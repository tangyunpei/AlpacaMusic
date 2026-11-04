import Darwin
import Foundation
import Testing
@testable import AlpacaMusic

@Suite struct LyricAlignmentCacheTests {
    private var document: LyricDocument {
        .init(lines: [.init(id: 8, text: "亲爱的你", start: 10, end: 18),
                      .init(id: 15, text: "别为我哭泣", start: 20, end: 29)], timing: .line, sourceDescription: "fixture")
    }
    private var track: Track {
        .init(id: "qq-42", title: "Song", artist: "Singer", album: "Album", duration: 35, source: .qq, sourceID: "42")
    }
    private var audio: LyricAudioIdentity {
        .init(contentDigest: String(repeating: "a", count: 64), sampleRate: 16_000, duration: 35)
    }
    private func identity(track: Track? = nil, document: LyricDocument? = nil,
                          audio: LyricAudioIdentity? = nil, model: String = "native-ASR-macOS27.0-v1") throws -> LyricAlignmentIdentity {
        try .make(track: track ?? self.track, document: document ?? self.document,
                  audio: audio ?? self.audio, modelVersion: model, algorithmVersion: "test-v1")
    }
    private func quality(count: Int) -> LyricAlignmentQuality {
        .init(coverage: 1, meanConfidence: 0.9, maximumAnchorDrift: 0.2, vocalOverlap: 1,
              matchedUnitCount: count, estimatedUnitCount: 0)
    }
    private func aligned(_ line: LyricLine) -> LyricAlignedLine {
        .init(lineID: line.id, words: Array(line.text).enumerated().map {
            .init(id: $0.offset, text: String($0.element), start: (line.start ?? 0) + 0.2 + Double($0.offset) * 0.5,
                  end: (line.start ?? 0) + 0.6 + Double($0.offset) * 0.5)
        }, quality: quality(count: LyricAudioAnchorMatcher.lexicalUnitCount(in: line.text)))
    }
    private func result(document: LyricDocument? = nil, model: String = "native-ASR-macOS27.0-v1") -> LyricAlignmentResult {
        .init(lines: (document ?? self.document).lines.map(aligned),
              vocalRegions: [.init(start: 10, end: 18), .init(start: 20, end: 29)], engineVersion: model, localeIdentifier: "zh-Hans-CN")
    }
    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/alpaca-alignment-cache-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func recordingIdentitySeparatesLiveCoverRemasterSourceAndActualMedia() throws {
        let original = try identity()
        var variants: [Track] = []
        for title in ["Song (Live)", "Song (2026 Remaster)", "Song (Cover)"] {
            var value = track; value.title = title; variants.append(value)
        }
        var album = track; album.album = "Live Album"; variants.append(album)
        var artist = track; artist.artist = "Another Singer"; variants.append(artist)
        var source = track; source.source = .netease; variants.append(source)
        var identifier = track; identifier.sourceID = "43"; variants.append(identifier)
        var duration = track; duration.duration = 36; variants.append(duration)
        for variant in variants { #expect(try identity(track: variant).key != original.key) }
        var differentBytes = audio; differentBytes.contentDigest = String(repeating: "b", count: 64)
        #expect(try identity(audio: differentBytes).key != original.key)
        var differentRate = audio; differentRate.sampleRate = 44_100
        #expect(try identity(audio: differentRate).key != original.key)
        #expect(try identity(model: "native-ASR-macOS27.1-v1").key != original.key)
        #expect(original.key.count == 64 && LyricAlignmentDigest.isSHA256(original.key))
    }

    @Test func signedURLTokensAreExcludedWhileAudioContentRemainsAuthoritative() throws {
        var a = track; a.sourceID = "https://example.test/song/42?token=secret-a&expires=20#token"
        var b = a; b.sourceID = "https://example.test/song/42?token=secret-b&expires=90"
        #expect(try identity(track: a).key == identity(track: b).key)
        b.sourceID = "https://example.test/song/43?token=secret-a"
        #expect(try identity(track: a).key != identity(track: b).key)
        var changedAudio = audio; changedAudio.contentDigest = String(repeating: "c", count: 64)
        #expect(try identity(track: a).key != identity(track: a, audio: changedAudio).key)
    }

    @Test func lyricDigestIncludesExactWordsBoundsWhitespaceAndStableDisplayLanguage() throws {
        let original = try identity()
        var variants: [LyricDocument] = []
        var text = document; text.lines[0].text += " "; variants.append(text)
        var start = document; start.lines[0].start = 10.1; variants.append(start)
        var end = document; end.lines[0].end = 17.9; variants.append(end)
        var word = document; word.lines[0].words = [.init(id: 0, text: "亲爱的你", start: 10.2, end: 12)]; variants.append(word)
        for variant in variants { #expect(try identity(document: variant).key != original.key) }
        var display = document; display.sourceDescription = "Lyrics in another UI language"
        #expect(try identity(document: display).key == original.key)
        let before = document
        _ = try identity()
        #expect(document == before)
    }

    @Test func boundedPCMHashDetectsRateContentAndRejectsNonfiniteSamples() throws {
        let first = try LyricAudioIdentity.fingerprint(samples: [0, 0.2, -0.7, 0.1], sampleRate: 16_000)
        #expect(first == (try LyricAudioIdentity.fingerprint(samples: [-0.0, 0.2, -0.7, 0.1], sampleRate: 16_000)))
        #expect(first != (try LyricAudioIdentity.fingerprint(samples: [0, 0.2, -0.6, 0.1], sampleRate: 16_000)))
        #expect(first != (try LyricAudioIdentity.fingerprint(samples: [0, 0.2, -0.7, 0.1], sampleRate: 44_100)))
        #expect(throws: LyricAlignmentCacheError.self) { try LyricAudioIdentity.fingerprint(samples: [.nan], sampleRate: 16_000) }
        #expect(throws: LyricAlignmentCacheError.self) { try LyricAudioIdentity.fingerprint(samples: [], sampleRate: 16_000) }
    }

    @Test func qualityGateKeepsGoodLinesAndLeavesPoorProviderAndGapCandidatesUntouched() {
        var input = document
        input.lines.append(.init(id: 31, text: "保重", start: 30, end: 34, words: [
            .init(id: 0, text: "保", start: 30.4, end: 31), .init(id: 1, text: "重", start: 31.2, end: 33)
        ]))
        let snapshot = input
        var proposed = result(document: input)
        proposed.lines[1].quality.meanConfidence = 0.49
        proposed.vocalRegions.append(.init(start: 30, end: 34))
        let accepted = LyricAlignmentQualityGate.acceptedResult(proposed, for: input, audioDuration: 35)
        #expect(accepted?.lines.map(\.lineID) == [8])
        #expect(input == snapshot)
        #expect(input.lines[2].words.map(\.start) == [30.4, 31.2])
        proposed.lines[0].words[0].start = 9.9
        #expect(LyricAlignmentQualityGate.acceptedResult(proposed, for: input, audioDuration: 35) == nil)
    }

    @Test func malformedTextTimingCountsAndAbsentVocalEvidenceNeverPassQualityGate() {
        let good = result()
        var cases: [LyricAlignmentResult] = []
        var text = good; text.lines[0].words[0].text = "其他"; cases.append(text)
        var overlap = good; overlap.lines[0].words[1].start = overlap.lines[0].words[0].start; cases.append(overlap)
        var gap = good; gap.lines[0].words[0].end = 19; cases.append(gap)
        var drift = good; drift.lines[0].words[0].start = 12; drift.lines[0].words[0].end = 12.1; cases.append(drift)
        var count = good; count.lines[0].quality.matchedUnitCount = 1; cases.append(count)
        var nonfinite = good; nonfinite.lines[0].quality.meanConfidence = .nan; cases.append(nonfinite)
        var noVoice = good; noVoice.vocalRegions = [.init(start: 1, end: 2)]; cases.append(noVoice)
        for candidate in cases {
            #expect(LyricAlignmentQualityGate.acceptedResult(candidate, for: document, audioDuration: 35)?.lines.map(\.lineID) == [15] ||
                    LyricAlignmentQualityGate.acceptedResult(candidate, for: document, audioDuration: 35) == nil)
        }
        var emptyVoice = good; emptyVoice.vocalRegions = []
        #expect(LyricAlignmentQualityGate.acceptedResult(emptyVoice, for: document, audioDuration: 35) == nil)
        var duplicate = good; duplicate.lines = [good.lines[0], good.lines[0]]
        #expect(LyricAlignmentQualityGate.acceptedResult(duplicate, for: document, audioDuration: 35) == nil)
    }

    @Test func roundTripPersistsOnlyRangesAndReconstructsOriginalText() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LyricAlignmentCache(directory: directory), key = try identity(), proposed = result()
        #expect(try await cache.store(proposed, for: key, document: document))
        let reopened = LyricAlignmentCache(directory: directory)
        #expect(try await reopened.cached(for: key, document: document) == proposed)
        let url = directory.appending(path: "lyric-alignments/" + key.key + ".json")
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(!contents.contains("亲爱的你") && !contents.contains("Song") && !contents.contains("Singer") && !contents.contains("Album"))
        #expect(!contents.contains("http") && !contents.contains("cookie") && !contents.contains("token"))
        #expect(contents.contains("ranges") && contents.contains("quality"))
        var changed = document; changed.lines[0].end = 17.8
        #expect(try await reopened.cached(for: key, document: changed) == nil)
        var changedAudio = audio; changedAudio.contentDigest = String(repeating: "d", count: 64)
        #expect(try await reopened.cached(for: identity(audio: changedAudio), document: document) == nil)
    }

    @Test func groupedUnicodeRunsKeepPunctuationAndDiscloseEstimatedSubunits() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let input = LyricDocument(lines: [.init(id: 0, text: "你好， café!", start: 10, end: 18)], timing: .line, sourceDescription: "fixture")
        let quality = LyricAlignmentQuality(coverage: 1, meanConfidence: 0.8, maximumAnchorDrift: 0.1,
                                           vocalOverlap: 1, matchedUnitCount: 3, estimatedUnitCount: 1)
        let proposed = LyricAlignmentResult(lines: [.init(lineID: 0, words: [
            .init(id: 0, text: "你好， ", start: 10.1, end: 11.3), .init(id: 1, text: "café!", start: 11.5, end: 12.3)
        ], quality: quality)], vocalRegions: [.init(start: 10, end: 18)], engineVersion: "native-ASR-macOS27.0-v1", localeIdentifier: "zh-Hans-CN")
        let cache = LyricAlignmentCache(directory: directory), key = try identity(document: input)
        #expect(try await cache.store(proposed, for: key, document: input))
        let loaded = try #require(try await cache.cached(for: key, document: input))
        #expect(loaded == proposed)
        #expect(loaded.lines[0].quality.estimatedUnitCount == 1)
        #expect(loaded.lines[0].words.map(\.text).joined() == input.lines[0].text)
    }

    @Test func corruptOversizedSymlinkAndDirectoryRecordsAreMisses() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LyricAlignmentCache(directory: directory), key = try identity()
        #expect(try await cache.store(result(), for: key, document: document))
        let url = directory.appending(path: "lyric-alignments/" + key.key + ".json")
        try Data("{malformed".utf8).write(to: url)
        #expect(try await cache.cached(for: key, document: document) == nil)
        try Data(repeating: 65, count: LyricAlignmentCache.maximumRecordBytes + 1).write(to: url)
        #expect(try await cache.cached(for: key, document: document) == nil)
        try FileManager.default.removeItem(at: url)
        let outside = directory.appending(path: "outside.json"); try Data("unchanged".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        #expect(try await cache.cached(for: key, document: document) == nil)
        await #expect(throws: LyricAlignmentCacheError.self) { try await cache.store(result(), for: key, document: document) }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "unchanged")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(try await cache.cached(for: key, document: document) == nil)
    }

    @Test func symlinkedCacheParentCannotRedirectWrites() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let link = directory.appending(path: "link", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let cache = LyricAlignmentCache(directory: link), key = try identity()
        await #expect(throws: LyricAlignmentCacheError.self) { try await cache.store(result(), for: key, document: document) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path()).isEmpty)
        #expect(try await cache.cached(for: key, document: document) == nil)
    }

    @Test func countEvictionIsBoundedAndKeepsLatestRecording() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LyricAlignmentCache(directory: directory)
        var last: LyricAlignmentIdentity?
        for index in 0..<70 {
            var bytes = audio; bytes.contentDigest = LyricAlignmentDigest.hash(Data("recording-\(index)".utf8))
            let key = try identity(audio: bytes)
            #expect(try await cache.store(result(), for: key, document: document))
            last = key
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory.appending(path: "lyric-alignments"), includingPropertiesForKeys: [.fileSizeKey])
        #expect(files.count == LyricAlignmentCache.maximumRecords)
        #expect(try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) } <= LyricAlignmentCache.maximumTotalBytes)
        #expect(try await cache.cached(for: #require(last), document: document) == result())
    }

    @Test func totalByteLimitEvictsOversizedAndOlderDerivedRecords() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let records = directory.appending(path: "lyric-alignments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: false)
        let padding = Data(repeating: 32, count: LyricAlignmentCache.maximumRecordBytes)
        for index in 0..<20 {
            let name = LyricAlignmentDigest.hash(Data("old-\(index)".utf8)) + ".json"
            try padding.write(to: records.appending(path: name))
        }
        let cache = LyricAlignmentCache(directory: directory), key = try identity()
        #expect(try await cache.store(result(), for: key, document: document))
        let files = try FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: [.fileSizeKey])
        #expect(try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) } <= LyricAlignmentCache.maximumTotalBytes)
        #expect(files.count < 20)
        #expect(try await cache.cached(for: key, document: document) == result())
    }

    @Test func nonregularFIFOIsRejectedWithoutBlocking() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let records = directory.appending(path: "lyric-alignments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: false)
        let key = try identity(), record = records.appending(path: key.key + ".json")
        #expect(mkfifo(record.path(percentEncoded: false), 0o600) == 0)
        let cache = LyricAlignmentCache(directory: directory)
        #expect(try await cache.cached(for: key, document: document) == nil)
        await #expect(throws: LyricAlignmentCacheError.self) { try await cache.store(result(), for: key, document: document) }
    }

    @Test func cancelledTaskDoesNotWriteAndInvalidDocumentsCannotCrashLookup() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LyricAlignmentCache(directory: directory), key = try identity(), proposed = result(), input = document
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cache.store(proposed, for: key, document: input)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "lyric-alignments").path()))
        var invalid = document; invalid.lines[1].id = invalid.lines[0].id
        var forcedKey = key; forcedKey.lyricDigest = try LyricAlignmentDigest.lyrics(invalid)
        #expect(try await cache.cached(for: forcedKey, document: invalid) == nil)
        #expect(LyricAlignmentQualityGate.acceptedResult(proposed, for: invalid, audioDuration: 35) == nil)
    }
}
