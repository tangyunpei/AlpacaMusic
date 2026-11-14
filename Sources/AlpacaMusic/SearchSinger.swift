import Foundation

/// One service's support for a singer: the name it credits and on how many of
/// the songs it returned.
struct SingerEvidence: Equatable, Sendable {
    var source: MusicSource
    var name: String
    var count: Int
    var total: Int
}

/// The singer the results point to. No service says two names are one person,
/// so a card with more than one name is a guess the listener can undo.
struct SingerCard: Equatable, Sendable {
    var evidence: [SingerEvidence]
    /// Each spelling once, in the services' fixed order.
    var names: [String] {
        var seen = Set<String>()
        return evidence.map(\.name).filter { seen.insert(SearchList.fold($0)).inserted }
    }
    var joinsNames: Bool { names.count > 1 }
    /// The card split by spelling, for "Not one singer?".
    var split: [SingerCard] {
        names.map { name in SingerCard(evidence: evidence.filter { SearchList.fold($0.name) == SearchList.fold(name) }) }
    }
}

struct SingerCount: Equatable, Sendable {
    var name: String
    var count: Int
}

/// What the page shows above the songs, read from the songs alone.
enum SearchShape: Equatable, Sendable {
    /// One name leads each service's songs: a singer card.
    case singer(SingerCard)
    /// No single singer: the singers credited in these songs, most first.
    case singers([SingerCount], more: Int)
    /// Nothing to show above the songs.
    case songs
}

/// Reads the singer from the credits on each service's first page of songs,
/// with no singer lookup. The numbers are the designer's first guesses and
/// have not been tried on real results.
enum SingerRule {
    /// A service with fewer songs than this has no say.
    static let minimumSongs = 8
    /// A name leads a service's songs when it is credited on this share of them.
    static let leadShare = 0.6
    /// When the typed text is in this share of a service's titles, it was a song search.
    static let titleShare = 0.5
    /// Singers named on the line before "N more".
    static let lineLength = 5

    /// The names in one credit: "A / B", "A & B", "A, B", "A、B".
    static func credits(_ artist: String) -> [String] {
        var parts = [artist]
        for separator in [" / ", " & ", ", ", "，", "、", " feat. ", " ft. "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        var seen = Set<String>()
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(SearchList.fold($0)).inserted }
    }

    /// Each credited name and on how many of these songs, most first; ties keep
    /// the order the names first appear in.
    static func counts(_ tracks: [Track]) -> [SingerCount] {
        var order: [String] = [], names: [String: String] = [:], totals: [String: Int] = [:]
        for track in tracks {
            for name in credits(track.artist) {
                let key = SearchList.fold(name)
                if names[key] == nil { names[key] = name; order.append(key) }
                totals[key, default: 0] += 1
            }
        }
        return order.enumerated()
            .sorted { (totals[$0.element] ?? 0, -$0.offset) > (totals[$1.element] ?? 0, -$1.offset) }
            .map { SingerCount(name: names[$0.element] ?? $0.element, count: totals[$0.element] ?? 0) }
    }

    static func shape(term: String, pages: [(source: MusicSource, tracks: [Track])]) -> SearchShape {
        let query = SearchList.fold(term)
        var evidence: [SingerEvidence] = [], voters = 0, leaderless = false
        for page in pages where page.tracks.count >= minimumSongs {
            voters += 1
            let total = page.tracks.count
            let titled = page.tracks.filter { !query.isEmpty && SearchList.fold($0.title).contains(query) }.count
            if Double(titled) >= Double(total) * titleShare { leaderless = true; continue }
            guard let leader = counts(page.tracks).first,
                  leader.count >= minimumSongs, Double(leader.count) >= Double(total) * leadShare else { leaderless = true; continue }
            evidence.append(SingerEvidence(source: page.source, name: leader.name, count: leader.count, total: total))
        }
        if voters > 0, !leaderless { return .singer(SingerCard(evidence: evidence)) }
        let all = counts(pages.flatMap(\.tracks))
        guard !all.isEmpty else { return .songs }
        return .singers(Array(all.prefix(lineLength)), more: max(0, all.count - lineLength))
    }
}
