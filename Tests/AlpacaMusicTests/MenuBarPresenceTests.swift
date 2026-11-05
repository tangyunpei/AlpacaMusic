import AppKit
import Foundation
import Testing
@testable import AlpacaMusic

@Suite @MainActor
struct MenuBarPresenceTests {
    @Test func miniPlayerStyleAndMenuBarItemsHaveDefaults() throws {
        let domain = "AlpacaMenuBarPresenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true)
        defer { model.player.shutdown() }
        #expect(model.miniPlayerStyle == .lyrics)
        #expect(model.showsMenuBarControls)
        #expect(model.showsMenuBarLyrics)
        #expect(model.hasMenuBarPresence)
    }

    @Test func miniPlayerStyleAndMenuBarItemsPersist() throws {
        let domain = "AlpacaMenuBarPresenceTests-\(UUID().uuidString)"
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
        model.miniPlayerStyle = .card
        model.showsMenuBarControls = false
        model.showsMenuBarLyrics = false
        #expect(defaults.string(forKey: "mini-player-style") == "card")
        #expect(defaults.object(forKey: "menu-bar-controls") as? Bool == false)
        #expect(defaults.object(forKey: "menu-bar-lyrics") as? Bool == false)

        let reloaded = AppModel(directory: second, preferences: defaults, ephemeralAccounts: true)
        defer { reloaded.player.shutdown() }
        #expect(reloaded.miniPlayerStyle == .card)
        #expect(!reloaded.showsMenuBarControls)
        #expect(!reloaded.showsMenuBarLyrics)
        reloaded.miniPlayerStyle = .artwork
        reloaded.showsMenuBarControls = true
        reloaded.showsMenuBarLyrics = true
        #expect(defaults.string(forKey: "mini-player-style") == "artwork")
        #expect(defaults.object(forKey: "menu-bar-controls") as? Bool == true)
        #expect(defaults.object(forKey: "menu-bar-lyrics") as? Bool == true)
    }

    @Test func unknownStoredMiniPlayerStyleFallsBackToTheLyricStrip() throws {
        let domain = "AlpacaMenuBarPresenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set("poster", forKey: "mini-player-style")
        let model = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true)
        defer { model.player.shutdown() }
        #expect(model.miniPlayerStyle == .lyrics)
    }

    @Test func menuBarPresenceHoldsWhileAnyMenuBarItemIsShown() throws {
        let domain = "AlpacaMenuBarPresenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true)
        defer { model.player.shutdown() }
        let states: [Bool] = [false, true]
        for showsPlayer in states {
            for showsControls in states {
                for showsLyrics in states {
                    model.showsMenuBarPlayer = showsPlayer
                    model.showsMenuBarControls = showsControls
                    model.showsMenuBarLyrics = showsLyrics
                    let expected: Bool = showsPlayer || showsControls || showsLyrics
                    #expect(model.hasMenuBarPresence == expected)
                }
            }
        }
    }

    @Test func lastWindowCloseQuitsOnlyWithoutAnyMenuBarItem() throws {
        let domain = "AlpacaMenuBarPresenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let application = NSApplication.shared
        let model = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true)
        defer { model.player.shutdown() }
        // The model is set directly, so no status items or panels are created.
        let delegate = AppDelegate()
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(application))
        delegate.model = model
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(application))
        model.showsMenuBarPlayer = false
        model.showsMenuBarControls = false
        #expect(model.showsMenuBarLyrics)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(application))
        model.showsMenuBarLyrics = false
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(application))
    }

    @Test func firstSnapshotLoadsLyricsAndHandsOverTheAudioSource() {
        let expected: [LyricsSyncAction] = [.load, .setAudioSource]
        let playing = LyricsSyncPlan.actions(from: nil, to: snapshot(source: audioSource("first"), position: 30))
        let empty = LyricsSyncPlan.actions(from: nil, to: snapshot(track: nil))
        #expect(playing == expected)
        #expect(empty == expected)
    }

    @Test func trackChangeReloadsLyrics() {
        let expected: [LyricsSyncAction] = [.load]
        let next = LyricsSyncPlan.actions(from: snapshot(track: "first"), to: snapshot(track: "second"))
        let cleared = LyricsSyncPlan.actions(from: snapshot(track: "first"), to: snapshot(track: nil))
        let restored = LyricsSyncPlan.actions(from: snapshot(track: nil), to: snapshot(track: "first"))
        #expect(next == expected)
        #expect(cleared == expected)
        #expect(restored == expected)
    }

    @Test func audioSourceChangeHandsOverTheNewSource() {
        let first = audioSource("first")
        let second = audioSource("second")
        let expected: [LyricsSyncAction] = [.setAudioSource]
        let ready = LyricsSyncPlan.actions(from: snapshot(), to: snapshot(source: first))
        let replaced = LyricsSyncPlan.actions(from: snapshot(source: first), to: snapshot(source: second))
        let detached = LyricsSyncPlan.actions(from: snapshot(source: second), to: snapshot())
        #expect(ready == expected)
        #expect(replaced == expected)
        #expect(detached == expected)
    }

    @Test func positionChangeAloneUpdatesAlignmentWithoutASeek() {
        let expected: [LyricsSyncAction] = [.updatePosition(didSeek: false)]
        let ticked = LyricsSyncPlan.actions(from: snapshot(position: 10), to: snapshot(position: 10.1))
        let recovered = LyricsSyncPlan.actions(from: snapshot(position: .nan), to: snapshot(position: 3))
        #expect(ticked == expected)
        #expect(recovered == expected)
    }

    @Test func seekRevisionChangeReportsExactlyOneSeek() {
        let expected: [LyricsSyncAction] = [.updatePosition(didSeek: true)]
        let samePosition = LyricsSyncPlan.actions(from: snapshot(position: 42, revision: 3), to: snapshot(position: 42, revision: 4))
        let movedPosition = LyricsSyncPlan.actions(from: snapshot(position: 42, revision: 3), to: snapshot(position: 95, revision: 4))
        let wrapped = LyricsSyncPlan.actions(from: snapshot(revision: UInt64.max), to: snapshot(revision: 0))
        #expect(samePosition == expected)
        #expect(movedPosition == expected)
        #expect(wrapped == expected)
    }

    @Test func combinedChangesLoadBeforeHandingOverTheSource() {
        let source = audioSource("second")
        let expected: [LyricsSyncAction] = [.load, .setAudioSource]
        let switched = LyricsSyncPlan.actions(from: snapshot(track: "first"), to: snapshot(track: "second", source: source))
        #expect(switched == expected)
        let everything: [LyricsSyncAction] = [.load, .setAudioSource, .updatePosition(didSeek: true)]
        let old = snapshot(track: "first", position: 80, revision: 1)
        let new = snapshot(track: "second", source: source, position: 0, revision: 2)
        let all = LyricsSyncPlan.actions(from: old, to: new)
        #expect(all == everything)
    }

    @Test func unchangedSnapshotsDoNothing() {
        let state = snapshot(source: audioSource("first"), position: 12.5, revision: 7)
        let unchanged = LyricsSyncPlan.actions(from: state, to: state)
        let stillUnknown = LyricsSyncPlan.actions(from: snapshot(position: .nan), to: snapshot(position: .nan))
        #expect(unchanged.isEmpty)
        #expect(stillUnknown.isEmpty)
    }

    private func audioSource(_ name: String) -> LyricAudioSource {
        LyricAudioSource(session: UUID(), trackKey: name, url: URL(fileURLWithPath: "/tmp/alpaca-lyrics-sync-\(name).m4a"))
    }

    private func snapshot(track: String? = "first", source: LyricAudioSource? = nil,
                          position: Double = 0, revision: UInt64 = 0) -> LyricsSyncSnapshot {
        LyricsSyncSnapshot(trackKey: track, audioSource: source, position: position, seekRevision: revision)
    }
}
