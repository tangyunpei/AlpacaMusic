import Foundation

/// One service's entry for a singer.
struct SingerProfile: Identifiable, Hashable, Sendable {
    var source: MusicSource
    /// The service's own identifier: a NetEase artist id, a QQ Music singer
    /// mid, or an Apple Music catalog id.
    var remoteID: String
    var name: String
    var aliases: [String] = []
    var pictureURL: URL? = nil
    var albumCount: Int? = nil
    var songCount: Int? = nil
    var id: String { "\(source.rawValue):\(remoteID)" }
}

/// A release date as precise as the service gives it.
struct ReleaseDate: Hashable, Sendable, Comparable {
    var year: Int
    var month: Int?
    var day: Int?

    /// "2025-03-24", "2025-03" or "2025".
    init?(text: String) {
        let parts = text.split(separator: "-").map { Int($0) }
        guard let first = parts.first, let year = first, (1000...9999).contains(year) else { return nil }
        self.year = year
        month = parts.count > 1 ? parts[1].flatMap { (1...12).contains($0) ? $0 : nil } : nil
        day = month != nil && parts.count > 2 ? parts[2].flatMap { (1...31).contains($0) ? $0 : nil } : nil
    }
    init(year: Int, month: Int? = nil, day: Int? = nil) { self.year = year; self.month = month; self.day = day }
    /// A moment given in milliseconds, read in China's time zone, where both
    /// NetEase and QQ Music publish.
    init?(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: milliseconds / 1000))
        guard let year = parts.year else { return nil }
        self.init(year: year, month: parts.month, day: parts.day)
    }
    init(date: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 0, month: parts.month, day: parts.day)
    }

    /// Year-only stands after the dated releases of the same year.
    private var key: (Int, Int, Int) { (year, month ?? 0, day ?? 0) }
    static func < (lhs: ReleaseDate, rhs: ReleaseDate) -> Bool { lhs.key < rhs.key }

    /// "Mar 2025" or "2025", in the app's language.
    var shortText: String {
        guard let month else { return String(year) }
        var parts = DateComponents(); parts.year = year; parts.month = month; parts.day = 1
        guard let date = Calendar(identifier: .gregorian).date(from: parts) else { return String(year) }
        return date.formatted(.dateTime.year().month(.abbreviated).locale(L10n.language.locale))
    }
}

/// One service's copy of an album or single.
struct SingerAlbum: Identifiable, Hashable, Sendable {
    var source: MusicSource
    var remoteID: String
    var name: String
    var artist: String
    var date: ReleaseDate?
    var trackCount: Int? = nil
    var artworkURL: URL? = nil
    /// The service's own word for it: an album, a single, an EP.
    var kind: String = ""
    var id: String { "\(source.rawValue):\(remoteID)" }
    var remote: RemoteMusicAlbum {
        RemoteMusicAlbum(id: remoteID, name: name, artist: artist, trackCount: trackCount, artworkURL: artworkURL, source: source)
    }
}

/// A page of a singer's albums or songs.
struct SingerPage<Item: Sendable>: Sendable {
    var items: [Item]
    var more: Bool
}

/// The rules for showing a singer's albums.
enum AlbumOrder {
    /// Newest first. A year-only date stands after the dated albums of that
    /// year; an album with no date goes last. Copies of one album from
    /// different services stand together, at the place of the newest copy,
    /// in the services' fixed order. Copies are one album when their folded
    /// names are equal.
    static func sorted(_ albums: [SingerAlbum]) -> [SingerAlbum] {
        var groups: [String: [SingerAlbum]] = [:], order: [String] = []
        for album in albums {
            let key = SearchList.fold(album.name)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(album)
        }
        let services = SearchSourceOrder.services
        func rank(_ source: MusicSource) -> Int { services.firstIndex(of: source) ?? services.count }
        let ranked = order.enumerated().map { index, key -> (Int, ReleaseDate?, [SingerAlbum]) in
            let copies = (groups[key] ?? []).sorted { rank($0.source) < rank($1.source) }
            return (index, copies.compactMap(\.date).max(), copies)
        }
        return ranked.sorted { a, b in
            switch (a.1, b.1) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.0 < b.0
            }
        }.flatMap(\.2)
    }

    /// The newest release across services; a dated one wins over its year alone.
    static func latest(_ albums: [SingerAlbum]) -> SingerAlbum? { sorted(albums).first }
}
