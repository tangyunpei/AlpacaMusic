import Foundation
import Testing
@testable import AlpacaMusic

private func song(_ id: String, unavailable: Bool = false) -> Track {
    Track(id: id, title: id, artist: "Artist", album: "", duration: 100, source: .local, unavailable: unavailable)
}

/// A small deterministic generator, so a failing case can be replayed.
private struct Sequence {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
    mutating func unit() -> Double { Double(next() % 10_000) / 10_000 }
}

/// The Next strip shows what `upcoming` says; it must say what `next` does.
@Suite struct PlaybackUpcomingTests {
    @Test func inOrderItListsTheSongsAfterTheCurrentOne() {
        var queue = PlaybackQueue(); queue.select(song("b"), context: [song("a"), song("b"), song("c"), song("d"), song("e")])
        #expect(queue.upcoming(shuffle: false, repeatMode: .off, limit: 8).tracks.map(\.id) == ["c", "d", "e"])
        #expect(queue.upcoming(shuffle: false, repeatMode: .off, limit: 2).tracks.map(\.id) == ["c", "d"])
        #expect(queue.upcoming(shuffle: false, repeatMode: .off, limit: 0) == PlaybackUpcoming())
        #expect(queue.upcoming(shuffle: false, repeatMode: .off, limit: 8).shuffled == 0)
    }

    @Test func itSkipsSongsThatCannotPlayAndEndsWithTheQueue() {
        var queue = PlaybackQueue(); queue.select(song("a"), context: [song("a"), song("gone", unavailable: true), song("b")])
        #expect(queue.upcoming(shuffle: false, repeatMode: .off, limit: 8).tracks.map(\.id) == ["b"])
        _ = queue.next(shuffle: false, repeatMode: .off)
        #expect(queue.upcoming(shuffle: false, repeatMode: .off, limit: 8).tracks.isEmpty)
    }

    @Test func repeatAllWrapsOnceAndNeverListsASongTwice() {
        var queue = PlaybackQueue(); queue.select(song("c"), context: [song("a"), song("b"), song("c"), song("d")])
        #expect(queue.upcoming(shuffle: false, repeatMode: .all, limit: 8).tracks.map(\.id) == ["d", "a", "b"])
        var single = PlaybackQueue(); single.select(song("a"))
        #expect(single.upcoming(shuffle: false, repeatMode: .all, limit: 8).tracks.isEmpty)
    }

    @Test func aSongQueuedToPlayNextComesFirstInOrder() {
        var queue = PlaybackQueue(); queue.select(song("a"), context: [song("a"), song("b"), song("c"), song("d")])
        queue.playNext(song("d"))
        #expect(queue.upcoming(shuffle: false, repeatMode: .off, limit: 8).tracks.map(\.id) == ["d", "b", "c"])
    }

    @Test func underShuffleOnlyTheSongQueuedNextIsKnown() {
        var queue = PlaybackQueue(); queue.select(song("a"), context: ["a", "b", "c", "d", "e"].map { song($0) })
        let open = queue.upcoming(shuffle: true, repeatMode: .off, limit: 8)
        #expect(open.tracks.isEmpty)
        #expect(open.shuffled == 4)
        queue.playNext(song("c"))
        let queued = queue.upcoming(shuffle: true, repeatMode: .off, limit: 8)
        #expect(queued.tracks.map(\.id) == ["c"])
        // The four others are still to come: three after the queued song.
        #expect(queued.shuffled == 3)
    }

    @Test func theShuffleCountFallsAsSongsPlayAndStartsOverWithRepeatAll() {
        var queue = PlaybackQueue(); queue.select(song("a"), context: ["a", "b", "c"].map { song($0) })
        #expect(queue.upcoming(shuffle: true, repeatMode: .off, limit: 8).shuffled == 2)
        _ = queue.next(shuffle: true, repeatMode: .off, randomUnit: 0)
        #expect(queue.upcoming(shuffle: true, repeatMode: .off, limit: 8).shuffled == 1)
        _ = queue.next(shuffle: true, repeatMode: .off, randomUnit: 0)
        #expect(queue.upcoming(shuffle: true, repeatMode: .off, limit: 8).shuffled == 0)
        // Every song has played: repeat all draws from the other two again.
        #expect(queue.upcoming(shuffle: true, repeatMode: .all, limit: 8).shuffled == 2)
    }

    @Test func peekingChangesNothing() {
        var queue = PlaybackQueue(); queue.select(song("a"), context: ["a", "b", "c", "d"].map { song($0) })
        queue.playNext(song("c"))
        var untouched = queue
        _ = queue.upcoming(shuffle: true, repeatMode: .all, limit: 8)
        _ = queue.upcoming(shuffle: false, repeatMode: .all, limit: 8)
        #expect(queue.tracks == untouched.tracks && queue.currentID == untouched.currentID && queue.history == untouched.history)
        // The queued song is still taken first, in both copies.
        #expect(queue.next(shuffle: true, repeatMode: .off)?.id == "c")
        #expect(untouched.next(shuffle: true, repeatMode: .off)?.id == "c")
    }

    /// Random queues and listener actions: the first listed song is always
    /// the one `next` returns, and under shuffle `next` draws from as many
    /// songs as were counted.
    @Test func itAgreesWithNextOverRandomSessions() {
        for seed in UInt64(1)...60 {
            var random = Sequence(state: seed)
            let count = 1 + Int(random.next() % 7)
            let tracks = (0..<count).map { song("s\($0)", unavailable: random.next() % 6 == 0) }
            guard let start = tracks.first(where: { !$0.unavailable }) else { continue }
            var queue = PlaybackQueue(); queue.select(start, context: tracks)
            for _ in 0..<40 {
                let shuffle = random.next() % 2 == 0
                let repeatMode: RepeatMode = random.next() % 3 == 0 ? .all : .off
                switch random.next() % 6 {
                case 0: queue.playNext(tracks[Int(random.next() % UInt64(count))])
                case 1: queue.move(tracks[Int(random.next() % UInt64(count))].id, direction: random.next() % 2 == 0 ? 1 : -1)
                case 2: _ = queue.previous(repeatMode: repeatMode)
                default: break
                }
                let listed = queue.upcoming(shuffle: shuffle, repeatMode: repeatMode, limit: 8)
                #expect(Set(listed.tracks.map(\.id)).count == listed.tracks.count)
                #expect(!listed.tracks.contains { $0.id == queue.currentID || $0.unavailable })
                var probe = queue
                let taken = probe.next(shuffle: shuffle, repeatMode: repeatMode, randomUnit: random.unit())
                if let first = listed.tracks.first {
                    #expect(taken?.id == first.id, "seed \(seed)")
                } else if shuffle {
                    let playable = tracks.filter { !$0.unavailable }
                    // Alone in the queue with repeat all, the same song plays again.
                    if playable.count == 1, repeatMode == .all { #expect(listed.shuffled == 0) }
                    else { #expect((taken == nil) == (listed.shuffled == 0), "seed \(seed)") }
                } else {
                    // In order, an empty list means the queue ends here or wraps onto the current song.
                    #expect(taken == nil || taken?.id == queue.currentID, "seed \(seed)")
                }
                if let taken { queue = probe; _ = taken }
            }
        }
    }
}
