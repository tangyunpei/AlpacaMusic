import AppKit
import Observation
import SwiftUI

/// Where the lyrics panel sits: centered just below the menu bar, which a
/// screen's visible frame already leaves out.
enum MenuBarLyricsLayout {
    static let maximumWidth: CGFloat = 760
    static let height: CGFloat = 72
    static let topGap: CGFloat = 4
    /// Keeps a narrow screen's panel clear of its side edges.
    private static let sideMargin: CGFloat = 24

    /// The panel frame for a screen's visible frame, or `.zero` when that
    /// frame is empty or not finite.
    static func frame(visibleFrame: CGRect) -> CGRect {
        let origin: CGPoint = visibleFrame.origin
        let size: CGSize = visibleFrame.size
        guard origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, !visibleFrame.isInfinite else { return .zero }
        let available: CGFloat = size.width - sideMargin * 2
        let width: CGFloat = min(maximumWidth, max(0, available))
        let midX: CGFloat = origin.x + size.width / 2
        let x: CGFloat = midX - width / 2
        let top: CGFloat = origin.y + size.height
        let y: CGFloat = top - topGap - height
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
/// and new lines cross-fade in. It shows only while timed lyrics play, and it
/// never takes clicks or VoiceOver focus.
struct MenuBarLyricsView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        let reduced: Bool = systemReduced || model.visual.reduceMotion
        MenuBarLyricsStage(model: model, reduced: reduced)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .appTheme(.listeningRoom)
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .accessibilityIdentifier("menu-bar-lyrics")
            .accessibilityHidden(true)
    }
}

/// Shows the capsule only for a cue at the player's position, so it fades in
/// as a line starts and out on a pause, an interlude or the end of the lyrics.
private struct MenuBarLyricsStage: View {
    let model: AppModel
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
        ZStack(alignment: .top) {
            if let document, let cue {
                projected(document: document, cue: cue, status: status, position: position)
                    .transition(appearance)
            }
        }
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
            MenuBarLyricsCapsule(document: document, fallback: cue, status: status, time: time, reduced: isReduced)
        }
    }
}

/// One projected moment: the sung line and its translation in a capsule
/// that resizes with the text. A new line drifts up as it fades in, and the
/// old one drifts up as it fades out.
private struct MenuBarLyricsCapsule: View {
    @Environment(\.appPalette) private var palette
    let document: LyricDocument
    /// The cue at the player's position, kept if the smooth time briefly
    /// lands between lines.
    let fallback: MiniLyricCue
    let status: PlaybackStatus
    let time: Double
    let reduced: Bool

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
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
            if let translation {
                Text(verbatim: translation)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.text.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// Frosted glass with a dark tint and a hairline edge, legible over any
/// wallpaper or window. Only the glass casts the soft shadow.
private struct MenuBarLyricsBackdrop: View {
    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.25), radius: 7, y: 3)
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.3))
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        }
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

    var body: some View {
        if model.showsMenuBarLyrics {
            MenuBarLyricsView(model: model)
                .environment(\.locale, model.language.locale)
        }
    }
}

/// Shows `MenuBarLyricsView` in a borderless, click-through panel just below
/// the menu bar while the setting is on. The panel never activates the app,
/// takes focus or joins window cycling, and it follows display and Space
/// changes.
@MainActor final class MenuBarLyricsOverlayController {
    private weak var model: AppModel?
    private var running = false
    private var generation: UInt64 = 0
    private var showing = false
    private var panel: NSPanel?
    private var screenObserver: (any NSObjectProtocol)?
    private var spaceObserver: (any NSObjectProtocol)?

    init(model: AppModel) {
        self.model = model
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
            return
        }
        if panel == nil { panel = Self.makePanel(model: model) }
        reposition()
    }

    /// Places the panel below the menu bar of the main screen and keeps it in
    /// front; without a usable screen it stays hidden.
    private func reposition() {
        guard running, showing, let panel else { return }
        let frame: CGRect = Self.overlayFrame()
        guard !frame.isEmpty else {
            panel.orderOut(nil)
            return
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.orderFrontRegardless()
    }

    private func observeScreens() {
        removeScreenObservers()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reposition() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reposition() }
        }
    }

    private func removeScreenObservers() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        screenObserver = nil
        spaceObserver = nil
    }

    private static func overlayFrame() -> CGRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        return MenuBarLyricsLayout.frame(visibleFrame: screen.visibleFrame)
    }

    /// A transparent panel above the menu bar's level that ignores the mouse
    /// and stays on every Space. SwiftUI never resizes it.
    private static func makePanel(model: AppModel) -> NSPanel {
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
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        let hostingView = NSHostingView(rootView: MenuBarLyricsOverlayRoot(model: model))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        return panel
    }
}
