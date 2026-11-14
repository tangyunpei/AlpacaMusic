import Testing
@testable import AlpacaMusic

private func page(_ source: MusicSource, _ credits: [(artist: String, count: Int)], title: String = "Song") -> (source: MusicSource, tracks: [Track]) {
    var tracks: [Track] = []
    for (artist, count) in credits {
        for index in 0..<count {
            tracks.append(Track(id: "\(source.rawValue):\(artist):\(index)", title: "\(title) \(tracks.count)", artist: artist,
                                album: "", duration: 200, source: source))
        }
    }
    return (source, tracks)
}

@Suite struct SingerRuleTests {
    @Test func creditsSplitDuetsAndKeepEachNameOnce() {
        #expect(SingerRule.credits("谭米洛 / 林栖") == ["谭米洛", "林栖"])
        #expect(SingerRule.credits("Milo Tan & Lin Qi") == ["Milo Tan", "Lin Qi"])
        #expect(SingerRule.credits("AC/DC") == ["AC/DC"])
        #expect(SingerRule.credits("Milo / milo") == ["Milo"])
    }

    @Test func oneNameLeadingEveryServiceGivesACardThatJoinsSpellings() {
        let pages = [page(.appleMusic, [("Milo Tan", 22), ("Other", 3)]),
                     page(.netease, [("谭米洛", 40), ("谭米洛 / 林栖", 6), ("林栖", 4)]),
                     page(.qq, [("谭米洛", 40)])]
        guard case .singer(let card) = SingerRule.shape(term: "Milo Tang", pages: pages) else {
            Issue.record("expected a singer card"); return
        }
        #expect(card.names == ["Milo Tan", "谭米洛"])
        #expect(card.joinsNames)
        #expect(card.evidence.map(\.count) == [22, 46, 40])
        #expect(card.evidence.map(\.total) == [25, 50, 40])
        // "Not one singer?" gives one card per spelling.
        #expect(card.split.map(\.names) == [["Milo Tan"], ["谭米洛"]])
        #expect(card.split[1].evidence.map(\.source) == [.netease, .qq])
    }

    @Test func aNameUnderTheShareOrCountLeadsNothing() {
        // 59% of the songs: not a leader.
        let short = SingerRule.shape(term: "x", pages: [page(.netease, [("A", 59), ("B", 41)])])
        guard case .singers = short else { Issue.record("expected the singers line"); return }
        // Seven of eight songs is over the share but under eight songs.
        let few = SingerRule.shape(term: "x", pages: [page(.netease, [("A", 7), ("B", 1)])])
        guard case .singers = few else { Issue.record("expected the singers line"); return }
    }

    @Test func aServiceWithFewSongsHasNoSay() {
        let pages = [page(.netease, [("谭米洛", 30)]), page(.appleMusic, [("Someone", 2), ("Else", 3)])]
        guard case .singer(let card) = SingerRule.shape(term: "Milo", pages: pages) else {
            Issue.record("expected a singer card"); return
        }
        #expect(card.evidence.map(\.source) == [.netease])
    }

    @Test func aSongTitleSearchGetsTheSingersLineInstead() {
        // Every song is called 雨停之前 and one singer sings most of them.
        let pages = [page(.netease, [("谭米洛", 26), ("林栖", 12), ("白川", 9)], title: "雨停之前"),
                     page(.qq, [("谭米洛", 30)], title: "雨停之前")]
        guard case .singers(let names, let more) = SingerRule.shape(term: "雨停之前", pages: pages) else {
            Issue.record("expected the singers line"); return
        }
        #expect(names.map(\.name) == ["谭米洛", "林栖", "白川"])
        #expect(names.map(\.count) == [56, 12, 9])
        #expect(more == 0)
    }

    @Test func theSingersLineNamesFiveAndCountsTheRest() {
        let pages = [page(.netease, (0..<8).map { ("Singer \($0)", 8 - $0) })]
        guard case .singers(let names, let more) = SingerRule.shape(term: "x", pages: pages) else {
            Issue.record("expected the singers line"); return
        }
        #expect(names.count == 5)
        #expect(names.first?.name == "Singer 0")
        #expect(more == 3)
    }

    @Test func noSongsShowNothingAboveTheList() {
        #expect(SingerRule.shape(term: "xqzvk", pages: [(.netease, []), (.qq, [])]) == .songs)
    }
}
