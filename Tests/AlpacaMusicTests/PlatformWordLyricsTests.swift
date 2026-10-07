import Foundation
import Testing
@testable import AlpacaMusic

@Suite struct PlatformWordLyricsTests {
    @Test func yrcPreservesMeasuredOnsetsDurationsAndInstrumentalGaps() throws {
        let text = "{\"t\":0,\"c\":[]}\n[1200,5400](1200,400,0)青(2050,600,0)山(3500,3100,0)远\n[9000,2200](9000,900,0)明(10000,1200,0)天"
        let doc = try #require(PlatformWordLyrics.parse(text, format: .yrc, translation: "[00:01.200]Translation\n[00:09.000]Tomorrow"))
        #expect(doc.timing == .word)
        #expect(doc.lines.map(\.text) == ["青山远", "明天"])
        #expect(doc.lines[0].words.map(\.start) == [1.2, 2.05, 3.5])
        #expect(doc.lines[0].words.map(\.end) == [1.6, 2.65, 6.6])
        #expect(doc.lines[0].end == 6.6)
        #expect(doc.activeIndex(at: 8) == nil)
        #expect(doc.lines[0].translation == "Translation")
    }

    @Test func qrcXMLPreservesNewlinesDecodesEntitiesAndWholeLatinWords() throws {
        let xml = "<QrcInfos><Lyric_1 LyricContent=\"[1000,4000]Hello (1000,800)world &amp; sky(2000,3000)\n[7000,2000]青(7000,700)山(8000,1000)\"/></QrcInfos>"
        let doc = try #require(PlatformWordLyrics.parse(xml, format: .qrc))
        #expect(doc.lines.count == 2)
        #expect(doc.lines[0].text == "Hello world & sky")
        #expect(doc.lines[0].words.map(\.text) == ["Hello ", "world & sky"])
        #expect(doc.lines[0].words.map(\.start) == [1, 2])
        #expect(doc.lines[1].words.map(\.start) == [7, 8])
        #expect(doc.lines[0].end == 5)
    }

    @Test func qrcTranslationUsesItsOwnMeasuredSentenceStart() throws {
        let raw = "[1000,2000]青(1000,500)山(2000,1000)"
        let translation = "<Qrc LyricContent='[1000,2000]Blue hills\n[5000,2000]Unrelated line'/>"
        let doc = try #require(PlatformWordLyrics.parse(raw, format: .qrc, translation: translation))
        #expect(doc.lines[0].translation == "Blue hills")
    }

    @Test func literalComparisonSymbolIsNotMistakenForXML() throws {
        let doc = try #require(PlatformWordLyrics.parse("[1000,1000]a < b(1000,1000)", format: .qrc))
        #expect(doc.lines[0].text == "a < b")
    }

    @Test func malformedMeasuredDataIsRejectedRatherThanGuessed() {
        for text in [
            "[1000,2000](900,500,0)早", // before the sentence
            "[1000,2000](1000,0,0)零", // zero vocal duration
            "[1000,2000](1000,5000,0)长", // beyond the measured cue
            "[1000,2000](2000,200,0)山(1500,200,0)青", // reversed onsets
            "[1000,2000](1000,500,0)青\n[2000,1000]missing words", // partial document
            "[86400000,1000](86400000,1000,0)远", // out of range
            "[1000,2000]prefix(1000,500,0)青"
        ] { #expect(PlatformWordLyrics.parse(text, format: .yrc) == nil) }
        #expect(PlatformWordLyrics.parse("<!DOCTYPE Qrc [<!ENTITY local SYSTEM 'file:///etc/passwd'>]><Qrc LyricContent='&local;'/>", format: .qrc) == nil)
        #expect(PlatformWordLyrics.parse(String(repeating: "a", count: LyricsParser.maximumBytes + 1), format: .qrc) == nil)
    }

    @Test func qrcCodecMatchesIndependentMITReferenceVector() throws {
        // Original fixture text encrypted by apoint123/qrc-decoder, not by our
        // implementation. No platform account or commercial lyric is involved.
        let decoded = try #require(QQWordLyricCodec.decode(qrcVector))
        let doc = try #require(PlatformWordLyrics.parse(decoded, format: .qrc))
        #expect(doc.lines.count == 2)
        #expect(doc.lines[0].words.map(\.start) == [1, 1.8, 3.1])
        #expect(doc.lines[0].words.map(\.end) == [1.5, 2.4, 5.2])
        #expect(doc.lines[1].text == "Hello world")
        #expect(doc.lines[1].words.map(\.start) == [6, 6.9])
    }

    @Test func qrcCodecRejectsMalformedTruncatedAndOversizedInput() {
        #expect(QQWordLyricCodec.decode("not a lyric") == nil)
        #expect(QQWordLyricCodec.decode("001122") == nil)
        #expect(QQWordLyricCodec.decode(String(qrcVector.dropLast(16))) == nil)
        #expect(QQWordLyricCodec.decode("ffffffffffffffff" + qrcVector.dropFirst(16)) == nil)
        #expect(QQWordLyricCodec.decode(String(repeating: "0", count: LyricsParser.maximumBytes * 2 + 1)) == nil)
    }

    @Test func qrcCodecAcceptsDocumentedPlainAndBase64CompatibilityForms() {
        let raw = "[1000,2000]青(1000,700)山(1800,1200)"
        #expect(QQWordLyricCodec.decode(raw) == raw)
        #expect(QQWordLyricCodec.decode(Data(raw.utf8).base64EncodedString()) == raw)
    }
}

// qrc-decoder revision cabea11ca2c1437858caaf7d51d9611e6a33bd77.
private let qrcVector = "ee7befb746f93831d42dcdf2e21f0d5d977de00c85449a7ceda273406896fa7a6b5070273a7bec21e7029c6a4b69d34548ddb7f3b3aa2bbb02ea88d7b4badbd39d32440dbc92599949c568edec14ce0760c42591ec2b8c4eb628b8dd3f07d777825bf23a7b5f1f38764a185ce7d3d472ae9de69f0d9be22931e5c9ddfa4671325e3981a8dc9d15c96503636262504ac9fa055562690feb49"
