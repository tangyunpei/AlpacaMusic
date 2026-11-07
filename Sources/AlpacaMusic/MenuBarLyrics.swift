import AppKit
import Observation
import SwiftUI

/// Where the lyrics panel sits: centered on the screen, so under the middle
/// of the menu bar and the notch, just below the menu bar.
enum MenuBarLyricsLayout {
    static let maximumWidth: CGFloat = 760
    static let height: CGFloat = 72
    static let topGap: CGFloat = 4
    /// Keeps a narrow screen's panel clear of its side edges.
    private static let sideMargin: CGFloat = 24

    /// The panel frame for a screen, or `.zero` when the screen frame is
    /// empty or not finite. The menu bar is what the visible frame leaves out
    /// at the top; a side Dock never moves the panel off center. While the
    /// menu bar hides itself the visible frame reaches the top edge, so
    /// `minimumMenuBarHeight` (the notch, or the status bar's thickness)
    /// still keeps the panel below where the menu bar appears.
    static func frame(screenFrame: CGRect, visibleFrame: CGRect, minimumMenuBarHeight: CGFloat) -> CGRect {
        let origin: CGPoint = screenFrame.origin
        let size: CGSize = screenFrame.size
        guard origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, !screenFrame.isInfinite else { return .zero }
        let top: CGFloat = origin.y + size.height
        let visibleTop: CGFloat = visibleFrame.isNull || visibleFrame.isInfinite ? top : visibleFrame.maxY
        let reserved: CGFloat = visibleTop.isFinite ? max(0, top - visibleTop) : 0
        let minimum: CGFloat = minimumMenuBarHeight.isFinite ? max(0, minimumMenuBarHeight) : 0
        let menuBar: CGFloat = max(reserved, minimum)
        let available: CGFloat = size.width - sideMargin * 2
        let width: CGFloat = min(maximumWidth, max(0, available))
        let x: CGFloat = origin.x + size.width / 2 - width / 2
        let y: CGFloat = top - menuBar - topGap - height
        guard x.isFinite, y.isFinite else { return .zero }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Which lyric the menu bar shows: a sung line of timed lyrics while music
/// plays. Paused playback, interludes and plain or missing lyrics show none.
enum MenuBarLyricsPresentation {
    static func cue(status: PlaybackStatus, document: LyricDocument?, position: Double) -> MiniLyricCue? {
        guard status == .playing,
              let cue = MiniLyricSelection.cue(in: document, at: position),
              cue.current != nil else { return nil }
        return cue
    }
}

/// The current lyric just below the menu bar, in a quiet capsule that hugs
/// the line: karaoke ink follows playback, the translation sits underneath
/// and new lines cross-fade in. It shows only while timed lyrics play, it
/// fades almost away while the pointer is over it, and it never takes clicks
/// or VoiceOver focus.
struct MenuBarLyricsView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    private let model: AppModel
    private let hover: MenuBarLyricsHover

    init(model: AppModel, hover: MenuBarLyricsHover = MenuBarLyricsHover()) {
        self.model = model
        self.hover = hover
    }

    var body: some View {
        let reduced: Bool = systemReduced || model.visual.reduceMotion
        MenuBarLyricsStage(model: model, hover: hover, reduced: reduced)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The panel's own space, so the capsule reports where it sits.
            .coordinateSpace(.named(MenuBarLyricsFade.space))
            .appTheme(.listeningRoom)
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .accessibilityIdentifier("menu-bar-lyrics")
            .accessibilityHidden(true)
    }
}

/// Shows the capsule only for a cue at the player's position, so it fades in
/// as a line starts and out on a pause, an interlude or the end of the lyrics.
/// While the pointer is over it, the capsule fades almost away.
private struct MenuBarLyricsStage: View {
    let model: AppModel
    let hover: MenuBarLyricsHover
    let reduced: Bool

    private var appearance: AnyTransition {
        AnyTransition.opacity.combined(with: AnyTransition.scale(scale: 0.96, anchor: .top))
    }

    var body: some View {
        let status: PlaybackStatus = model.player.status
        let position: Double = model.player.position
        let document: LyricDocument? = model.lyrics.document
        let cue: MiniLyricCue? = MenuBarLyricsPresentation.cue(status: status, document: document, position: position)
        let hidden: Bool = cue == nil
        let isReduced: Bool = reduced
        let faded: Bool = hover.isPointerOver
        ZStack(alignment: .top) {
            if let document, let cue {
                projected(document: document, cue: cue, status: status, position: position)
                    .transition(appearance)
            }
        }
        // Text and glass fade together, so what is under them shows through.
        .opacity(faded ? MenuBarLyricsFade.opacity : 1)
        .animation(isReduced ? nil : (faded ? MenuBarLyricsFade.fadeOut : MenuBarLyricsFade.fadeIn), value: faded)
        // Room for the capsule's shadow inside the panel.
        .padding(.top, 4)
        .padding(.horizontal, 12)
        .animation(isReduced ? nil : ExperienceMotion.panel, value: hidden)
        .transaction { (transaction: inout Transaction) in
            if isReduced {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    /// The cue at the player's own position bounds the smooth time, so the
    /// ink never reaches the next line before the player does.
    private func projected(document: LyricDocument, cue: MiniLyricCue, status: PlaybackStatus,
                           position: Double) -> some View {
        let cueEnd: Double? = cue.current?.end ?? cue.next?.start
        let playing: Bool = status == .playing
        let isReduced: Bool = reduced
        let lowPower: Bool = CompactLyricsMotion.lowPower(model.visual)
        return ProjectedLyricTime(position: position, isPlaying: playing, cueEnd: cueEnd,
                                  animates: playing && !isReduced, lowPower: lowPower) { (time: Double) in
            MenuBarLyricsCapsule(document: document, fallback: cue, status: status, time: time,
                                 hover: hover, reduced: isReduced)
        }
    }
}

/// One projected moment: the sung line and its translation in a capsule
/// that resizes with the text. A new line drifts up as it fades in, and the
/// old one drifts up as it fades out. The capsule reports its frame so the
/// overlay can tell when the pointer is over it.
private struct MenuBarLyricsCapsule: View {
    @Environment(\.appPalette) private var palette
    let document: LyricDocument
    /// The cue at the player's position, kept if the smooth time briefly
    /// lands between lines.
    let fallback: MiniLyricCue
    let status: PlaybackStatus
    let time: Double
    let hover: MenuBarLyricsHover
    let reduced: Bool
    /// Marks this capsule's reports, so a capsule still fading out cannot
    /// clear the frame of the one that replaced it.
    @State private var owner: UUID = UUID()

    private var drift: AnyTransition {
        AnyTransition.asymmetric(insertion: AnyTransition.opacity.combined(with: AnyTransition.offset(y: 5)),
                                 removal: AnyTransition.opacity.combined(with: AnyTransition.offset(y: -5)))
    }

    var body: some View {
        let projected: MiniLyricCue? = MenuBarLyricsPresentation.cue(status: status, document: document, position: time)
        let cue: MiniLyricCue = projected ?? fallback
        let key: Int? = cue.currentIndex
        ZStack {
            lines(cue)
                .id(key)
                .transition(drift)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .clipShape(Capsule(style: .continuous))
        .background { MenuBarLyricsBackdrop() }
        .onGeometryChange(for: CGRect.self) { (proxy: GeometryProxy) -> CGRect in
            proxy.frame(in: .named(MenuBarLyricsFade.space))
        } action: { (frame: CGRect) in
            hover.setCapsule(frame, from: owner)
        }
        .onDisappear { hover.clearCapsule(from: owner) }
        .animation(reduced ? nil : ExperienceMotion.panel, value: key)
    }

    @ViewBuilder private func lines(_ cue: MiniLyricCue) -> some View {
        if let index = cue.currentIndex, let line = cue.current {
            sungLine(line, index: index)
        }
    }

    private func sungLine(_ line: LyricLine, index: Int) -> some View {
        let context: LyricTimingContext = LyricSingingTiming.context(for: index, in: document.lines)
        let text: String = MenuBarLyricsText.singleLine(line.text)
        let translation: String? = MenuBarLyricsText.translation(of: line)
        return VStack(spacing: 2) {
            LyricProgressText(line: line, text: text, position: time, appearance: .highlight,
                              reduceMotion: reduced, timingContext: context)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
            if let translation {
                Text(verbatim: translation)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.text.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// Frosted glass with a dark tint and a hairline edge, legible over any
/// wallpaper or window. The tint is deep enough that the glass stays dark
/// over a bright window too, where the unsung words (a quarter of the text
/// color) would otherwise fade into it. Only the glass casts the shadow.
private struct MenuBarLyricsBackdrop: View {
    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.25), radius: 7, y: 3)
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.6))
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        }
    }
}

/// How the lyric gets out of the way of the pointer. The panel never takes
/// clicks, so whatever is under the capsule is always reachable; fading it
/// also lets you see what you are pointing at. Only the pointer's position is
/// read, never the screen.
enum MenuBarLyricsFade {
    /// The capsule's opacity while the pointer is over it: a faint trace that
    /// still shows where the lyric is.
    static let opacity: Double = 0.12
    static let fadeOut: Animation = Animation.easeOut(duration: 0.14)
    static let fadeIn: Animation = Animation.easeInOut(duration: 0.3)
    /// How often the pointer is read while a lyric shows.
    static let pollInterval: Duration = .milliseconds(100)
    /// The pointer counts as over the capsule within this margin of it, and
    /// stays over it until it is this much farther out, so a pointer resting
    /// on the edge does not make the lyric flicker.
    static let enterMargin: CGFloat = 6
    static let exitMargin: CGFloat = 16
    /// The panel's SwiftUI coordinate space: origin at the top left.
    static let space: String = "menu-bar-lyrics"

    /// The capsule, measured in the panel's SwiftUI space, in screen
    /// coordinates (origin at the bottom left), like the panel frame.
    static func screenRect(of capsule: CGRect, inPanel panelFrame: CGRect) -> CGRect {
        CGRect(x: panelFrame.minX + capsule.minX, y: panelFrame.maxY - capsule.maxY,
               width: capsule.width, height: capsule.height)
    }

    /// Whether the pointer (screen coordinates) is over the capsule. Without
    /// a capsule, or with an unusable frame or pointer, it is not.
    static func isPointerOver(_ pointer: CGPoint, capsule: CGRect?, panelFrame: CGRect, wasOver: Bool) -> Bool {
        guard let capsule, usable(capsule), usable(panelFrame),
              pointer.x.isFinite, pointer.y.isFinite else { return false }
        let margin: CGFloat = wasOver ? exitMargin : enterMargin
        let region: CGRect = screenRect(of: capsule, inPanel: panelFrame).insetBy(dx: -margin, dy: -margin)
        return region.contains(pointer)
    }

    private static func usable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }
}

/// Whether the pointer is over the lyric's capsule. The capsule reports its
/// frame here, and the overlay controller, which reads the pointer, decides.
@MainActor @Observable final class MenuBarLyricsHover {
    /// Whether the capsule should fade out of the pointer's way.
    private(set) var isPointerOver = false
    /// The capsule in the panel's SwiftUI space, or nil while no lyric shows.
    /// Only the controller reads it, so views never redraw for it.
    @ObservationIgnored private(set) var capsule: CGRect?
    /// Called when the capsule appears, moves, resizes or goes away.
    @ObservationIgnored var capsuleChanged: (@MainActor () -> Void)?
    /// The capsule that reported last. A new line's capsule can appear while
    /// the old one is still fading out, and only the latest one may clear.
    @ObservationIgnored private var owner: UUID?

    func setCapsule(_ frame: CGRect, from owner: UUID) {
        self.owner = owner
        update(frame)
    }

    /// Forgets the capsule when the one that reported last goes away.
    func clearCapsule(from owner: UUID) {
        guard owner == self.owner else { return }
        self.owner = nil
        update(nil)
    }

    private func update(_ frame: CGRect?) {
        guard frame != capsule else { return }
        capsule = frame
        capsuleChanged?()
    }

    func setPointerOver(_ over: Bool) {
        guard over != isPointerOver else { return }
        isPointerOver = over
    }
}

private enum MenuBarLyricsText {
    /// A multi-line cue (SRT, or merged duplicate timestamps) reads as one
    /// line. Only whitespace changes, so the karaoke ink still lines up.
    static func singleLine(_ text: String) -> String {
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { (character: Character) -> Bool in character.isNewline }) else { return trimmed }
        return String(trimmed.map { (character: Character) -> Character in character.isNewline ? " " : character })
    }

    /// The translation as one line, or nil when it has no readable text.
    static func translation(of line: LyricLine) -> String? {
        guard let translation = line.translation else { return nil }
        let text: String = singleLine(translation)
        return text.isEmpty ? nil : text
    }
}

/// The panel's content: the lyrics in the app's language, and nothing at all
/// (so no playback tracking) while the setting is off.
private struct MenuBarLyricsOverlayRoot: View {
    let model: AppModel
    let hover: MenuBarLyricsHover

    var body: some View {
        if model.showsMenuBarLyrics {
            MenuBarLyricsView(model: model, hover: hover)
                .environment(\.locale, model.language.locale)
        }
    }
}

/// Shows `MenuBarLyricsView` in a borderless, click-through panel just below
/// the menu bar while the setting is on. The panel never activates the app,
/// takes focus or joins window cycling, and it follows display, Space and
/// focus changes. While a lyric shows it reads the pointer's position a few
/// times a second, so the lyric can fade while the pointer is over it.
@MainActor final class MenuBarLyricsOverlayController {
    private weak var model: AppModel?
    private var running = false
    private var generation: UInt64 = 0
    private var showing = false
    private var panel: NSPanel?
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private let hover = MenuBarLyricsHover()
    private var pointerWatch: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        hover.capsuleChanged = { [weak self] in self?.followPointer() }
    }

    /// Follows the setting and the screens; calling it again while running
    /// does nothing.
    func start() {
        guard !running else { return }
        running = true
        generation &+= 1
        observeScreens()
        observe(generation)
    }

    /// Hides the panel and stops following the setting and the screens.
    func stop() {
        running = false
        showing = false
        removeScreenObservers()
        panel?.orderOut(nil)
        followPointer()
    }

    /// Reads the setting, re-arms for its next change, then shows or hides
    /// the panel. The token ends an observation chain left over from before a
    /// restart.
    private func observe(_ token: UInt64) {
        guard running, token == generation else { return }
        guard let model else {
            stop()
            return
        }
        let shows: Bool = withObservationTracking {
            model.showsMenuBarLyrics
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe(token) }
        }
        apply(shows, model: model)
    }

    /// Creates the panel the first time it is shown.
    private func apply(_ shows: Bool, model: AppModel) {
        showing = shows
        guard shows else {
            panel?.orderOut(nil)
            followPointer()
            return
        }
        if panel == nil { panel = Self.makePanel(model: model, hover: hover) }
        reposition()
    }

    /// Places the panel below the menu bar of the lyrics screen and keeps it
    /// in front; without a usable screen it stays hidden.
    private func reposition() {
        guard running, showing, let panel else { return }
        let frame: CGRect = Self.overlayFrame()
        guard !frame.isEmpty else {
            panel.orderOut(nil)
            followPointer()
            return
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.orderFrontRegardless()
        followPointer()
    }

    /// Reads the pointer now, then keeps reading it while a lyric shows on
    /// the visible panel. Otherwise it stops reading and clears the fade.
    private func followPointer() {
        guard running, showing, let panel, panel.isVisible, hover.capsule != nil else {
            pointerWatch?.cancel()
            pointerWatch = nil
            hover.setPointerOver(false)
            return
        }
        readPointer()
        guard pointerWatch == nil else { return }
        pointerWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: MenuBarLyricsFade.pollInterval)
                guard !Task.isCancelled, let self else { return }
                self.readPointer()
            }
        }
    }

    /// Whether the pointer is over the capsule right now. Only the pointer's
    /// position is read: nothing about the screen or other apps.
    private func readPointer() {
        guard running, showing, let panel, panel.isVisible else {
            hover.setPointerOver(false)
            return
        }
        let over: Bool = MenuBarLyricsFade.isPointerOver(NSEvent.mouseLocation, capsule: hover.capsule,
                                                         panelFrame: panel.frame, wasOver: hover.isPointerOver)
        hover.setPointerOver(over)
    }

    /// Repositions on display and Space changes, and when focus moves to
    /// another app or window, so with a menu bar on every display the panel
    /// follows the display in use.
    private func observeScreens() {
        removeScreenObservers()
        let workspace: NotificationCenter = NSWorkspace.shared.notificationCenter
        let triggers: [(center: NotificationCenter, name: Notification.Name)] = [
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (NotificationCenter.default, NSWindow.didBecomeKeyNotification),
            (workspace, NSWorkspace.activeSpaceDidChangeNotification),
            (workspace, NSWorkspace.didActivateApplicationNotification)
        ]
        observers = triggers.map { (trigger: (center: NotificationCenter, name: Notification.Name)) in
            let token: any NSObjectProtocol = trigger.center.addObserver(forName: trigger.name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reposition() }
            }
            return (trigger.center, token)
        }
    }

    private func removeScreenObservers() {
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
    }

    /// The display in use when every display has its own menu bar, otherwise
    /// the one display that has the menu bar. `NSScreen.main` is the display
    /// with keyboard focus, also while another app is frontmost.
    private static func lyricsScreen() -> NSScreen? {
        if NSScreen.screensHaveSeparateSpaces { return NSScreen.main ?? NSScreen.screens.first }
        return NSScreen.screens.first
    }

    private static func overlayFrame() -> CGRect {
        guard let screen = lyricsScreen() else { return .zero }
        let minimumMenuBarHeight: CGFloat = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        return MenuBarLyricsLayout.frame(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                         minimumMenuBarHeight: minimumMenuBarHeight)
    }

    /// A transparent panel above the menu bar's level that ignores the mouse
    /// and stays on every Space. SwiftUI never resizes it.
    private static func makePanel(model: AppModel, hover: MenuBarLyricsHover) -> NSPanel {
        let panel = NSPanel(contentRect: overlayFrame(), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Like the status items it sits under, it stays when the app is hidden.
        panel.canHide = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        let hostingView = NSHostingView(rootView: MenuBarLyricsOverlayRoot(model: model, hover: hover))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        return panel
    }
}
