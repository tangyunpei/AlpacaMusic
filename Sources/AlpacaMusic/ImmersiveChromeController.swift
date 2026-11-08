import AppKit
import Observation

/// Shows the immersive room's controls (the player bar and the top switches)
/// while the listener is active, and fades them after a few idle seconds.
/// Pointer movement, clicks, scrolling and keys bring them back. They stay
/// while the pointer rests on them, while the queue or a sheet is open, while
/// a menu is open, and whenever VoiceOver or Switch Control is running, so
/// nothing a listener is using disappears.
///
/// The room's view activates it when it appears and deactivates it when it
/// goes away, so nothing runs while only the mini player or another window
/// is showing.
@MainActor @Observable final class ImmersiveChromeController {
    static let idleDelay: Duration = .seconds(3)

    /// Something that keeps the controls on screen while it lasts.
    enum Hold: Hashable {
        case pointerOnPlayerBar
        case pointerOnTopControls
        case queue
        case sheet
    }

    private(set) var isVisible = true

    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private let assistiveTechnology: @MainActor () -> Bool
    @ObservationIgnored private let menuOpen: @MainActor () -> Bool
    @ObservationIgnored private let onHide: @MainActor () -> Void
    @ObservationIgnored private(set) var isActive = false
    @ObservationIgnored private var lastActivity: ContinuousClock.Instant
    @ObservationIgnored private var holds: Set<Hold> = []
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var timerID: UUID?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var accessibilityObservers: [NSKeyValueObservation] = []

    init(delay: Duration = idleDelay,
         assistiveTechnology: @escaping @MainActor () -> Bool = ImmersiveChromeController.assistiveTechnologyRunning,
         menuOpen: @escaping @MainActor () -> Bool = { RunLoop.main.currentMode == .eventTracking },
         onHide: @escaping @MainActor () -> Void = ImmersiveChromeController.hidePointer) {
        self.delay = delay
        self.assistiveTechnology = assistiveTechnology
        self.menuOpen = menuOpen
        self.onHide = onHide
        lastActivity = clock.now
    }

    /// The room appeared: controls show, and the idle countdown starts.
    func activate(watchingSystem: Bool = true) {
        guard !isActive else { return }
        isActive = true
        if watchingSystem { startWatching() }
        poke()
    }
    /// The room went away: controls show again and nothing runs. Holds stay:
    /// they mirror real state, such as the pointer resting on the player bar.
    func deactivate() {
        isActive = false
        stopWatching()
        timer?.cancel(); timer = nil; timerID = nil
        show()
    }
    /// The window went away: no hover exit will arrive for its views.
    func forgetPointerHolds() {
        holds.remove(.pointerOnPlayerBar); holds.remove(.pointerOnTopControls)
    }
    /// Listener activity: show the controls and restart the countdown.
    func poke() {
        guard isActive else { return }
        lastActivity = clock.now
        show()
        armTimer()
    }
    /// Holds are recorded even outside the room, so a pointer already on the
    /// player bar when the room opens keeps it on screen.
    func hold(_ hold: Hold, _ active: Bool) {
        if active {
            holds.insert(hold)
            if isActive { show() }
        } else if holds.remove(hold) != nil {
            poke()
        }
    }
    func isHolding(_ hold: Hold) -> Bool { holds.contains(hold) }

    private func show() { if !isVisible { isVisible = true } }

    /// One countdown at a time; activity only moves its deadline.
    private func armTimer() {
        guard isActive, timer == nil else { return }
        let id = UUID(); timerID = id
        timer = Task { [weak self] in await self?.countdown(id) }
    }
    private func countdown(_ id: UUID) async {
        defer { if timerID == id { timer = nil; timerID = nil } }
        while isActive, timerID == id {
            let due = lastActivity.advanced(by: delay)
            if clock.now >= due {
                // An open menu takes the events, so the room sees none;
                // reading a menu counts as activity.
                if menuOpen() { lastActivity = clock.now; continue }
                guard holds.isEmpty, !assistiveTechnology() else { return }
                isVisible = false
                onHide()
                return
            }
            do { try await clock.sleep(until: due) } catch { return }
        }
    }

    private func startWatching() {
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                                   .leftMouseDragged, .scrollWheel, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.poke() }
                return event
            }
        }
        // VoiceOver and Switch Control send no events to the room; when one
        // starts, the controls come back and stay.
        let changed: @Sendable (NSWorkspace, NSKeyValueObservedChange<Bool>) -> Void = { [weak self] _, _ in
            Task { @MainActor in self?.assistiveTechnologyChanged() }
        }
        accessibilityObservers = [NSWorkspace.shared.observe(\.isVoiceOverEnabled, changeHandler: changed),
                                  NSWorkspace.shared.observe(\.isSwitchControlEnabled, changeHandler: changed)]
    }
    private func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        accessibilityObservers.forEach { $0.invalidate() }
        accessibilityObservers = []
    }
    private func assistiveTechnologyChanged() {
        if assistiveTechnology() { show() } else { poke() }
    }

    static func assistiveTechnologyRunning() -> Bool {
        NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
    }
    /// Hides the pointer with the controls, like a video player; it comes
    /// back on the next move. Only over the room's own window, when it is in
    /// front with no sheet on it.
    static func hidePointer() {
        guard let app = NSApp, app.isActive, let window = app.keyWindow, window.attachedSheet == nil,
              window.frame.contains(NSEvent.mouseLocation) else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
    }
}
