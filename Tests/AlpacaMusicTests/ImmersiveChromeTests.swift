import Foundation
import Testing
@testable import AlpacaMusic

@MainActor private final class MenuFlag { var open = true }

@Suite(.serialized) @MainActor struct ImmersiveChromeTests {
    private func controller(voiceOver: Bool = false, menuOpen: @escaping @MainActor () -> Bool = { false },
                            hides: @escaping @MainActor () -> Void = {}) -> ImmersiveChromeController {
        ImmersiveChromeController(delay: .milliseconds(80), assistiveTechnology: { voiceOver }, menuOpen: menuOpen, onHide: hides)
    }
    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test func controlsFadeAfterTheListenerIsIdle() async throws {
        var hidden = 0
        let chrome = controller(hides: { hidden += 1 })
        #expect(chrome.isVisible)
        chrome.activate(watchingSystem: false)
        try await settle { !chrome.isVisible }
        #expect(hidden == 1) // The pointer hides with the controls.
    }

    @Test func activityBringsThemBackAndRestartsTheCountdown() async throws {
        let chrome = controller()
        chrome.activate(watchingSystem: false)
        try await settle { !chrome.isVisible }
        chrome.poke()
        #expect(chrome.isVisible)
        // Keep moving: the controls stay as long as activity continues.
        for _ in 0..<6 { try await Task.sleep(for: .milliseconds(30)); chrome.poke(); #expect(chrome.isVisible) }
        try await settle { !chrome.isVisible }
    }

    @Test func controlsInUseStayUntilReleased() async throws {
        let chrome = controller()
        chrome.activate(watchingSystem: false)
        chrome.hold(.pointerOnPlayerBar, true)
        chrome.hold(.queue, true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(chrome.isVisible)
        chrome.hold(.pointerOnPlayerBar, false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(chrome.isVisible) // The queue still holds them.
        chrome.hold(.queue, false)
        try await settle { !chrome.isVisible }
    }

    @Test func voiceOverKeepsTheControlsOnScreen() async throws {
        let chrome = controller(voiceOver: true)
        chrome.activate(watchingSystem: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(chrome.isVisible)
    }

    @Test func leavingTheRoomShowsTheControlsForGood() async throws {
        let chrome = controller()
        chrome.activate(watchingSystem: false)
        try await settle { !chrome.isVisible }
        chrome.deactivate()
        #expect(chrome.isVisible && !chrome.isActive)
        chrome.poke() // Activity outside the room arms nothing.
        try await Task.sleep(for: .milliseconds(200))
        #expect(chrome.isVisible)
    }

    @Test func aPointerAlreadyOnTheBarKeepsItWhenTheRoomOpens() async throws {
        let chrome = controller()
        chrome.hold(.pointerOnPlayerBar, true) // Recorded before the room opens.
        chrome.activate(watchingSystem: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(chrome.isVisible)
        // Leaving and reopening the room keeps what the pointer is doing.
        chrome.deactivate(); chrome.activate(watchingSystem: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(chrome.isVisible)
        chrome.hold(.pointerOnPlayerBar, false)
        try await settle { !chrome.isVisible }
    }

    @Test func aClosedWindowForgetsThePointer() async throws {
        let chrome = controller()
        chrome.hold(.pointerOnTopControls, true)
        chrome.forgetPointerHolds()
        #expect(!chrome.isHolding(.pointerOnTopControls))
        chrome.activate(watchingSystem: false)
        try await settle { !chrome.isVisible }
    }

    @Test func anOpenSheetOrMenuKeepsTheControls() async throws {
        let menu = MenuFlag()
        let chrome = controller(menuOpen: { menu.open })
        chrome.activate(watchingSystem: false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(chrome.isVisible) // Reading a menu counts as activity.
        menu.open = false
        try await settle { !chrome.isVisible }
        chrome.hold(.sheet, true)
        #expect(chrome.isVisible)
        try await Task.sleep(for: .milliseconds(200))
        #expect(chrome.isVisible)
        chrome.hold(.sheet, false)
        try await settle { !chrome.isVisible }
    }

    @Test func holdsOutsideTheRoomStartNothing() async throws {
        var hidden = 0
        let chrome = controller(hides: { hidden += 1 })
        chrome.hold(.queue, true); chrome.hold(.queue, false); chrome.poke()
        try await Task.sleep(for: .milliseconds(200))
        #expect(chrome.isVisible && hidden == 0 && !chrome.isActive)
    }

    @Test func leavingTheRoomStopsTheController() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("immersive-\(UUID().uuidString)")
        let suite = "AlpacaImmersive.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, preferences: UserDefaults(suiteName: suite)!, ephemeralAccounts: true)
        defer { model.player.shutdown(); model.immersiveChrome.deactivate() }
        model.immersive = true
        #expect(!model.immersiveChrome.isActive) // The room's view starts it when it appears.
        model.immersiveChrome.activate(watchingSystem: false)
        model.immersive = false
        #expect(!model.immersiveChrome.isActive && model.immersiveChrome.isVisible)
    }
}
