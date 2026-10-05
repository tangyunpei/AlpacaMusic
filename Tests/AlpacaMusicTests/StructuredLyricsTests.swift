import Foundation
import Testing
@testable import AlpacaMusic

struct StructuredLyricsTests {
    @Test func preservesMeasuredWordEndsAndSilenceWithoutRounding() throws {
        let measured = LyricDocument(lines: [
            .init(id: 0, text: "One two", start: 0.013, end: 2.981, words: [
                .init(id: 0, text: "One ", start: 0.013, end: 0.517),
                .init(id: 1, text: "two", start: 1.803, end: 2.981)
            ]),
            .init(id: 1, text: "Again", start: 5.137, end: 6.061)
        ], timing: .word, sourceDescription: "Untrusted label")
        var expected = measured; expected.sourceDescription = "汽水音乐"
        let actual = try LyricsParser.parse(LyricsPayload(text: "", document: measured), sourceDescription: "汽水音乐")
        #expect(actual == expected)
        #expect(actual.activeWordIndex(in: 0, at: 1) == nil)
        #expect(actual.activeIndex(at: 4) == nil)
        #expect(actual.activeIndex(at: 5.137) == 1)
    }
    @Test func malformedMeasuredTimingsCannotReachCaptionRendering() throws {
        let bad: [LyricDocument] = [
            .init(lines: [.init(id: 0, text: "Bad", start: .nan, end: 3)], timing: .line, sourceDescription: ""),
            .init(lines: [.init(id: 0, text: "Later", start: 3, end: 4), .init(id: 1, text: "Earlier", start: 1, end: 2)], timing: .line, sourceDescription: ""),
            .init(lines: [.init(id: 0, text: "Missing")], timing: .word, sourceDescription: ""),
            .init(lines: [.init(id: 0, text: "Too long", start: 1, end: 2, words: [.init(id: 0, text: "long", start: 1.5, end: 3)])], timing: .word, sourceDescription: ""),
            .init(lines: [.init(id: 0, text: "Backwards", start: 1, end: 2, words: [.init(id: 0, text: "word", start: 1.8, end: 1.2)])], timing: .word, sourceDescription: "")
        ]
        for document in bad {
            #expect(throws: MusicError.self) {
                try LyricsParser.parse(LyricsPayload(text: "", document: document), sourceDescription: "汽水音乐")
            }
        }
    }
    @Test func structuredPayloadHasTheSameSizeLimitAsTextLyrics() throws {
        let document = LyricDocument(lines: [.init(id: 0, text: "Small", start: 1, end: 2, translation: String(repeating: "x", count: LyricsParser.maximumBytes))], timing: .line, sourceDescription: "")
        #expect(throws: MusicError.self) {
            try LyricsParser.parse(LyricsPayload(text: "", document: document), sourceDescription: "汽水音乐")
        }
    }
}
