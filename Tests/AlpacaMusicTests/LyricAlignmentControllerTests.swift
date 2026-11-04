import Foundation
import Testing
@testable import AlpacaMusic

private actor AlignmentControllerProbe {
    private struct Entry { let document: LyricDocument; let publish: LyricAlignmentRunner.Publish; let progress: LyricAlignmentRunner.Progress }
    private var entries: [UUID: Entry] = [:]
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
    func register(_ source: LyricAudioSource, document: LyricDocument,
                  publish: @escaping LyricAlignmentRunner.Publish,
                  progress: @escaping LyricAlignmentRunner.Progress) {
        entries[source.session] = .init(document: document, publish: publish, progress: progress)
        waiting.removeValue(forKey: source.session)?.resume()
    }
    func wait(for session: UUID) async {
        if entries[session] != nil { return }
        await withCheckedContinuation { waiting[session] = $0 }
    }
    func complete(_ session: UUID, cached: Bool = false) async {
        guard let entry = entries[session] else { return }
        let lines = entry.document.lines.compactMap { line -> LyricAlignedLine? in
            guard let start = line.start, let end = line.end else { return nil }
            return .init(lineID: line.id, words: [.init(id: 0, text: line.text, start: start + 0.1, end: end)],
                         quality: .init(coverage: 1, meanConfidence: 0.9, maximumAnchorDrift: 0.1, vocalOverlap: 1,
                                        matchedUnitCount: 1, estimatedUnitCount: 0))
        }
        await entry.publish(.init(lines: lines, vocalRegions: [.init(start: 0, end: 100)],
                                  engineVersion: "Fixture", localeIdentifier: "en-US"), cached)
        await entry.progress(.ready(lines.count))
    }
    var count: Int { entries.count }
}

@Suite @MainActor struct LyricAlignmentControllerTests {
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    private func track(_ name: String, in directory: URL) async throws -> Track {
        let url = directory.appending(path: "\(name).wav")
        try "[00:01]\(name) first\n[00:05]\(name) second\n[00:10]\(name) third".write(to: url.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
        let track = Track(id: name, title: name, artist: "Original test", album: "Fixture", duration: 15, source: .local, url: url)
        _ = try await LyricsStorage(directory: directory).importFile(url.deletingPathExtension().appendingPathExtension("lrc"), for: track)
        return track
    }
    private func controller(_ probe: AlignmentControllerProbe, directory: URL) -> LyricsController {
        LyricsController(client: NativeMusicClient(credentials: MemoryMusicCredentialStore()), directory: directory,
            alignmentOperation: { source, _, document, _, _, progress, publish in
                await probe.register(source, document: document, publish: publish, progress: progress)
            })
    }
    @Test func lateResultsCannotCrossSongChangesOrReplacedMediaSessions() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let probe = AlignmentControllerProbe(), lyrics = controller(probe, directory: directory)
        let first = try await track("First", in: directory), second = try await track("Second", in: directory)
        let old = LyricAudioSource(session: UUID(), trackKey: LyricsIdentity.key(for: first), url: first.url!)
        lyrics.setAudioSource(old, position: 0); await lyrics.load(track: first); await probe.wait(for: old.session)
        await lyrics.load(track: second)
        await probe.complete(old.session, cached: true)
        #expect(lyrics.document?.lines.first?.text == "Second first")
        #expect(lyrics.document?.lines.allSatisfy { $0.words.isEmpty } == true)
        let new = LyricAudioSource(session: UUID(), trackKey: LyricsIdentity.key(for: second), url: second.url!)
        lyrics.setAudioSource(new, position: 0); await probe.wait(for: new.session)
        lyrics.setAudioSource(nil, position: 0)
        await probe.complete(new.session, cached: true)
        #expect(lyrics.document?.lines.allSatisfy { $0.words.isEmpty } == true)
        #expect(lyrics.audioAlignmentStatus == .waitingAudio)
    }
    @Test func freshTimingAppliesAheadAndSeekUsesPreviouslyAnalyzedCues() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let probe = AlignmentControllerProbe(), lyrics = controller(probe, directory: directory)
        let track = try await track("Original", in: directory)
        let source = LyricAudioSource(session: UUID(), trackKey: LyricsIdentity.key(for: track), url: track.url!)
        lyrics.setAudioSource(source, position: 2); await lyrics.load(track: track); await probe.wait(for: source.session)
        await probe.complete(source.session)
        #expect(lyrics.document?.lines[0].words.isEmpty == true)
        #expect(lyrics.document?.lines[1].words.isEmpty == false)
        lyrics.updateAlignmentPosition(1, didSeek: true)
        #expect(lyrics.document?.lines[0].words.isEmpty == false)
        lyrics.setAutomaticAudioAlignment(false)
        await probe.complete(source.session, cached: true)
        #expect(lyrics.audioAlignmentStatus == .off)
        #expect(lyrics.document?.lines.allSatisfy { $0.words.isEmpty } == true)
    }
    @Test func cachedTimingIsImmediateAndImportedReplacementInvalidatesPriorAnalysis() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let probe = AlignmentControllerProbe(), lyrics = controller(probe, directory: directory)
        let track = try await track("Original", in: directory)
        let source = LyricAudioSource(session: UUID(), trackKey: LyricsIdentity.key(for: track), url: track.url!)
        lyrics.setAudioSource(source, position: 2); await lyrics.load(track: track); await probe.wait(for: source.session)
        await probe.complete(source.session, cached: true)
        #expect(lyrics.document?.lines[0].words.isEmpty == false)
        let replacement = directory.appending(path: "replacement.lrc")
        try "[00:01]A new lyric\n[00:05]A new ending".write(to: replacement, atomically: true, encoding: .utf8)
        lyrics.setAutomaticAudioAlignment(false)
        try await lyrics.importFile(url: replacement, for: track)
        await probe.complete(source.session, cached: true)
        #expect(lyrics.document?.lines[0].text == "A new lyric")
        #expect(lyrics.document?.lines.allSatisfy { $0.words.isEmpty } == true)
        #expect(await probe.count == 1)
    }
    @Test func disablingAnalysisAndProtectedPlaybackNeverInvokesAudioEngine() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let probe = AlignmentControllerProbe(), lyrics = controller(probe, directory: directory)
        let track = try await track("Original", in: directory)
        lyrics.setAutomaticAudioAlignment(false)
        lyrics.setAudioSource(.init(session: UUID(), trackKey: LyricsIdentity.key(for: track), url: track.url!), position: 0)
        await lyrics.load(track: track)
        #expect(await probe.count == 0)
        lyrics.setAudioSource(nil, position: 0)
        lyrics.setAutomaticAudioAlignment(true)
        #expect(await probe.count == 0)
        #expect(lyrics.status == .ready)
        #expect(lyrics.audioAlignmentStatus == .waitingAudio)
    }
}
