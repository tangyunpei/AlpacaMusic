import Foundation

/// Asks the linked services for songs. Tests substitute it, so the results
/// page can be driven without any service.
@MainActor protocol SearchLoading: AnyObject, Sendable {
    /// The linked sources a search asks, in the pills' order.
    func targets(configurations: [SourceConfiguration], includeSodaPublicly: Bool) async -> [MusicSource]
    /// The first page from every target, each handed over as soon as it is in.
    func firstPages(_ term: String, configurations: [SourceConfiguration], includeSodaPublicly: Bool,
                    deliver: @escaping @MainActor (SearchPage) -> Void) async
    /// One source's page, `offset` songs into its results: zero to try a
    /// failed source again, more for "More songs".
    func page(_ term: String, source: MusicSource, offset: Int, configurations: [SourceConfiguration],
              includeSodaPublicly: Bool) async -> SearchPage
    /// False for a service switched off after the search began.
    func isActive(_ source: MusicSource) -> Bool
}

/// The sources' fixed order: in the pills, and when the list takes turns.
enum SearchSourceOrder {
    static let services: [MusicSource] = [.appleMusic, .netease, .qq, .spotify, .soda]
    static func sorted(_ sources: [MusicSource]) -> [MusicSource] {
        sources.sorted { (services.firstIndex(of: $0) ?? services.count) < (services.firstIndex(of: $1) ?? services.count) }
    }
}

/// When a service has more songs, and which page to ask for next.
enum SearchPagingRule {
    /// QQ Music's search reports at most this many songs.
    static let qqLimit = 999
    /// QQ Music pages hold 40 songs; a page that lost a duplicate still counts as a page.
    static func qqPage(after count: Int) -> Int { Int((Double(max(0, count)) / 40).rounded(.up)) + 1 }
    /// Whether to offer another page after a page of `returned` songs, `total` in all so far.
    static func paging(_ source: MusicSource, returned: Int, total: Int) -> SearchPaging {
        guard returned > 0 else { return .end }
        switch source {
        case .appleMusic: return returned < 25 ? .end : .more // AppleMusicService.catalogSearchLimit
        case .netease: return returned < 50 ? .end : .more
        // Duplicates removed can shorten a QQ page that still has more behind it.
        case .qq: return returned < 30 || total >= qqLimit ? .end : .more
        default: return .unsupported
        }
    }
}

/// The app's services. Apple Music pages through its documented catalog
/// search; a signed-in NetEase or QQ Music pages through the same song search
/// with an offset or page number (tried live on 14 November 2026). Custom
/// servers and Spotify give their first page only.
@MainActor final class PlatformSearchLoader: SearchLoading {
    private let sources: SourceService
    private let appleMusic: AppleMusicService
    private let spotify: SpotifyService
    private let native: NativeMusicClient?

    init(sources: SourceService, appleMusic: AppleMusicService, spotify: SpotifyService, native: NativeMusicClient? = nil) {
        self.sources = sources; self.appleMusic = appleMusic; self.spotify = spotify; self.native = native
    }

    func targets(configurations: [SourceConfiguration], includeSodaPublicly: Bool) async -> [MusicSource] {
        var targets = await sources.searchTargets(configurations: configurations, includeSodaPublicly: includeSodaPublicly)
        if appleMusic.isEnabled { targets.append(.appleMusic) }
        if spotify.isEnabled { targets.append(.spotify) }
        return SearchSourceOrder.sorted(targets)
    }

    func firstPages(_ term: String, configurations: [SourceConfiguration], includeSodaPublicly: Bool,
                    deliver: @escaping @MainActor (SearchPage) -> Void) async {
        let service = sources, apple = appleMusic, spotifyService = spotify
        let includeApple = apple.isEnabled, includeSpotify = spotifyService.isEnabled
        // Only a signed-in account pages; a custom server for the same platform does not.
        let signedIn = await native?.connectedSources() ?? []
        let hand: @MainActor @Sendable (SourceSearchResult) -> Void = { result in deliver(Self.page(result, pages: signedIn.contains(result.source))) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await service.search(term, configurations: configurations, includeSodaPublicly: includeSodaPublicly, onResult: hand)
            }
            if includeApple {
                group.addTask { await deliver(await Self.applePage(apple, term: term, offset: 0)) }
            }
            if includeSpotify {
                group.addTask { await deliver(await Self.spotifyPage(spotifyService, term: term)) }
            }
            await group.waitForAll()
        }
    }

    func page(_ term: String, source: MusicSource, offset: Int, configurations: [SourceConfiguration],
              includeSodaPublicly: Bool) async -> SearchPage {
        switch source {
        case .appleMusic: return await Self.applePage(appleMusic, term: term, offset: offset)
        case .spotify where offset == 0: return await Self.spotifyPage(spotify, term: term)
        case .netease where offset > 0, .qq where offset > 0:
            guard let native, await native.connectedSources().contains(source) else { return SearchPage(source: source, tracks: [], paging: .unsupported) }
            do {
                let tracks = try await native.searchPage(term, source: source, offset: offset)
                return SearchPage(source: source, tracks: tracks, paging: SearchPagingRule.paging(source, returned: tracks.count, total: offset + tracks.count))
            }
            catch is CancellationError { return SearchPage(source: source, tracks: [], paging: .more) }
            catch { return SearchPage(source: source, tracks: [], error: error.localizedDescription, paging: .more) }
        case _ where offset > 0: return SearchPage(source: source, tracks: [], paging: .unsupported)
        default:
            let signedIn = await native?.connectedSources() ?? []
            let results = await sources.search(term, configurations: configurations, includeSodaPublicly: includeSodaPublicly)
            return results.first { $0.source == source }.map { Self.page($0, pages: signedIn.contains(source)) }
                ?? SearchPage(source: source, tracks: [], error: L10n.string("没有回应"))
        }
    }

    func isActive(_ source: MusicSource) -> Bool {
        switch source {
        case .spotify: spotify.isEnabled
        case .appleMusic: appleMusic.isEnabled
        default: true
        }
    }

    /// A signed-in NetEase or QQ Music pages on; a full first page from a
    /// custom server may have more behind it that it cannot ask for.
    private static func page(_ result: SourceSearchResult, pages: Bool) -> SearchPage {
        let count = result.tracks.count
        let paging = pages ? SearchPagingRule.paging(result.source, returned: count, total: count)
            : count >= (result.source == .qq ? 40 : 50) ? .unsupported : .end
        return SearchPage(source: result.source, tracks: result.tracks, error: result.error, paging: paging)
    }

    private static func applePage(_ service: AppleMusicService, term: String, offset: Int) async -> SearchPage {
        do {
            let tracks = offset == 0 ? try await service.search(term) : try await service.searchPage(term, offset: offset)
            return SearchPage(source: .appleMusic, tracks: tracks,
                              paging: SearchPagingRule.paging(.appleMusic, returned: tracks.count, total: offset + tracks.count))
        }
        catch is CancellationError { return SearchPage(source: .appleMusic, tracks: []) }
        catch { return SearchPage(source: .appleMusic, tracks: [], error: AppleMusicErrorMessage.describe(error)) }
    }

    private static func spotifyPage(_ service: SpotifyService, term: String) async -> SearchPage {
        do {
            let tracks = try await service.search(term)
            return SearchPage(source: .spotify, tracks: tracks, paging: tracks.count >= 30 ? .unsupported : .end)
        }
        catch is CancellationError { return SearchPage(source: .spotify, tracks: []) }
        catch { return SearchPage(source: .spotify, tracks: [], error: SpotifyService.message(error)) }
    }
}
