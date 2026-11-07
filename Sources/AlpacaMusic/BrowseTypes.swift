import Foundation

/// A list the Now page can open: one of a platform's charts, or a playlist or
/// album it recommends. Only metadata; songs load when the list is opened.
struct BrowseCollection: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable, Hashable { case chart, playlist, album }
    var source: MusicSource
    var kind: Kind
    /// The platform's own identifier: a NetEase playlist id, a QQ chart
    /// `topId` or playlist `dissid`, or an Apple Music catalog id.
    var remoteID: String
    var title: String
    /// One short line under the title, such as how often a chart updates or
    /// who curates a playlist. Empty when the platform gives nothing useful.
    var caption: String = ""
    var artworkURL: URL? = nil
    /// The first entries as the platform lists them, so a card can show what
    /// is inside before any song request.
    var preview: [BrowsePreviewLine] = []
    var trackCount: Int? = nil
    /// Songs that arrived with the list itself, such as Apple Music's song
    /// charts. Opening such a list needs no further request.
    var tracks: [Track]? = nil
    var id: String { "\(source.rawValue):\(kind.rawValue):\(remoteID)" }
}

struct BrowsePreviewLine: Sendable, Hashable {
    var title: String
    var artist: String
}

/// What one platform recommends: playlists or albums, and songs where the
/// platform has a daily or personal song list.
struct BrowseRecommendations: Sendable, Equatable {
    var collections: [BrowseCollection] = []
    var songs: [Track] = []
    /// When the platform says these picks change, if it says so (Apple Music).
    var refreshesAt: Date? = nil
    /// Why part of the picks is missing, when one of several requests failed.
    /// The page shows it and asks again after the retry delay.
    var partialError: String? = nil
}

/// How often the Now page may ask a platform again. Nothing polls: lists load
/// when the page shows a source whose copy is missing or past these limits,
/// or when the listener presses refresh.
enum BrowseSchedule {
    /// Charts and picks stay for six hours at most.
    static let listLifetime: TimeInterval = 6 * 60 * 60
    /// A chart's or playlist's songs, once read, stay as long.
    static let tracksLifetime: TimeInterval = 6 * 60 * 60
    /// Daily lists turn over in the early morning; anything read before this
    /// local hour is stale once it passes.
    static let dailyResetHour = 6
    /// After a failure the page waits this long before trying on its own again.
    static let retryDelay: TimeInterval = 2 * 60
    /// The refresh button stays off for this long after a load starts.
    static let refreshCooldown: TimeInterval = 60
    /// How many songs a chart or playlist shows: one platform request each.
    static let trackLimit = 100
    /// Opened lists kept per session before the oldest is dropped.
    static let cachedCollections = 16

    /// A platform hint sooner than this after a read is ignored, so an odd
    /// date cannot make the page ask again within minutes.
    static let shortestHint: TimeInterval = 30 * 60

    /// When a copy read at `fetched` stops being fresh: the earliest of its
    /// lifetime, the next daily reset, and the platform's own hint.
    static func expiry(fetched: Date, lifetime: TimeInterval, hint: Date? = nil, calendar: Calendar = .current) -> Date {
        var result = fetched.addingTimeInterval(lifetime)
        if let reset = calendar.nextDate(after: fetched, matching: DateComponents(hour: dailyResetHour, minute: 0, second: 0),
                                         matchingPolicy: .nextTime), reset < result {
            result = reset
        }
        if let hint, hint >= fetched.addingTimeInterval(shortestHint), hint < result { result = hint }
        return result
    }
}
