import Testing
@testable import AlpacaMusic

private func song(_ id: String, _ title: String, _ artist: String = "谭米洛", source: MusicSource = .netease) -> Track {
    Track(id: id, title: title, artist: artist, album: "", duration: 200, source: source)
}
private func copies(_ tracks: [Track], _ origin: SearchOrigin) -> [SearchCopy] {
    tracks.enumerated().map { SearchCopy(track: $1, origin: origin, rank: $0) }
}

@Suite struct SearchListTests {
    @Test func sourcesTakeTurnsAndSkipOneThatRanOut() {
        let order = SearchList.takeTurns([["L1"], ["A1", "A2", "A3"], ["N1", "N2"]])
        #expect(order == ["L1", "A1", "N1", "A2", "N2", "A3"])
    }

    @Test func theSameTitleAndSingerFromTwoServicesIsOneRow() {
        var rows: [SearchRow] = []
        let netease = song("netease:1", "雨停之前"), qq = song("qq:1", "雨停之前 ", source: .qq)
        let apple = song("appleMusic:1", "Before the Rain Stops", "Milo Tan", source: .appleMusic)
        let order = SearchList.takeTurns([copies([netease], .service(.netease)), copies([qq, apple], .service(.qq))])
        SearchList.append(order, to: &rows, isSaved: { _ in false })
        #expect(rows.count == 2)
        #expect(rows[0].copies.map(\.track.id) == ["netease:1", "qq:1"])
        #expect(rows[0].sources == [.netease, .qq])
        // The first copy plays and is saved.
        #expect(rows[0].track.id == "netease:1")
        // A copy titled in another language stays a separate row.
        #expect(rows[1].track.id == "appleMusic:1")
    }

    @Test func caseWidthAndAccentsDoNotSplitASong() {
        var rows: [SearchRow] = []
        SearchList.append(copies([song("a", "Café ＴＩＤＥ", "Milo")], .service(.netease)) + copies([song("b", "cafe tide", "MILO", source: .qq)], .service(.qq)),
                          to: &rows, isSaved: { _ in false })
        #expect(rows.count == 1)
    }

    @Test func twoSongsOneServiceCallsTheSameStayTwoRows() {
        var rows: [SearchRow] = []
        SearchList.append(copies([song("netease:1", "夜航"), song("netease:2", "夜航")], .service(.netease)), to: &rows, isSaved: { _ in false })
        #expect(rows.map(\.id) == ["netease:1", "netease:2"])
    }

    @Test func aLibrarySongKeepsItsPlaceAndALaterServiceJoinsIt() {
        var rows: [SearchRow] = []
        let saved = song("netease:7", "夜航")
        SearchList.append(copies([saved], .library), to: &rows, isSaved: { $0.id == saved.id })
        SearchList.append(copies([song("qq:9", "夜航", source: .qq), song("netease:7", "夜航")], .service(.qq)), to: &rows, isSaved: { _ in false })
        #expect(rows.count == 1)
        #expect(rows[0].track.id == "netease:7")
        #expect(rows[0].savedAtArrival)
    }

    @Test func rowsAddedLaterGoBelowAndNothingAboveMoves() {
        var rows: [SearchRow] = []
        SearchList.append(copies([song("netease:1", "A"), song("netease:2", "B")], .service(.netease)), to: &rows, isSaved: { _ in false })
        let before = rows.map(\.id)
        SearchList.append(copies([song("qq:5", "C", source: .qq), song("qq:6", "A", source: .qq)], .service(.qq)), to: &rows, isSaved: { _ in false })
        #expect(Array(rows.map(\.id).prefix(2)) == before)
        #expect(rows.map(\.id) == ["netease:1", "netease:2", "qq:5"])
        #expect(rows[0].sources == [.netease, .qq])
    }

    @Test func libraryAndNotSavedAreFixedWhenARowArrives() {
        var rows: [SearchRow] = []
        var saved: Set<String> = ["netease:1"]
        SearchList.append(copies([song("netease:1", "A"), song("netease:2", "B")], .service(.netease)), to: &rows, isSaved: { saved.contains($0.id) })
        // Liking B saves it; its row stays under Not saved and out of Library.
        saved.insert("netease:2")
        #expect(SearchList.filter(rows, by: .library).map(\.id) == ["netease:1"])
        #expect(SearchList.filter(rows, by: .notSaved).map(\.id) == ["netease:2"])
    }

    @Test func oneServiceShowsItsOwnOrder() {
        var rows: [SearchRow] = []
        let netease = copies([song("netease:1", "A"), song("netease:2", "B")], .service(.netease))
        let qq = copies([song("qq:1", "B", source: .qq), song("qq:2", "A", source: .qq)], .service(.qq))
        SearchList.append(SearchList.takeTurns([netease, qq]), to: &rows, isSaved: { _ in false })
        // Turns: NetEase's A, QQ Music's B; then NetEase's B and QQ Music's A join those rows.
        #expect(rows.map(\.id) == ["netease:1", "qq:1"])
        #expect(rows.allSatisfy { $0.copies.count == 2 })
        #expect(SearchList.filter(rows, by: .source(.netease)).map(\.id) == ["netease:1", "qq:1"])
        #expect(SearchList.filter(rows, by: .source(.qq)).map(\.id) == ["qq:1", "netease:1"])
        #expect(SearchList.filter(rows, by: .source(.appleMusic)).isEmpty)
    }
}
