import AVFoundation
import Foundation
import SoundAnalysis

/// Independently detects speech/singing with the system sound classifier. These
/// coarse regions gate lyric anchors; they never become per-character onsets and
/// do not imply that the app has separated a clean vocal stem.
enum NativeLyricVocalDetector {
    static let minimumConfidence = 0.5
    static let labels: Set<String> = ["speech", "singing", "choir"]

    static func detect(fileURL: URL, offset: Double = 0) async throws -> [LyricVocalRegion] {
        try Task.checkCancellation()
        let session = try VocalAnalysisSession(fileURL: fileURL, offset: offset)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let completed = await session.analyze()
            try Task.checkCancellation()
            if let error = session.observer.error { throw error }
            guard completed else { throw CancellationError() }
            return session.observer.regions
        } onCancel: { session.cancel() }
    }

    static func qualifies(identifier: String, confidence: Double) -> Bool {
        labels.contains(identifier) && confidence.isFinite && confidence >= minimumConfidence && confidence <= 1
    }
}

/// SoundAnalysis's file analysis/cancellation APIs manage their work internally.
/// The adapter retains its observer, whose mutable callback state is locked.
private final class VocalAnalysisSession: @unchecked Sendable {
    private let analyzer: SNAudioFileAnalyzer
    let observer: VocalAnalysisObserver

    init(fileURL: URL, offset: Double) throws {
        guard fileURL.isFileURL, offset.isFinite, offset >= 0 else { throw NativeLyricAlignmentError.invalidAudio }
        analyzer = try SNAudioFileAnalyzer(url: fileURL)
        observer = VocalAnalysisObserver(offset: offset)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 600)
        request.overlapFactor = 0.5
        guard !Set(request.knownClassifications).isDisjoint(with: NativeLyricVocalDetector.labels) else {
            throw NativeLyricAlignmentError.unsupportedLanguage
        }
        try analyzer.add(request, withObserver: observer)
    }

    func analyze() async -> Bool {
        await withCheckedContinuation { continuation in
            analyzer.analyze { completed in continuation.resume(returning: completed) }
        }
    }

    func cancel() { analyzer.cancelAnalysis() }
}

private final class VocalAnalysisObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let offset: Double
    private let lock = NSLock()
    private var storedRegions: [LyricVocalRegion] = []
    private var storedError: (any Error)?
    var regions: [LyricVocalRegion] { lock.withLock { storedRegions } }
    var error: (any Error)? { lock.withLock { storedError } }

    init(offset: Double) { self.offset = offset; super.init() }

    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let classified = result as? SNClassificationResult,
              classified.classifications.contains(where: {
                  NativeLyricVocalDetector.qualifies(identifier: $0.identifier, confidence: $0.confidence)
              }) else { return }
        let start = classified.timeRange.start.seconds + offset
        let end = CMTimeRangeGetEnd(classified.timeRange).seconds + offset
        guard start.isFinite, end.isFinite, end > start else { return }
        lock.withLock {
            if storedRegions.count < 8_192 { storedRegions.append(.init(start: start, end: end)) }
        }
    }

    func request(_ request: any SNRequest, didFailWithError error: any Error) {
        lock.withLock { storedError = error }
    }
}
