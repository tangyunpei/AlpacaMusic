import AVFoundation
import CryptoKit
import Foundation

/// Ephemeral access to the exact media selected by the player. Never persisted;
/// protected platform playback does not expose a source here.
struct LyricAudioSource: Equatable, Sendable {
    let session: UUID
    let trackKey: String
    let url: URL
}

enum LyricAudioPreparationError: Error, LocalizedError {
    case unsupported, tooLarge, invalidMedia, changedFile, network
    var errorDescription: String? {
        switch self {
        case .unsupported: L10n.string("当前音频无法提前分析，继续使用已有字幕时间。")
        case .tooLarge: L10n.string("音频超过后台分析限制，继续使用已有字幕时间。")
        case .invalidMedia: L10n.string("音频无法解码，继续使用已有字幕时间。")
        case .changedFile: L10n.string("分析期间音频文件已变更，未使用对齐结果。")
        case .network: L10n.string("后台音频读取失败，继续使用已有字幕时间。")
        }
    }
}

/// One background job owns its temporary media and PCM. Only derived word
/// ranges/times leave the job. Playback never awaits downloading or recognition.
actor LyricAudioPreparation {
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumDuration: Double = 1_200
    static let windowDuration: Double = 45
    private var directory: URL?
    private var scope: URL?
    private var file: AVAudioFile?
    private var fingerprint: LyricLocalAssetFingerprint?
    private var originalURL: URL?
    private(set) var identity: LyricAudioIdentity?

    func prepare(_ source: LyricAudioSource) async throws -> LyricAudioIdentity {
        try Task.checkCancellation()
        let work = FileManager.default.temporaryDirectory.appending(path: "alpaca-lyric-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        directory = work
        let mediaURL: URL
        if source.url.isFileURL {
            if source.url.startAccessingSecurityScopedResource() { scope = source.url }
            let before = try LyricLocalAssetFingerprint.make(url: source.url)
            guard before.fileSize <= Self.maximumBytes else { throw LyricAudioPreparationError.tooLarge }
            fingerprint = before; originalURL = source.url; mediaURL = source.url
        } else {
            guard ["https", "http"].contains(source.url.scheme?.lowercased() ?? ""),
                  source.url.user == nil, source.url.password == nil,
                  !source.url.path.lowercased().hasSuffix(".m3u8") else { throw LyricAudioPreparationError.unsupported }
            let suffix = source.url.pathExtension.lowercased()
            let ext = ["mp3", "m4a", "aac", "wav", "aiff", "caf", "flac", "mp4"].contains(suffix) ? suffix : "audio"
            mediaURL = work.appending(path: "media.\(ext)")
            try await download(source.url, to: mediaURL)
        }
        try Task.checkCancellation()
        let digest = try Self.digest(url: mediaURL)
        let decoded: AVAudioFile
        do { decoded = try AVAudioFile(forReading: mediaURL, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw LyricAudioPreparationError.invalidMedia }
        let rate = decoded.processingFormat.sampleRate
        let duration = Double(decoded.length) / rate
        guard rate.isFinite, (8_000...192_000).contains(rate), decoded.processingFormat.channelCount <= 8,
              duration.isFinite, duration > 0, duration <= Self.maximumDuration else { throw LyricAudioPreparationError.tooLarge }
        try checkUnchanged()
        file = decoded
        let value = LyricAudioIdentity(contentDigest: digest, sampleRate: rate, duration: duration)
        identity = value
        return value
    }

    func localFingerprint() -> LyricLocalAssetFingerprint? { fingerprint }

    func window(start: Double, end: Double) throws -> URL {
        try Task.checkCancellation(); try checkUnchanged()
        guard let file, let directory, let identity, start.isFinite, end.isFinite,
              start >= 0, end > start, end <= identity.duration + 0.01,
              end - start <= Self.windowDuration + 0.01 else { throw LyricAudioPreparationError.invalidMedia }
        let outputURL = directory.appending(path: "window.caf")
        try? FileManager.default.removeItem(at: outputURL)
        let format = file.processingFormat
        let output = try AVAudioFile(forWriting: outputURL, settings: format.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        file.framePosition = min(file.length, AVAudioFramePosition(start * format.sampleRate))
        var remaining = min(file.length - file.framePosition, AVAudioFramePosition((end - start) * format.sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else { throw LyricAudioPreparationError.invalidMedia }
        while remaining > 0 {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8_192, remaining)))
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= Int64(buffer.frameLength)
        }
        guard remaining == 0 else { throw LyricAudioPreparationError.invalidMedia }
        try checkUnchanged()
        return outputURL
    }

    func cleanup() {
        file = nil; identity = nil
        scope?.stopAccessingSecurityScopedResource(); scope = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    func checkUnchanged() throws {
        if let originalURL, let fingerprint, try LyricLocalAssetFingerprint.make(url: originalURL) != fingerprint {
            throw LyricAudioPreparationError.changedFile
        }
    }

    private func download(_ url: URL, to destination: URL) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 120
        config.httpCookieStorage = nil; config.urlCache = nil; config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("audio/*, application/octet-stream;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw LyricAudioPreparationError.network }
            guard response.expectedContentLength <= Self.maximumBytes else { throw LyricAudioPreparationError.tooLarge }
            let mime = (response.mimeType ?? "").lowercased()
            guard !mime.contains("mpegurl"), !mime.contains("text/"), !mime.contains("json") else { throw LyricAudioPreparationError.unsupported }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw LyricAudioPreparationError.network }
            let handle = try FileHandle(forWritingTo: destination); defer { try? handle.close() }
            var block = Data(); block.reserveCapacity(65_536); var count = 0
            for try await byte in stream {
                count += 1
                guard count <= Self.maximumBytes else { throw LyricAudioPreparationError.tooLarge }
                block.append(byte)
                if block.count == 65_536 { try Task.checkCancellation(); try handle.write(contentsOf: block); block.removeAll(keepingCapacity: true) }
            }
            try Task.checkCancellation(); try handle.write(contentsOf: block)
            guard count > 0 else { throw LyricAudioPreparationError.network }
        } catch is CancellationError { throw CancellationError() }
        catch let error as LyricAudioPreparationError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw LyricAudioPreparationError.network }
    }

    private static func digest(url: URL) throws -> String {
        _ = try LyricLocalAssetFingerprint.make(url: url)
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(), count = 0
        while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty {
            try Task.checkCancellation(); count += bytes.count
            guard count <= maximumBytes else { throw LyricAudioPreparationError.tooLarge }
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Prioritize the playhead and upcoming cues, then fill the rest for later
/// seeks. A seek changes the next job; timestamps never depend on wall time.
enum LyricAnalysisWindow {
    struct Range: Equatable, Sendable { let start: Double; let end: Double }
    static func next(document: LyricDocument, duration: Double, position: Double,
                     attempted: Set<Int>) -> (index: Int, range: Range)? {
        guard duration.isFinite, duration > 0, position.isFinite else { return nil }
        let eligible = document.lines.indices.filter { index in
            let line = document.lines[index]
            return line.words.isEmpty && !attempted.contains(index) && line.start.map { $0 >= 0 && $0 < duration } == true
        }
        let ahead = eligible.first { (document.lines[$0].start ?? 0) >= max(0, position - 1) }
        guard let index = ahead ?? eligible.first, let start = document.lines[index].start else { return nil }
        // Include each cue in full; long lines retain cadence fallback.
        let cueEnd = min(duration, document.lines[index].end ?? duration)
        guard cueEnd - start < LyricAudioPreparation.windowDuration - 2 else { return (index, .init(start: start, end: min(duration, start + LyricAudioPreparation.windowDuration))) }
        return (index, .init(start: max(0, start - 0.5), end: min(duration, max(cueEnd + 0.5, start + LyricAudioPreparation.windowDuration - 0.5))))
    }

    static func merge(_ result: LyricAlignmentResult, into original: LyricDocument,
                      position: Double?, includeCurrent: Bool = false) -> LyricDocument {
        var document = original
        let words = Dictionary(uniqueKeysWithValues: result.lines.map { ($0.lineID, $0.words) })
        for index in document.lines.indices {
            guard document.lines[index].words.isEmpty, let aligned = words[document.lines[index].id],
                  includeCurrent || position == nil || (document.lines[index].start ?? 0) > (position ?? 0) + 0.15 else { continue }
            document.lines[index].words = aligned
            document.lines[index].wordTimingOrigin = .audioEstimate
        }
        if document.lines.contains(where: { !$0.words.isEmpty }) { document.timing = .word }
        return document
    }
}
