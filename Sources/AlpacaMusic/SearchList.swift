import Foundation

/// How far a service's song search can go past what it has returned.
enum SearchPaging: Equatable, Sendable {
    /// A full page came back and the service can be asked for the next one.
    case more
    /// The service returned all it has.
    case end
    /// The service may have more, but this version cannot ask for it.
    case unsupported
}

/// One service's answer for one page of a song search.
struct SearchPage: Sendable {
    var source: MusicSource
    var tracks: [Track]
    var error: String? = nil
    var paging: SearchPaging = .end
}

/// Where a copy in a row came from: the library match, or a service's search.
enum SearchOrigin: Hashable, Sendable {
    case library
    case service(MusicSource)
}

/// One copy of a song in a row, with its place in its own source's list.
struct SearchCopy: Equatable, Sendable {
    var track: Track
    var origin: SearchOrigin
    var rank: Int
}

/// One row of the results: one song, with each source's copy of it. The first
/// copy is the one that plays and is saved.
struct SearchRow: Identifiable, Equatable, Sendable {
    var copies: [SearchCopy]
    /// In the library when the row first appeared. It stays as it was, so the
    /// Library and Not saved pills never move or drop a row after a like or an add.
    var savedAtArrival: Bool

    var id: String { copies[0].track.id }
    var track: Track { copies[0].track }
    /// The sources of the copies' songs, first copy first, each once.
    var sources: [MusicSource] {
        var seen = Set<MusicSource>()
        return copies.map(\.track.source).filter { seen.insert($0).inserted }
    }
    func rank(in source: MusicSource) -> Int? {
        copies.first { $0.origin == .service(source) }?.rank
    }
}

/// The pills above the list: everything, the library's songs, the songs not
/// yet saved, or one linked service.
enum SearchFilter: Hashable, Sendable {
    case all, library, notSaved
    case source(MusicSource)
}

/// The rules that turn the sources' answers into one list of rows.
enum SearchList {
    /// Case, accents and width do not count.
    static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Two copies are the same song when their folded title and folded singer are equal.
    static func key(_ track: Track) -> String { fold(track.title) + "\u{1F}" + fold(track.artist) }

    /// The sources take turns: each one's first, then each one's second, and so
    /// on, skipping a source that has run out. Each keeps its own order.
    static func takeTurns<Item>(_ lists: [[Item]]) -> [Item] {
        var result: [Item] = []
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count { result.append(list[index]) }
        }
        return result
    }

    /// Adds copies below the rows already there, in the order given. A copy of
    /// a song a row already holds joins that row instead, unless the row has a
    /// copy from the same origin (two songs one service calls the same stay two
    /// rows). Rows already there never move.
    static func append(_ copies: [SearchCopy], to rows: inout [SearchRow], isSaved: (Track) -> Bool) {
        var byID: [String: Int] = [:], byKey: [String: [Int]] = [:]
        for (index, row) in rows.enumerated() {
            for copy in row.copies {
                byID[copy.track.id] = index
                byKey[key(copy.track), default: []].append(index)
            }
        }
        for copy in copies {
            if let index = byID[copy.track.id] {
                // The very same song: the row already shows it; only note the origin.
                if !rows[index].copies.contains(where: { $0.origin == copy.origin }) { rows[index].copies.append(copy) }
                continue
            }
            let copyKey = key(copy.track)
            if !fold(copy.track.title).isEmpty,
               let index = byKey[copyKey]?.first(where: { candidate in !rows[candidate].copies.contains { $0.origin == copy.origin } }) {
                rows[index].copies.append(copy)
                byID[copy.track.id] = index
                continue
            }
            rows.append(SearchRow(copies: [copy], savedAtArrival: isSaved(copy.track)))
            byID[copy.track.id] = rows.count - 1
            byKey[copyKey, default: []].append(rows.count - 1)
        }
    }

    /// The rows a pill shows. One service shows its own order; the others keep the list's.
    static func filter(_ rows: [SearchRow], by filter: SearchFilter) -> [SearchRow] {
        switch filter {
        case .all: rows
        case .library: rows.filter(\.savedAtArrival)
        case .notSaved: rows.filter { !$0.savedAtArrival }
        case .source(let source):
            rows.compactMap { row in row.rank(in: source).map { (row, $0) } }
                .enumerated()
                .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
                .map(\.element.0)
        }
    }

    /// Library songs whose title, singer or album contains the term.
    static func libraryMatches(_ tracks: [Track], term: String) -> [Track] {
        tracks.filter { "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(term) }
    }
}
