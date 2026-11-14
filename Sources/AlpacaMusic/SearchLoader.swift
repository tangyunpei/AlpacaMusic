import Foundation

/// Asks the linked services for songs. Tests substitute it, so the results
/// page can be driven without any service.
@MainActor protocol SearchLoading: AnyObject {
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

/// The app's services. NetEase, QQ Music and custom servers are asked for
/// their first page only, through the same call as before; Apple Music pages
/// through its documented catalog search.
@MainActor final class PlatformSearchLoader: SearchLoading {
    private let sources: SourceService
    private let appleMusic: AppleMusicService
    private let spotify: SpotifyService

    init(sources: SourceService, appleMusic: AppleMusicService, spotify: SpotifyService) {
        self.sources = sources; self.appleMusic = appleMusic; self.spotify = spotify
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
        let hand: @MainActor @Sendable (SourceSearchResult) -> Void = { result in deliver(Self.page(result)) }
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
        case _ where offset > 0: return SearchPage(source: source, tracks: [], paging: .unsupported)
        default:
            let results = await sources.search(term, configurations: configurations, includeSodaPublicly: includeSodaPublicly)
            return results.first { $0.source == source }.map(Self.page)
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

    /// A full first page from NetEase, QQ Music or a custom server may have
    /// more behind it, which this version cannot ask for yet.
    private static func page(_ result: SourceSearchResult) -> SearchPage {
        let full = result.tracks.count >= (result.source == .qq ? 40 : 50)
        return SearchPage(source: result.source, tracks: result.tracks, error: result.error, paging: full ? .unsupported : .end)
    }

    private static func applePage(_ service: AppleMusicService, term: String, offset: Int) async -> SearchPage {
        do {
            let tracks = offset == 0 ? try await service.search(term) : try await service.searchPage(term, offset: offset)
            return SearchPage(source: .appleMusic, tracks: tracks,
                              paging: tracks.count >= AppleMusicService.catalogSearchLimit ? .more : .end)
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
