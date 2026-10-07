import Foundation

enum LyricAudioAlignmentStatus: Equatable, Sendable {
    case off, waitingAudio, provider, preparing, model, analyzing, ready(Int), fallback(String)
    var description: String {
        switch self {
        case .off: L10n.string("音频字幕对齐已关闭")
        case .waitingAudio: L10n.string("当前音源未提供可分析音频，使用已有字幕时间")
        case .provider: L10n.string("使用已有逐字时间")
        case .preparing: L10n.string("正在后台读取音频")
        case .model: L10n.string("正在准备本机语言模型")
        case .analyzing: L10n.string("正在提前分析人声与字幕")
        case .ready(let count): L10n.string("已匹配 \(count) 句人声时间")
        case .fallback(let reason): reason
        }
    }
}

enum LyricAlignmentRunner {
    typealias Position = @Sendable () async -> Double
    typealias Progress = @Sendable (LyricAudioAlignmentStatus) async -> Void
    typealias Publish = @Sendable (LyricAlignmentResult, Bool) async -> Void
    typealias Operation = @Sendable (LyricAudioSource, Track, LyricDocument, LyricAlignmentCache,
                                     @escaping Position, @escaping Progress, @escaping Publish) async -> Void
    static let algorithmVersion = "lyric-anchors-preanalysis-v1"
    static func run(source: LyricAudioSource, track: Track, document: LyricDocument,
                    cache: LyricAlignmentCache,
                    position: Position,
                    progress: Progress,
                    publish: Publish) async {
        let preparation = LyricAudioPreparation()
        do {
            try Task.checkCancellation()
            let availability = await NativeLyricAudioAligner.availability(for: document)
            guard availability != .unsupported else { throw NativeLyricAlignmentError.unsupportedLanguage }
            await progress(.preparing)
            let audio = try await preparation.prepare(source)
            let identity = try LyricAlignmentIdentity.make(track: track, document: document, audio: audio,
                                                          localAsset: await preparation.localFingerprint(),
                                                          modelVersion: NativeLyricAudioAligner.engineVersion,
                                                          algorithmVersion: algorithmVersion)
            var combined = try await cache.cached(for: identity, document: document)
            if let combined { await publish(combined, true); await progress(.ready(combined.lines.count)) }
            var attempted = Set(document.lines.indices.filter { index in
                !document.lines[index].words.isEmpty || combined?.lines.contains(where: { $0.lineID == document.lines[index].id }) == true
            })
            var firstWindow = true
            while let window = LyricAnalysisWindow.next(document: document, duration: audio.duration,
                                                        position: await position(), attempted: attempted) {
                try Task.checkCancellation()
                let url = try await preparation.window(start: window.range.start, end: window.range.end)
                if case .needsModel = availability, firstWindow { await progress(.model) }
                else { await progress(.analyzing) }
                let result = try await NativeLyricAudioAligner.align(fileURL: url, document: document,
                                                                   offset: window.range.start, allowAssetDownload: true)
                try Task.checkCancellation(); try await preparation.checkUnchanged()
                firstWindow = false
                attempted.insert(window.index)
                for index in document.lines.indices {
                    let line = document.lines[index]
                    if let start = line.start, let end = line.end, start >= window.range.start, end <= window.range.end { attempted.insert(index) }
                }
                if let accepted = LyricAlignmentQualityGate.acceptedResult(result, for: document, audioDuration: audio.duration) {
                    var collected = combined ?? .init(lines: [], vocalRegions: [], engineVersion: accepted.engineVersion,
                                                     localeIdentifier: accepted.localeIdentifier)
                    let ids = Set(accepted.lines.map(\.lineID))
                    collected.lines.removeAll { ids.contains($0.lineID) }; collected.lines += accepted.lines
                    collected.lines.sort { $0.lineID < $1.lineID }
                    collected.vocalRegions = LyricAudioAnchorMatcher.mergedVocalRegions(collected.vocalRegions + accepted.vocalRegions,
                                                                                       within: 0..<audio.duration)
                    combined = collected
                    _ = try? await cache.store(collected, for: identity, document: document)
                    await publish(collected, false)
                }
            }
            try Task.checkCancellation()
            await progress(combined.map { .ready($0.lines.count) } ?? .fallback(L10n.string("未获得可靠的人声时间，继续使用字幕估算")))
        } catch is CancellationError {
            // The owning controller already replaced/disabled this job.
        } catch {
            if !Task.isCancelled {
                let reason: String
                if let error = error as? LyricAudioPreparationError { reason = error.localizedDescription }
                else if let native = error as? NativeLyricAlignmentError {
                    switch native {
                    case .unsupportedLanguage: reason = L10n.string("本机模型暂不支持这首歌的语言，使用已有字幕时间")
                    case .modelNotInstalled: reason = L10n.string("本机语言模型未就绪，使用已有字幕时间")
                    default: reason = L10n.string("音频分析未完成，继续使用已有字幕时间")
                    }
                } else { reason = L10n.string("音频分析未完成，继续使用已有字幕时间") }
                await progress(.fallback(reason))
            }
        }
        await preparation.cleanup()
    }
}
