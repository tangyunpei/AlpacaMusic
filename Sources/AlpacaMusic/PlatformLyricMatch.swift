import Foundation

/// Apple Music offers no word timing, so its songs would otherwise only get
/// LRCLIB lines with estimated word progress. When NetEase Cloud Music or QQ
/// Music is signed in, find the same recording there and use its measured
/// word timing. A match needs the title, an artist and the duration (within
/// two seconds) to agree, and the lyrics must be word-timed. Anything less
/// falls back to LRCLIB rather than risk timing from another recording.
enum PlatformLyricMatch {
    /// Searched in this order; the first word-timed match wins.
    static let sources: [MusicSource] = [.netease, .qq]
    static let durationTolerance = 2.0
    /// Apple Music often credits Chinese, Japanese and Korean artists in
    /// English ("Jay Chou" for 周杰伦), so names in different scripts cannot
    /// be compared. Such a candidate also needs a near-identical duration and
    /// must be the platform's first result with that title: the search
    /// includes the English name, which the platform resolves to the artist,
    /// while covers and re-uploads with copied durations rank below it.
    static let unverifiedArtistTolerance = 1.5
    /// Lyrics for at most this many matching recordings are requested.
    static let candidateLimit = 2

    enum Outcome: Sendable {
        case found(LyricDocument)
        /// No matching recording with word timing; worth remembering.
        case missing
        /// A network, session or time-limit failure; worth retrying later.
        case failed
    }

    static func canSearch(_ track: Track) -> Bool {
        track.duration.isFinite && (1...3600).contains(track.duration)
            && !baseTitle(track.title).isEmpty && !artistNames(track.artist).isEmpty
            && [track.title, track.artist, track.album].allSatisfy { $0.utf8.count <= 2048 }
    }

    /// Search with the title without bracketed notes and the first artist,
    /// which platforms rank more reliably than Apple Music's full credits.
    static func query(for track: Track) -> String {
        let title = baseTitle(track.title, folded: false)
        let artist = artistNames(track.artist, folded: false).first ?? ""
        return String("\(title) \(artist)".trimmingCharacters(in: .whitespaces).prefix(120))
    }

    /// Candidates that are the same recording: a matching artist first, then
    /// the closest duration, then the platform's search order.
    static func matches(for track: Track, in results: [Track]) -> [Track] {
        guard canSearch(track) else { return [] }
        let title = titleKey(LRCLIBClient.normalized(track.title)), base = titleKey(baseTitle(track.title))
        let artists = artistNames(track.artist)
        let edition = isEdition(track), cover = isCover(track)
        func sameTitle(_ candidate: Track) -> Bool {
            titleKey(LRCLIBClient.normalized(candidate.title)) == title || titleKey(baseTitle(candidate.title)) == base
        }
        let firstTitled = results.firstIndex(where: sameTitle)
        let matching = results.enumerated().compactMap { offset, candidate -> (verified: Bool, gap: Double, offset: Int, track: Track)? in
            let gap = abs(candidate.duration - track.duration)
            guard candidate.duration.isFinite, candidate.duration > 0, gap <= durationTolerance,
                  isEdition(candidate) == edition, isCover(candidate) == cover, sameTitle(candidate) else { return nil }
            let names = artistNames(candidate.artist)
            if artists.contains(where: { artist in names.contains { sameName(artist, $0) } }) {
                return (true, gap, offset, candidate)
            }
            // Only an English credit for a name the platform writes natively.
            let otherScript = !artists.contains(where: isNative) && !names.isEmpty && names.allSatisfy(isNative)
            guard otherScript, gap <= unverifiedArtistTolerance, offset == firstTitled else { return nil }
            return (false, gap, offset, candidate)
        }
        return matching.sorted {
            if $0.verified != $1.verified { return $0.verified }
            return $0.gap != $1.gap ? $0.gap < $1.gap : $0.offset < $1.offset
        }.map(\.track)
    }

    /// Word timing on most timed lines, ending within the Apple Music song.
    static func isUsable(_ document: LyricDocument, for track: Track) -> Bool {
        guard document.timing == .word, !document.isInstrumental else { return false }
        let timed = document.lines.filter { $0.start != nil }
        guard !timed.isEmpty else { return false }
        let worded = timed.filter(LyricEmphasis.hasUsableWordTiming).count
        guard worded * 2 >= timed.count else { return false }
        let last = timed.compactMap(\.start).max() ?? 0
        return last <= track.duration + durationTolerance
    }

    static func sourceDescription(_ source: MusicSource) -> String {
        L10n.string("\(source.title) · 逐字")
    }

    /// One platform, bounded by `deadline` so a slow service never holds back
    /// the LRCLIB fallback for long.
    static func lookup(_ track: Track, scope: LyricsSessionScope, client: NativeMusicClient,
                       deadline: Duration) async -> Outcome {
        await withTaskGroup(of: Outcome?.self) { group in
            group.addTask { await attempt(track, scope: scope, client: client) }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failed
        }
    }

    private static func attempt(_ track: Track, scope: LyricsSessionScope, client: NativeMusicClient) async -> Outcome {
        do {
            let results = try await client.search(query(for: track), source: scope.source)
            for candidate in matches(for: track, in: results).prefix(candidateLimit) {
                try Task.checkCancellation()
                guard let payload = try await client.lyrics(candidate, scope: scope),
                      let document = payload.document, isUsable(document, for: track) else { continue }
                let described = try LyricsParser.parse(LyricsPayload(text: "", document: document),
                                                       sourceDescription: sourceDescription(scope.source))
                return .found(described)
            }
            try Task.checkCancellation()
            return .missing
        } catch { return .failed }
    }

    /// The title without bracketed notes ("(feat. …)", "[Live]", "（电视剧插曲）")
    /// or a " - …" suffix.
    static func baseTitle(_ value: String, folded: Bool = true) -> String {
        var text = folded ? LRCLIBClient.normalized(value) : value
        text = text.replacingOccurrences(of: #"\s*[(（\[【][^)）\]】]*[)）\]】]"#, with: " ", options: .regularExpression)
        if let dash = text.range(of: " - ") { text = String(text[..<dash.lowerBound]) }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Titles compared without spaces or punctuation: "爸，我回来了" and "爸我回來了".
    private static func titleKey(_ value: String) -> String {
        String(value.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }.map(Character.init))
    }

    /// Individual credited names: "A & B", "A / B", "A, B", "A feat. B", and a
    /// bracketed alias such as "정바스 (J.BASS)".
    static func artistNames(_ value: String, folded: Bool = true) -> [String] {
        let text = folded ? LRCLIBClient.normalized(value) : value.trimmingCharacters(in: .whitespacesAndNewlines)
        let separated = text.replacingOccurrences(
            of: #"\s*(?:/|&|＆|,|，|、|;|；|\+|×|[(（)）]|\s(?:feat\.?|ft\.?|featuring|with|x)\s)\s*"#,
            with: "\u{1}", options: [.regularExpression, .caseInsensitive])
        return separated.split(separator: "\u{1}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The same name (ignoring name dots, as in "羽·泉"), the same words in
    /// another order, or the same Chinese, Japanese or Korean part of a mixed
    /// credit ("Keung To 姜涛" and "姜涛").
    static func sameName(_ left: String, _ right: String) -> Bool {
        let dots: Set<Character> = ["·", "・", "•", "．", "."]
        if left.filter({ !dots.contains($0) }) == right.filter({ !dots.contains($0) }) { return true }
        let leftWords = left.split(separator: " ").sorted(), rightWords = right.split(separator: " ").sorted()
        if leftWords.count > 1, leftWords == rightWords { return true }
        let leftNative = leftWords.filter(isNative), rightNative = rightWords.filter(isNative)
        return !leftNative.isEmpty && leftNative == rightNative
    }

    /// "翻自 …", "翻唱", "(Cover: …)": a cover is never the original recording.
    private static func isCover(_ track: Track) -> Bool {
        LRCLIBClient.normalized(track.title).range(of: #"翻自|翻唱|\bcover\b"#, options: .regularExpression) != nil
    }

    private static func isEdition(_ track: Track) -> Bool {
        LRCLIBClient.hasEditionMarker(LRCLIBClient.normalized(track.title))
            || LRCLIBClient.hasEditionMarker(LRCLIBClient.normalized(track.album))
    }

    private static func isNative(_ word: some StringProtocol) -> Bool {
        word.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: true
            default: false
            }
        }
    }
}
