import AppKit
import Foundation
import Testing
@testable import AlpacaMusic

@Suite @MainActor
struct MiniPlayerTests {
    @Test func progressFractionIsClampedAndSafeForUnusableDurations() {
        #expect(MiniPlayerTiming.fraction(position: 30, duration: 120) == 0.25)
        #expect(MiniPlayerTiming.fraction(position: -5, duration: 120) == 0)
        #expect(MiniPlayerTiming.fraction(position: 500, duration: 120) == 1)
        #expect(MiniPlayerTiming.fraction(position: .nan, duration: 120) == 0)
        #expect(MiniPlayerTiming.fraction(position: 30, duration: 0) == 0)
        #expect(MiniPlayerTiming.fraction(position: 30, duration: -1) == 0)
        #expect(MiniPlayerTiming.fraction(position: 30, duration: .nan) == 0)
        #expect(MiniPlayerTiming.fraction(position: 30, duration: .infinity) == 0)
    }

    @Test func seekingRequiresAKnownDurationAndClampsTheTarget() {
        #expect(MiniPlayerTiming.seekTarget(fraction: 0.5, duration: 200) == 100)
        #expect(MiniPlayerTiming.seekTarget(fraction: 1.4, duration: 200) == 200)
        #expect(MiniPlayerTiming.seekTarget(fraction: -0.2, duration: 200) == 0)
        #expect(MiniPlayerTiming.seekTarget(fraction: .nan, duration: 200) == nil)
        #expect(MiniPlayerTiming.seekTarget(fraction: 0.5, duration: 0) == nil)
        #expect(MiniPlayerTiming.seekTarget(fraction: 0.5, duration: .infinity) == nil)
        #expect(MiniPlayerTiming.validDuration(.nan) == nil)
        #expect(MiniPlayerTiming.validDuration(42) == 42)
    }

    @Test func timeLabelsShowElapsedAndRemaining() {
        #expect(MiniPlayerTiming.remaining(position: 30, duration: 90) == 60)
        #expect(MiniPlayerTiming.remaining(position: 120, duration: 90) == 0)
        #expect(MiniPlayerTiming.remaining(position: .nan, duration: 90) == 90)
        #expect(MiniPlayerTiming.remaining(position: 30, duration: 0) == nil)
        #expect(MiniPlayerTiming.elapsedText(position: 65, duration: 200) == "1:05")
        #expect(MiniPlayerTiming.elapsedText(position: 500, duration: 200) == "3:20")
        #expect(MiniPlayerTiming.elapsedText(position: -3, duration: 200) == "0:00")
        #expect(MiniPlayerTiming.elapsedText(position: .infinity, duration: 0) == "0:00")
        #expect(MiniPlayerTiming.remainingText(position: 30, duration: 90) == "-1:00")
        #expect(MiniPlayerTiming.remainingText(position: 30, duration: 0) == "—")
        #expect(MiniPlayerTiming.remainingText(position: 30, duration: .nan) == "—")
        #expect(MiniPlayerTiming.remainingText(position: 30, duration: .infinity) == formattedTime(.infinity))
    }

    @Test func statusItemSymbolFollowsPlaybackOnly() {
        #expect(MenuBarPlayerIcon.symbol(for: .playing) == "waveform")
        #expect(MenuBarPlayerIcon.symbol(for: .paused) == "music.note")
        #expect(MenuBarPlayerIcon.symbol(for: .idle) == "music.note")
        #expect(MenuBarPlayerIcon.symbol(for: .loading) == "music.note")
        #expect(MenuBarPlayerIcon.symbol(for: .failed) == "music.note")
    }

    @Test func windowIdentifiersAreStable() {
        #expect(PlayerWindowID.main == "main")
        #expect(PlayerWindowID.miniPlayer == "mini-player")
    }

    @Test func menuBarPlayerDefaultsOnAndPersists() throws {
        let domain = "AlpacaMiniPlayerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let first = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let second = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let model = AppModel(directory: first, preferences: defaults, ephemeralAccounts: true)
        defer { model.player.shutdown() }
        #expect(model.showsMenuBarPlayer)
        model.showsMenuBarPlayer = false
        #expect(defaults.object(forKey: "menu-bar-player") as? Bool == false)

        let reloaded = AppModel(directory: second, preferences: defaults, ephemeralAccounts: true)
        defer { reloaded.player.shutdown() }
        #expect(!reloaded.showsMenuBarPlayer)
        reloaded.showsMenuBarPlayer = true
        #expect(defaults.object(forKey: "menu-bar-player") as? Bool == true)
    }

    @Test func lastWindowClosePolicyFollowsMenuBarPresence() throws {
        let domain = "AlpacaMiniPlayerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let application = NSApplication.shared
        let model = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true)
        defer { model.player.shutdown() }
        // The model is set directly rather than attached, so no status items
        // or panels are created.
        let delegate = AppDelegate()
        // Before a model is connected, closing the last window quits as before.
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(application))
        delegate.model = model
        #expect(model.showsMenuBarPlayer)
        #expect(model.showsMenuBarControls)
        #expect(model.showsMenuBarLyrics)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(application))
        model.showsMenuBarPlayer = false
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(application))
        model.showsMenuBarControls = false
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(application))
        model.showsMenuBarLyrics = false
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(application))
    }

    @Test func miniPlayerStylesRunFromTheCoverToTheCard() {
        let expected: [MiniPlayerStyle] = [.artwork, .lyrics, .card]
        #expect(MiniPlayerStyle.allCases == expected)
    }

    @Test func nextStyleCyclesThroughEveryStyle() {
        #expect(MiniPlayerStyle.artwork.next == .lyrics)
        #expect(MiniPlayerStyle.lyrics.next == .card)
        #expect(MiniPlayerStyle.card.next == .artwork)
        for style in MiniPlayerStyle.allCases {
            let third: MiniPlayerStyle = style.next.next.next
            #expect(style.next != style)
            #expect(third == style)
        }
    }

    @Test func styleSizesGrowFromASquareCoverToTheCard() {
        let artwork: CGSize = MiniPlayerStyle.artwork.size
        let lyrics: CGSize = MiniPlayerStyle.lyrics.size
        let card: CGSize = MiniPlayerStyle.card.size
        let expectedArtwork = CGSize(width: 156, height: 156)
        let expectedLyrics = CGSize(width: 480, height: 84)
        let expectedCard = CGSize(width: 400, height: 236)
        #expect(artwork == expectedArtwork)
        #expect(lyrics == expectedLyrics)
        #expect(card == expectedCard)

        let artworkArea: CGFloat = artwork.width * artwork.height
        let lyricsArea: CGFloat = lyrics.width * lyrics.height
        let cardArea: CGFloat = card.width * card.height
        // The cover is a square and the smallest window.
        #expect(artwork.width == artwork.height)
        #expect(artworkArea < lyricsArea)
        #expect(artworkArea < cardArea)
        // The lyric strip is the widest and shorter than the card.
        #expect(lyrics.width > card.width)
        #expect(lyrics.width > artwork.width)
        #expect(lyrics.height < card.height)
        // The card is the largest.
        #expect(cardArea > lyricsArea)
    }

    @Test func styleTitlesAndSymbolsAreDistinct() {
        let titles: [String] = MiniPlayerStyle.allCases.map { (style: MiniPlayerStyle) -> String in style.title }
        let symbols: [String] = MiniPlayerStyle.allCases.map { (style: MiniPlayerStyle) -> String in style.symbol }
        let titlesFilled: Bool = titles.allSatisfy { (title: String) -> Bool in !title.isEmpty }
        let expectedSymbols: [String] = ["photo", "quote.bubble", "rectangle"]
        #expect(titlesFilled)
        #expect(Set(titles).count == titles.count)
        #expect(Set(symbols).count == symbols.count)
        #expect(symbols == expectedSymbols)
    }

    @Test func styleRawValuesAreStable() {
        let rawValues: [String] = MiniPlayerStyle.allCases.map { (style: MiniPlayerStyle) -> String in style.rawValue }
        let identifiers: [String] = MiniPlayerStyle.allCases.map { (style: MiniPlayerStyle) -> String in style.id }
        let expected: [String] = ["artwork", "lyrics", "card"]
        #expect(rawValues == expected)
        #expect(identifiers == expected)
        let parsed: [MiniPlayerStyle?] = expected.map { (raw: String) -> MiniPlayerStyle? in MiniPlayerStyle(rawValue: raw) }
        let styles: [MiniPlayerStyle?] = [MiniPlayerStyle.artwork, MiniPlayerStyle.lyrics, MiniPlayerStyle.card]
        let unknown: MiniPlayerStyle? = MiniPlayerStyle(rawValue: "poster")
        #expect(parsed == styles)
        #expect(unknown == nil)
    }
}
