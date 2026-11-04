import AVFoundation
import Foundation
import NaturalLanguage
import Speech

enum NativeLyricAlignmentAvailability: Equatable, Sendable {
    case ready(localeIdentifier: String)
    case needsModel(localeIdentifier: String)
    case unsupported
}

enum NativeLyricAlignmentError: Error, Equatable, Sendable {
    case unsupportedLanguage
    case modelNotInstalled
    case invalidAudio
    case noCompatibleFormat
}

/// Uses the macOS 26 on-device speech model to measure lyric anchors and voice
/// regions ahead of playback. It never opens a microphone or uses server ASR.
/// Singing recognition is imperfect: unmatched/low-confidence cues fall back to
/// the ordinary lyric estimator, not guessed audio peak timestamps.
enum NativeLyricAudioAligner {
    static var engineVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "apple-speech-singing-anchors-v1-macos-\(version.majorVersion).\(version.minorVersion)"
    }
    static let maximumAudioSeconds = 180.0

    static func availability(for document: LyricDocument,
                             localeIdentifier: String? = nil) async -> NativeLyricAlignmentAvailability {
        guard SpeechTranscriber.isAvailable,
              let locale = await supportedLocale(for: document, explicit: localeIdentifier) else { return .unsupported }
        let modules = makeModules(locale: locale)
        let status = await AssetInventory.status(forModules: [modules.transcriber, modules.detector])
        switch status {
        case .installed: return .ready(localeIdentifier: locale.identifier)
        case .supported, .downloading: return .needsModel(localeIdentifier: locale.identifier)
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    static func align(fileURL: URL, document: LyricDocument, offset: Double = 0,
                      localeIdentifier: String? = nil,
                      allowAssetDownload: Bool = false) async throws -> LyricAlignmentResult {
        try Task.checkCancellation()
        guard fileURL.isFileURL, offset.isFinite, offset >= 0,
              SpeechTranscriber.isAvailable,
              let locale = await supportedLocale(for: document, explicit: localeIdentifier) else {
            throw NativeLyricAlignmentError.unsupportedLanguage
        }
        let file = try AVAudioFile(forReading: fileURL)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, duration <= maximumAudioSeconds else {
            throw NativeLyricAlignmentError.invalidAudio
        }
        // Classify actual speech/singing first. Silence and instruments do not
        // need ASR or language-asset installation, and native recognizers may
        // otherwise reject these inputs as an internal recognition failure.
        let vocalRegions = try await NativeLyricVocalDetector.detect(fileURL: fileURL, offset: offset)
        let regions = LyricAudioAnchorMatcher.mergedVocalRegions(vocalRegions, within: offset..<(offset + duration))
        guard !regions.isEmpty else {
            return .init(lines: [], vocalRegions: [], engineVersion: engineVersion,
                         localeIdentifier: locale.identifier)
        }
        let modules = makeModules(locale: locale)
        let speechModules: [any SpeechModule] = [modules.transcriber, modules.detector]
        let status = await AssetInventory.status(forModules: speechModules)
        if status != .installed {
            guard status != .unsupported else { throw NativeLyricAlignmentError.unsupportedLanguage }
            guard allowAssetDownload else { throw NativeLyricAlignmentError.modelNotInstalled }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: speechModules) {
                try await request.downloadAndInstall()
            }
            guard await AssetInventory.status(forModules: speechModules) == .installed else {
                throw NativeLyricAlignmentError.modelNotInstalled
            }
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: speechModules) else {
            throw NativeLyricAlignmentError.noCompatibleFormat
        }
        let analyzer = SpeechAnalyzer(modules: speechModules,
                                      options: .init(priority: .utility, modelRetention: .whileInUse))
        let context = AnalysisContext()
        // Bounded phrase hints improve recognition, but hints aren't evidence:
        // acceptance still requires measured timestamps, confidence, and VAD.
        context.contextualStrings[.general] = document.lines.filter {
            guard let start = $0.start else { return false }
            return start >= offset && start < offset + duration && $0.words.isEmpty
        }.prefix(48).map(\.text)
        try await analyzer.setContext(context)
        let transcription = Task<[LyricAudioAnchor], Error> {
            var anchors: [LyricAudioAnchor] = []
            for try await result in modules.transcriber.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                for run in result.text.runs {
                    guard let range = run.audioTimeRange, let confidence = run.transcriptionConfidence else { continue }
                    let start = range.start.seconds + offset, end = CMTimeRangeGetEnd(range).seconds + offset
                    let text = String(result.text[run.range].characters)
                    guard start.isFinite, end.isFinite, end > start else { continue }
                    if let last = anchors.last, last.start == start, last.end == end {
                        anchors[anchors.count - 1].text += text
                        anchors[anchors.count - 1].confidence = min(last.confidence, confidence)
                    } else {
                        anchors.append(.init(text: text, start: start, end: end, confidence: confidence))
                    }
                    guard anchors.count <= 8_192 else { throw NativeLyricAlignmentError.invalidAudio }
                }
            }
            return anchors
        }
        let detection = Task<[LyricVocalRegion], Error> {
            var regions: [LyricVocalRegion] = []
            for try await result in modules.detector.results {
                try Task.checkCancellation()
                guard result.isFinal, result.speechDetected else { continue }
                let start = result.range.start.seconds + offset
                let end = CMTimeRangeGetEnd(result.range).seconds + offset
                if start.isFinite, end.isFinite, end > start {
                    regions.append(.init(start: start, end: end))
                }
                guard regions.count <= 8_192 else { throw NativeLyricAlignmentError.invalidAudio }
            }
            return regions
        }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await analyzer.prepareToAnalyze(in: format)
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                let anchors = try await transcription.value
                _ = try await detection.value
                try Task.checkCancellation()
                return LyricAudioAnchorMatcher.align(document: document, anchors: anchors,
                                                     vocalRegions: regions,
                                                     audioRange: offset..<(offset + duration),
                                                     engineVersion: engineVersion,
                                                     localeIdentifier: locale.identifier)
            } catch {
                transcription.cancel(); detection.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            transcription.cancel(); detection.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private static func makeModules(locale: Locale) -> (transcriber: SpeechTranscriber, detector: SpeechDetector) {
        (SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                           attributeOptions: [.audioTimeRange, .transcriptionConfidence]),
         SpeechDetector(detectionOptions: .init(sensitivityLevel: .low), reportResults: true))
    }

    private static func supportedLocale(for document: LyricDocument, explicit: String?) async -> Locale? {
        let identifier = explicit ?? preferredLocaleIdentifier(for: document)
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
    }

    static func preferredLocaleIdentifier(for document: LyricDocument) -> String {
        let text = document.lines.prefix(48).map(\.text).joined(separator: " ").prefix(8_192)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text))
        switch recognizer.dominantLanguage {
        case .simplifiedChinese, .traditionalChinese: return "zh-CN"
        case .japanese: return "ja-JP"
        case .korean: return "ko-KR"
        case .spanish: return "es-ES"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .italian: return "it-IT"
        case .portuguese: return "pt-BR"
        case .russian: return "ru-RU"
        case .arabic: return "ar-SA"
        default: return "en-US"
        }
    }
}
