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

    /// Rows from the public NetEase lyric/v1 endpoint (no account). NetEase
    /// gives punctuation, brackets and censored letters no vocal duration.
    @Test func yrcZeroLengthTokensJoinTheWordTheyAreWrittenAgainst() throws {
        let rows: [(row: String, words: [String])] = [
            // 1859245776: a closing bracket at the very end of the sentence.
            ("[0,11460](0,10860,0)（(10860,60,0)The (10920,240,0)Kid (11160,300,0)LAROI(11460,0,0)）",
             ["（", "The ", "Kid ", "LAROI）"]),
            // 1859245776: an opening bracket at the very start.
            ("[44970,420](44970,0,0)（(44970,90,0)The (45060,150,0)Kid (45210,180,0)LAROI(45390,0,0)）",
             ["（The ", "Kid ", "LAROI）"]),
            // 1859245776: censored letters lead into the rest of their word.
            ("[99060,2130](99060,300,0)I'll (99360,270,0)be (99630,0,0)*(99630,0,0)*(99630,0,0)*(99630,0,0)*(99630,90,0)ed (99720,300,0)up (100020,150,0)if (100170,120,0)you (100290,240,0)can't (100530,120,0)be (100650,360,0)right (101010,180,0)here",
             ["I'll ", "be ", "****ed ", "up ", "if ", "you ", "can't ", "be ", "right ", "here"]),
            // 1868553: two zero-length tokens in a row go opposite ways.
            ("[25200,3480](25200,480,0)I'm (25680,510,0)just (26190,210,0)a (26400,930,0)poor (27330,1020,0)boy(28350,0,0), (28350,0,0)（(28350,30,0)oooh(28380,0,0), (28380,180,0)poor (28560,60,0)boy(28620,60,0)）",
             ["I'm ", "just ", "a ", "poor ", "boy, ", "（oooh, ", "poor ", "boy", "）"]),
            ("[196080,1620](196080,900,0)Galileo(196980,0,0), (196980,720,0)galileo", ["Galileo, ", "galileo"]),
            // 1901371647
            ("[212010,1900](212010,220,0)不(212230,200,0)肯(212430,510,0)哭(212940,420,0)一(213360,190,0)场 (213550,0,0)（(213550,60,0)You (213610,80,0)Are (213690,60,0)The (213750,120,0)Hero(213870,40,0)）",
             ["不", "肯", "哭", "一", "场 ", "（You ", "Are ", "The ", "Hero", "）"]),
            ("[221180,3730](221180,430,0)去(221610,740,0)吗(222350,0,0)？(222350,390,0)去(222740,70,0)啊(222810,530,0)！(223340,200,0)以(223540,240,0)最(223780,200,0)卑(223980,270,0)微(224250,160,0)的(224410,500,0)梦",
             ["去", "吗？", "去", "啊", "！", "以", "最", "卑", "微", "的", "梦"]),
            // 5257138: brackets between single CJK characters, one with a space inside.
            ("[277800,2870](277800,340,0)让(278140,390,0)我(278530,310,0)爱(278840,290,0)你(279130,320,0)是(279450,460,0)谁(279910,0,0)（(279910,360,0)是(280270,400,0)我(280670,0,0)）",
             ["让", "我", "爱", "你", "是", "谁", "（是", "我）"]),
            ("[280670,2710](280670,240,0)让(280910,420,0)你(281330,320,0)爱(281650,240,0)我(281890,340,0)是(282230,420,0)谁(282650,0,0)（ (282650,60,0)是(282710,410,0)你(283120,260,0)）",
             ["让", "你", "爱", "我", "是", "谁", "（ 是", "你", "）"])
        ]
        for (row, expected) in rows {
            let document = try #require(PlatformWordLyrics.parse(row, format: .yrc), "\(row)")
            let line = try #require(document.lines.first)
            #expect(document.timing == .word)
            #expect(line.words.map(\.text) == expected)
            #expect(line.text == row.replacing(#/^\[\d+,\d+\]|\(\d+,\d+,\d+\)/#, with: ""))
            // Every start and end is a measured token; zero-length tokens move none.
            let measured = row.matches(of: #/\((\d+),(\d+),\d+\)/#).compactMap { match -> (start: Double, end: Double)? in
                guard let onset = Int(match.1), let length = Int(match.2), length > 0 else { return nil }
                return (Double(onset) / 1_000, Double(onset + length) / 1_000)
            }
            #expect(line.words.map(\.start) == measured.map(\.start))
            #expect(line.words.map(\.end) == measured.map { Optional($0.end) })
        }
    }

    @Test func yrcSongWithZeroLengthTokensKeepsWordTimingAndSkipsCreditRows() throws {
        let text = """
        {"t":0,"c":[{"tx":"作词: "},{"tx":"Someone"}]}
        [0,11460](0,10860,0)（(10860,60,0)The (10920,240,0)Kid (11160,300,0)LAROI(11460,0,0)）
        [44970,420](44970,0,0)（(44970,90,0)The (45060,150,0)Kid (45210,180,0)LAROI(45390,0,0)）
        """
        let document = try #require(PlatformWordLyrics.parse(text, format: .yrc))
        #expect(document.timing == .word)
        #expect(document.lines.map(\.text) == ["（The Kid LAROI）", "（The Kid LAROI）"])
        #expect(document.lines.allSatisfy { !$0.words.isEmpty })
    }

    @Test func yrcRowWithOnlyZeroLengthTokensSpansItsMeasuredSentence() throws {
        let document = try #require(PlatformWordLyrics.parse("[1000,2000](1000,0,0)零", format: .yrc))
        #expect(document.lines[0].words.map(\.text) == ["零"])
        #expect(document.lines[0].words.map(\.start) == [1])
        #expect(document.lines[0].words.map(\.end) == [3])
    }

    @Test func yrcLyricParenthesesAreNotMistakenForTokens() throws {
        let document = try #require(PlatformWordLyrics.parse("[1000,2000](1000,500,0)(Ooh, (1500,500,0)yeah) (2000,1000,0)(oh,oh,oh)", format: .yrc))
        #expect(document.lines[0].words.map(\.text) == ["(Ooh, ", "yeah) ", "(oh,oh,oh)"])
    }

    @Test @MainActor func zeroLengthPunctuationRevealsWithItsWordWithoutMovingMeasuredOnsets() throws {
        func close(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 0.000_1 } == true }
        let latin = try #require(PlatformWordLyrics.parse("[196080,1620](196080,900,0)Galileo(196980,0,0), (196980,720,0)galileo", format: .yrc)).lines[0]
        let spoken = LyricReveal.timeline(for: latin).units.filter { !$0.text.allSatisfy(\.isWhitespace) }
        #expect(spoken.map(\.text).joined() == "Galileo,galileo")
        #expect(close(spoken.first?.start, 196.08))
        // The comma appears as "Galileo" ends, not before and not with the next word's ink.
        let comma = try #require(spoken.first { $0.text == "," })
        #expect(close(comma.start, 196.98) && comma.end == comma.start)
        #expect(close(spoken.first { $0.text == "g" }?.start, 196.98))

        let row = "[277800,2870](277800,340,0)让(278140,390,0)我(278530,310,0)爱(278840,290,0)你(279130,320,0)是(279450,460,0)谁(279910,0,0)（(279910,360,0)是(280270,400,0)我(280670,0,0)）"
        let cjk = try #require(PlatformWordLyrics.parse(row, format: .yrc)).lines[0]
        let timeline = LyricReveal.timeline(for: cjk)
        // Brackets carry no vocal timing to estimate; every spoken character is measured.
        #expect(timeline.isTimed && !timeline.isEstimated)
        #expect(timeline.units.map(\.text).joined() == "让我爱你是谁（是我）")
        let starts: [Double] = [277.8, 278.14, 278.53, 278.84, 279.13, 279.45, 279.91, 279.91, 280.27, 280.67]
        #expect(timeline.units.count == starts.count)
        for (unit, start) in zip(timeline.units, starts) { #expect(close(unit.start, start), "\(unit.text)") }
    }

    @Test func malformedMeasuredDataIsRejectedRatherThanGuessed() {
        for text in [
            "[1000,2000](900,500,0)早", // before the sentence
            "[1000,2000](1000,5000,0)长", // beyond the measured cue
            "[1000,2000](2000,200,0)山(1500,200,0)青", // reversed onsets
            "[1000,2000](2000,0,0)，(1500,200,0)青", // zero-length token after the next onset
            "[1000,2000](1000,500,0)青(3500,0,0)，", // zero-length token beyond the cue
            "[1000,2000](3000,0,0)零", // nothing left to time inside the cue
            "[1000,2000](1000,500,0)青(1500,0,0)", // zero-length token without text
            "[1000,2000](-1000,500,0)青", // negative onset
            "[1000,2000](1000,500,0)青(-1500,500,0)山", // negative onset mid-row
            "[1000,2000](1000,500,0)青(1500,abc,0)山", // non-numeric duration mid-row
            "[1000,2000](1000,500,0)青(1500.5,500,0)山", // fractional onset mid-row
            "[1000,2000](1000,500,0)青\n[2000,1000]missing words", // partial document
            "[86400000,1000](86400000,1000,0)远", // out of range
            "[1000,2000]prefix(1000,500,0)青"
        ] { #expect(PlatformWordLyrics.parse(text, format: .yrc) == nil, "\(text)") }
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
