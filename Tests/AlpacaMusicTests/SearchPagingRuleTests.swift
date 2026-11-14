import Testing
@testable import AlpacaMusic

@Suite struct SearchPagingRuleTests {
    @Test func qqPagesCountFortyEvenWhenAPageLostADuplicate() {
        #expect(SearchPagingRule.qqPage(after: 0) == 1)
        #expect(SearchPagingRule.qqPage(after: 40) == 2)
        #expect(SearchPagingRule.qqPage(after: 39) == 2)
        #expect(SearchPagingRule.qqPage(after: 79) == 3)
    }

    @Test func aFullPageOffersMoreAndAShortOrEmptyOneEnds() {
        #expect(SearchPagingRule.paging(.netease, returned: 50, total: 50) == .more)
        #expect(SearchPagingRule.paging(.netease, returned: 49, total: 99) == .end)
        #expect(SearchPagingRule.paging(.qq, returned: 38, total: 78) == .more)
        #expect(SearchPagingRule.paging(.qq, returned: 29, total: 69) == .end)
        #expect(SearchPagingRule.paging(.appleMusic, returned: 25, total: 50) == .more)
        #expect(SearchPagingRule.paging(.appleMusic, returned: 24, total: 49) == .end)
        #expect(SearchPagingRule.paging(.netease, returned: 0, total: 300) == .end)
    }

    @Test func qqStopsAtTheNineHundredNinetyNineSongsItReports() {
        #expect(SearchPagingRule.paging(.qq, returned: 40, total: 960) == .more)
        #expect(SearchPagingRule.paging(.qq, returned: 39, total: 999) == .end)
    }

    @Test func otherSourcesGiveOnePage() {
        #expect(SearchPagingRule.paging(.spotify, returned: 30, total: 30) == .unsupported)
    }
}
