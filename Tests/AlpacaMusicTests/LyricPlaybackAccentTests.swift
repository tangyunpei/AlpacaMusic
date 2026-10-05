import Foundation
import Testing
@testable import AlpacaMusic

@Test @MainActor func playbackAccentWaitsForTheSuppliedWordAndRemovesSizeEmphasisAfterward() throws {
    let words = [LyricWord(id: 0, text: "In ", start: 0, end: 0.6),
                 LyricWord(id: 1, text: "the ", start: 0.6, end: 1.2),
                 LyricWord(id: 2, text: "quiet ", start: 2, end: 4.4),
                 LyricWord(id: 3, text: "room", start: 5, end: 7)]
    let line = LyricLine(id: 0, text: words.map(\.text).joined(), start: 0, end: 8, words: words)
    let viewport = CGSize(width: 1000, height: 600)
    let before = LyricTypography.layout(line: line, index: 0, in: viewport, position: 1.9, reduceMotion: false)
    #expect(before.allSatisfy { $0.accent == nil && $0.scale == 1 })
    let hit = LyricTypography.layout(line: line, index: 0, in: viewport, position: 2.06, reduceMotion: false)
    let quiet = try #require(hit.first { $0.text == "quiet " })
    #expect((quiet.accent?.intensity ?? 0) > 0.3)
    #expect(quiet.scale > 1.02)
    #expect(hit.first { $0.text == "room" }?.accent == nil)
    let after = LyricTypography.layout(line: line, index: 0, in: viewport, position: 7.8, reduceMotion: false)
    #expect(after.allSatisfy { $0.accent == nil && $0.scale == 1 })
    for sample in [before, hit, after] {
        #expect(sample.map(\.text) == words.map(\.text))
        #expect(sample.map(\.timedStart) == words.map { Optional($0.start) })
        #expect(sample.map(\.timedEnd) == words.map(\.end))
    }
}

@Test @MainActor func estimatedAccentPlacementSurvivesViewportChangesAndSeeks() {
    for text in ["把夜色留在每一扇窗前，等待下一次相逢", "In the quiet room we leave a little light beside the window"] {
        let line = LyricLine(id: 0, text: text, start: 10, end: 18)
        var wideEvents: [Int: Double] = [:], narrowEvents: [Int: Double] = [:]
        for tick in 0..<192 {
            let time = 10 + Double(tick) / 24
            let wide = LyricTypography.layout(line: line, index: 0, in: CGSize(width: 1000, height: 600), position: time, reduceMotion: false)
            let narrow = LyricTypography.layout(line: line, index: 0, in: CGSize(width: 300, height: 240), position: time, reduceMotion: false)
            #expect(wide.map(\.text) == narrow.map(\.text))
            #expect(wide.map(\.text).joined() == text)
            #expect(wide.map(\.accent) == narrow.map(\.accent))
            #expect(wide.allSatisfy { $0.timedStart == nil && $0.timedEnd == nil })
            for piece in wide where piece.accent != nil && wideEvents[piece.id] == nil { wideEvents[piece.id] = time }
            for piece in narrow where piece.accent != nil && narrowEvents[piece.id] == nil { narrowEvents[piece.id] = time }
        }
        #expect(wideEvents == narrowEvents)
        #expect(!wideEvents.isEmpty)
        #expect(wideEvents.count <= 2)
        #expect(wideEvents.values.contains { $0 > 12 })
        let early = LyricTypography.layout(line: line, index: 0, in: CGSize(width: 1000, height: 600), position: 10, reduceMotion: false)
        #expect(early.allSatisfy { $0.accent == nil && $0.scale == 1 })
        let sample = LyricTypography.layout(line: line, index: 0, in: CGSize(width: 1000, height: 600), position: 14.3, reduceMotion: false)
        _ = LyricTypography.layout(line: line, index: 0, in: CGSize(width: 1000, height: 600), position: 17.8, reduceMotion: false)
        let revisited = LyricTypography.layout(line: line, index: 0, in: CGSize(width: 1000, height: 600), position: 14.3, reduceMotion: false)
        #expect(sample.map(\.accent) == revisited.map(\.accent))
        #expect(sample.map(\.center) == revisited.map(\.center))
        #expect(sample.map(\.scale) == revisited.map(\.scale))
    }
}


@Test @MainActor func shortSuppliedWordsKeepTheirGestureAfterTheNextWordStarts() throws {
    let words = [LyricWord(id: 0, text: "Light ", start: 1, end: 1.12),
                 LyricWord(id: 1, text: "returns ", start: 1.12, end: 1.24),
                 LyricWord(id: 2, text: "quiet ", start: 1.24, end: 1.36),
                 LyricWord(id: 3, text: "room", start: 1.36, end: 1.48)]
    let line = LyricLine(id: 42, text: words.map(\.text).joined(), start: 0, end: 4, words: words)
    let size = CGSize(width: 1000, height: 600)
    let frame = { (time: Double) in LyricTypography.layout(line: line, index: 0, in: size, position: time, reduceMotion: false) }
    var found = 0
    for index in words.indices {
        let word = words[index]
        guard frame(word.start + 0.06)[index].accent != nil else { continue }
        found += 1
        let crossing = try #require(frame(word.end! + 0.10)[index].accent)
        #expect(crossing.progress > 0)
        if crossing.kind == .ring || crossing.kind == .box { #expect(crossing.intensity > 0.1) }
        let complete = try #require(frame(word.start + 0.40)[index].accent)
        #expect(complete.progress > 0.98)
        #expect(frame(word.start - 0.001)[index].accent == nil)
        _ = frame(3.8)
        #expect(frame(word.end! + 0.10)[index].accent == crossing)
    }
    #expect(found > 0 && found <= 2)
    #expect(frame(3.8).allSatisfy { $0.accent == nil && $0.scale == 1 })
    for time in [1.06, 1.38, 1.70, 2.25] {
        let sample = frame(time)
        #expect(sample.map(\.text) == words.map(\.text))
        #expect(sample.map(\.timedStart) == words.map { Optional($0.start) })
        #expect(sample.map(\.timedEnd) == words.map(\.end))
        let reduced = LyricTypography.layout(line: line, index: 0, in: size, position: time, reduceMotion: true)
        #expect(reduced.allSatisfy { $0.accent == nil })
    }
}

@Test @MainActor func completeAccentSurvivesMultipleRapidCueChangesOnItsOriginalWord() throws {
    let first = LyricLine(id: 101, text: "light", start: 1, end: 1.10,
                          words: [.init(id: 0, text: "light", start: 1.06, end: 1.10)])
    let following = [LyricLine(id: 102, text: "we", start: 1.10, end: 1.20),
                     LyricLine(id: 103, text: "are", start: 1.20, end: 1.30),
                     LyricLine(id: 104, text: "together", start: 1.30, end: 4)]
    let document = LyricDocument(lines: [first] + following, timing: .word, sourceDescription: "Original artificial fixture")
    let original = document
    let size = CGSize(width: 1000, height: 600)
    let frame = { (position: Double) in LyricTypography.frame(document: document, position: position, in: size, reduceMotion: false) }
    let started = try #require(frame(1.08).fragments.first { $0.role == .primary && $0.lineID == first.id })
    let initialState = try #require(started.accent)
    let choice = LyricAccentChoice(kind: initialState.kind, reason: .wordOnset,
                                  direction: initialState.rotation < 0 ? -1 : 1)
    let event = try #require(LyricEmphasis.eventInterval(choice: choice, line: first, unitIndex: 0))
    #expect(event.end > 1.90)
    #expect(frame(1.059).fragments.allSatisfy { $0.accent == nil })
    for tick in 0..<Int((event.end - 1.10) * 60) {
        let position = 1.10 + Double(tick) / 60
        let result = frame(position)
        let owner = try #require(result.fragments.first { $0.role == .completingAccent && $0.lineID == first.id })
        #expect(owner.text == first.text)
        #expect(owner.accent == LyricEmphasis.state(choice: choice, line: first, unitIndex: 0, position: position))
        #expect(owner.opacity == 1)
        #expect(owner.glyphOpacity > 0 && owner.glyphOpacity <= 1)
        #expect(owner.timedStart == nil && owner.timedEnd == nil)
        #expect(result.activeLineID == document.lines[document.activeIndex(at: position)!].id)
        #expect(result.fragments.filter { $0.role == .primary }.map(\.text).joined() == document.lines[document.activeIndex(at: position)!].text)
        #expect(result.fragments.filter { $0.lineID == first.id && $0.role != .echo }.count == 1)
        #expect(Set(result.fragments.map(\.id)).count == result.fragments.count)
        let bounds = LyricAccentRenderer.maximumWorldBounds(for: owner)
        if position >= 1.30 {
            #expect(result.fragments.filter { $0.role == .primary }.allSatisfy { !bounds.intersects($0.bounds) })
        }
        #expect(bounds.minX >= -1 && bounds.minY >= -1 && bounds.maxX <= size.width + 1 && bounds.maxY <= size.height + 1)
    }
    let complete = try #require(frame(event.start + 0.40).fragments.first { $0.role == .completingAccent && $0.lineID == first.id }?.accent)
    #expect(complete.progress == 1 && complete.trail == 0)
    #expect(frame(event.end + 0.001).fragments.allSatisfy { $0.lineID != first.id })
    let sampled = frame(1.50)
    _ = frame(3.90)
    let replay = frame(1.50)
    #expect(sampled.fragments.map(\.center) == replay.fragments.map(\.center))
    #expect(sampled.fragments.map(\.accent) == replay.fragments.map(\.accent))
    #expect(sampled.fragments.map(\.glyphOpacity) == replay.fragments.map(\.glyphOpacity))
    let reduced = LyricTypography.frame(document: document, position: 1.50, in: size, reduceMotion: true)
    #expect(reduced.fragments.allSatisfy { $0.role == .primary && $0.accent == nil })
    #expect(document == original)
}

@Test @MainActor func estimatedFinalWordCompletesInAnExplicitGapAndDoesNotReplayLater() throws {
    let line = LyricLine(id: 7, text: "light", start: 0, end: 0.10)
    let document = LyricDocument(lines: [line, .init(id: 8, text: "we", start: 2, end: 3)],
                                 timing: .line, sourceDescription: "Original artificial fixture")
    let size = CGSize(width: 430, height: 360)
    let frame = { (position: Double) in LyricTypography.frame(document: document, position: position, in: size, reduceMotion: false) }
    let before = frame(0.06)
    let accent = try #require(before.fragments.first { $0.role == .primary }?.accent)
    let owner = try #require(frame(0.50).fragments.first { $0.role == .completingAccent })
    #expect(owner.lineID == line.id && owner.accent?.kind == accent.kind)
    #expect(owner.accent?.progress == 1 && owner.accent?.trail == 0)
    #expect(frame(0.50).activeLineID == nil)
    #expect(frame(1.50).fragments.isEmpty)
    #expect(frame(2.01).fragments.allSatisfy { $0.lineID != line.id })
    #expect(frame(0.50).fragments.first { $0.role == .completingAccent }?.accent == owner.accent)
}


@Test @MainActor func twoCompletingWordsUseSeparateMarginSlotsWithoutDuplicatingTheSentence() throws {
    let line = LyricLine(id: 1, text: "we carry light", start: 0, end: 2, words: [
        .init(id: 0, text: "we ", start: 0, end: 1.9),
        .init(id: 1, text: "carry ", start: 1.9, end: 1.94),
        .init(id: 2, text: "light", start: 1.94, end: 2)
    ])
    let document = LyricDocument(lines: [line, .init(id: 2, text: "we", start: 2, end: 5)],
                                 timing: .word, sourceDescription: "Original artificial fixture")
    let size = CGSize(width: 960, height: 540)
    let result = LyricTypography.frame(document: document, position: 2.40, in: size, reduceMotion: false)
    let owners = result.fragments.filter { $0.role == .completingAccent }
    #expect(owners.count == 2)
    #expect(owners.map(\.text) == ["carry ", "light"])
    #expect(owners.allSatisfy { $0.accent?.progress == 1 && $0.accent?.trail == 0 })
    let left = try #require(owners.first)
    let right = try #require(owners.last)
    #expect(left.center.x < size.width / 2 && right.center.x > size.width / 2)
    let leftBounds = LyricAccentRenderer.maximumWorldBounds(for: left)
    let rightBounds = LyricAccentRenderer.maximumWorldBounds(for: right)
    #expect(!leftBounds.intersects(rightBounds))
    #expect(result.fragments.filter { $0.role == .primary }.allSatisfy { !leftBounds.intersects($0.bounds) && !rightBounds.intersects($0.bounds) })
    #expect(result.fragments.filter { $0.lineID == line.id && $0.role == .outgoing }.allSatisfy { $0.text == "we " })
}
