import AppKit
import SwiftUI

/// Scene identifiers shared by the main window, the mini player and the
/// menu bar player.
enum PlayerWindowID {
    static let main = "main"
    static let miniPlayer = "mini-player"
}

@MainActor enum PlayerWindows {
    /// Opens `target`, then closes `source` a moment later, so the app never
    /// has zero windows in between (closing the last window may quit it).
    static func switchWindow(to target: String, from source: String,
                             open: OpenWindowAction, dismiss: DismissWindowAction) {
        open(id: target)
        Task {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            dismiss(id: source)
        }
    }
}

/// Pure timing helpers for the compact player surfaces. A duration that is
/// not finite or not positive (live streams, unknown or malformed values)
/// has no progress and cannot be scrubbed, matching `PlaybackControls`.
enum MiniPlayerTiming {
    static func validDuration(_ duration: Double) -> Double? {
        duration.isFinite && duration > 0 ? duration : nil
    }
    /// Played fraction in 0...1; 0 when either value is unusable.
    static func fraction(position: Double, duration: Double) -> Double {
        guard let total = validDuration(duration), position.isFinite else { return 0 }
        return min(1, max(0, position / total))
    }
    /// The position in seconds for a scrub fraction, or nil when seeking is
    /// not possible.
    static func seekTarget(fraction: Double, duration: Double) -> Double? {
        guard let total = validDuration(duration), fraction.isFinite else { return nil }
        return min(1, max(0, fraction)) * total
    }
    /// Seconds left, or nil when the duration is unusable.
    static func remaining(position: Double, duration: Double) -> Double? {
        guard let total = validDuration(duration) else { return nil }
        let elapsed = position.isFinite ? min(total, max(0, position)) : 0
        return total - elapsed
    }
    static func elapsedText(position: Double, duration: Double) -> String {
        let elapsed = position.isFinite ? max(0, position) : 0
        guard let total = validDuration(duration) else { return formattedTime(elapsed) }
        return formattedTime(min(total, elapsed))
    }
    /// "-m:ss" for a known duration, the live label for an infinite one,
    /// and a dash otherwise.
    static func remainingText(position: Double, duration: Double) -> String {
        if let left = remaining(position: position, duration: duration) { return "-" + formattedTime(left) }
        return duration.isInfinite ? formattedTime(duration) : "—"
    }
}

/// The mini player's layouts, smallest first: the cover alone with play /
/// pause, a lyric strip, and a card with the full controls.
enum MiniPlayerStyle: String, CaseIterable, Identifiable, Sendable {
    case artwork, lyrics, card

    var id: String { rawValue }
    var title: String {
        switch self {
        case .artwork: L10n.string("封面")
        case .lyrics: L10n.string("歌词")
        case .card: L10n.string("卡片")
        }
    }
    var symbol: String {
        switch self {
        case .artwork: "photo"
        case .lyrics: "quote.bubble"
        case .card: "rectangle"
        }
    }
    /// The exact window size: the content fills the whole window, under the
    /// title bar too.
    var size: CGSize {
        switch self {
        case .artwork: CGSize(width: 156, height: 156)
        case .lyrics: CGSize(width: 480, height: 84)
        case .card: CGSize(width: 400, height: 236)
        }
    }
}

/// The mini player's window chrome: the content reaches the window's top
/// edge, and the close, minimize and zoom buttons show only while the
/// pointer is over the player, so the cover style is a plain square.
@MainActor enum MiniPlayerWindowChrome {
    static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    static func apply(to window: NSWindow, showsButtons: Bool) {
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        // The title bar's safe area would make the content-sized window
        // taller than the style; cancelling it keeps the window exactly the
        // style's size, with the buttons over the content.
        if let content = window.contentView {
            let titleBar: CGFloat = content.safeAreaInsets.top - content.additionalSafeAreaInsets.top
            if content.additionalSafeAreaInsets.top != -titleBar {
                content.additionalSafeAreaInsets = NSEdgeInsets(top: -titleBar, left: 0, bottom: 0, right: 0)
            }
        }
        for type in buttonTypes {
            guard let button = window.standardWindowButton(type), button.isHidden == showsButtons else { continue }
            button.isHidden = !showsButtons
        }
    }

    /// A style change resizes the window from its top-left corner, so a
    /// player in the screen's top-right corner would grow off the screen or
    /// shrink away from the corner. This keeps a player that touched the
    /// right edge against it, and any player inside its screen.
    static func keepOnScreen(_ window: NSWindow, previousFrame: CGRect?) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let origin: CGPoint = resizedOrigin(for: window.frame, previousFrame: previousFrame, in: screen.visibleFrame)
        if origin != window.frame.origin { window.setFrameOrigin(origin) }
    }

    /// The origin after a resize: a frame whose previous right edge was at
    /// the right edge of `visible` stays there, then it is kept inside.
    nonisolated static func resizedOrigin(for frame: CGRect, previousFrame: CGRect?, in visible: CGRect) -> CGPoint {
        var anchored: CGRect = frame
        if let previousFrame, previousFrame.maxX.isFinite, visible.maxX.isFinite, frame.width.isFinite,
           abs(previousFrame.maxX - visible.maxX) <= 1 {
            anchored.origin.x = visible.maxX - frame.width
        }
        return onScreenOrigin(for: anchored, in: visible)
    }

    /// The origin that keeps `frame` inside `visible`, moving it as little as
    /// possible. A frame larger than `visible` keeps its top-left corner
    /// inside; an unusable rectangle leaves the origin unchanged.
    nonisolated static func onScreenOrigin(for frame: CGRect, in visible: CGRect) -> CGPoint {
        let values: [CGFloat] = [frame.minX, frame.minY, frame.width, frame.height,
                                 visible.minX, visible.minY, visible.width, visible.height]
        guard values.allSatisfy({ (value: CGFloat) -> Bool in value.isFinite }),
              visible.width > 0, visible.height > 0 else { return frame.origin }
        var origin: CGPoint = frame.origin
        if origin.x + frame.width > visible.maxX { origin.x = visible.maxX - frame.width }
        if origin.x < visible.minX { origin.x = visible.minX }
        if origin.y < visible.minY { origin.y = visible.minY }
        if origin.y + frame.height > visible.maxY { origin.y = visible.maxY - frame.height }
        return origin
    }
}

/// Finds the window that hosts the mini player, keeps its chrome in step
/// with the hover and keeps it on screen when a style change resizes it. It
/// draws nothing and never takes clicks.
private struct MiniPlayerWindowChromeHost: NSViewRepresentable {
    var showsButtons: Bool

    func makeNSView(context: Context) -> ChromeProbe { ChromeProbe() }

    func updateNSView(_ view: ChromeProbe, context: Context) {
        view.showsButtons = showsButtons
    }

    final class ChromeProbe: NSView {
        var showsButtons: Bool = false {
            didSet { if showsButtons != oldValue { applyChrome() } }
        }
        private var frameObservers: [any NSObjectProtocol] = []
        /// The window's frame before the latest resize.
        private var settledFrame: CGRect?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            for observer in frameObservers { NotificationCenter.default.removeObserver(observer) }
            frameObservers = []
            settledFrame = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyChrome()
            guard let window else { return }
            settledFrame = window.frame
            let center: NotificationCenter = NotificationCenter.default
            frameObservers = [
                center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.windowResized() }
                },
                center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.settledFrame = self?.window?.frame }
                }
            ]
        }

        private func windowResized() {
            guard let window else { return }
            MiniPlayerWindowChrome.keepOnScreen(window, previousFrame: settledFrame)
            settledFrame = window.frame
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func applyChrome() {
            guard let window else { return }
            MiniPlayerWindowChrome.apply(to: window, showsButtons: showsButtons)
        }
    }
}

/// The floating player in the chosen style. A style menu and an expand
/// button appear on hover, and the context menu offers the same choices.
struct MiniPlayerView: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Bindable var model: AppModel
    @State private var hovering = false

    private var reduced: Bool { systemReduced || model.visual.reduceMotion }

    var body: some View {
        let reduceMotion = reduced
        surface(model.miniPlayerStyle, reduceMotion: reduceMotion)
            .ignoresSafeArea()
            .background { MiniPlayerWindowChromeHost(showsButtons: hovering) }
            .onHover { hovering = $0 }
            .contextMenu {
                stylePicker
                Divider()
                Button(L10n.string("打开主窗口")) { showMainWindow() }
            }
            .animation(reduceMotion ? nil : ExperienceMotion.control, value: hovering)
            .animation(reduceMotion ? nil : ExperienceMotion.panel, value: model.player.current?.id)
            .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mini-player")
    }

    /// The layout at its style's exact size over the blurred artwork. Only
    /// the layouts cross-fade; the frame, and so the window, changes at once.
    private func surface(_ style: MiniPlayerStyle, reduceMotion: Bool) -> some View {
        let size = style.size
        return ZStack {
            switch style {
            case .artwork: MiniArtworkLayout(model: model, hovering: hovering).transition(AnyTransition.opacity)
            case .lyrics: MiniLyricsLayout(model: model).transition(AnyTransition.opacity)
            case .card: MiniCardLayout(model: model).transition(AnyTransition.opacity)
            }
        }
        .animation(reduceMotion ? nil : ExperienceMotion.panel, value: style)
        .frame(width: size.width, height: size.height)
        .clipped()
        .overlay(alignment: .topTrailing) { windowControls }
        .background { PlayerSurfaceBackdrop(track: model.player.current).ignoresSafeArea() }
        .foregroundStyle(palette.text)
    }

    /// The style menu and the expand button. They fade out rather than
    /// leave, so VoiceOver still reaches them without a pointer.
    private var windowControls: some View {
        HStack(spacing: 0) {
            Menu { stylePicker } label: {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
                    .foregroundStyle(palette.text.opacity(0.82))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.string("迷你播放器样式"))
            .accessibilityLabel(L10n.string("迷你播放器样式"))
            SurfaceIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: L10n.string("打开主窗口"), size: 22) { showMainWindow() }
        }
        .padding(4)
        .opacity(hovering ? 1 : 0)
    }

    private var stylePicker: some View {
        Picker(L10n.string("迷你播放器样式"), selection: $model.miniPlayerStyle) {
            ForEach(MiniPlayerStyle.allCases) { style in
                Label(style.title, systemImage: style.symbol).tag(style)
            }
        }
        .pickerStyle(.inline)
    }

    private func showMainWindow() {
        PlayerWindows.switchWindow(to: PlayerWindowID.main, from: PlayerWindowID.miniPlayer,
                                   open: openWindow, dismiss: dismissWindow)
    }
}

/// The cover alone with play / pause on it; previous, next and progress
/// appear on hover. The cover is not a button, so it still drags the window.
private struct MiniArtworkLayout: View {
    @Bindable var model: AppModel
    var hovering: Bool

    var body: some View {
        let size = MiniPlayerStyle.artwork.size
        let track = model.player.current
        let progress = MiniPlayerTiming.fraction(position: model.player.position, duration: model.player.duration)
        let shade: [Color] = [Color.black.opacity(0.36), Color.black.opacity(0.08), Color.black.opacity(0.36)]
        ZStack {
            ArtworkView(track: track, radius: 0, highResolution: true)
                .frame(width: size.width, height: size.height)
                .clipped()
            LinearGradient(colors: shade, startPoint: .top, endPoint: .bottom)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            HStack(spacing: 12) {
                if track != nil {
                    CoverRoundButton(symbol: "backward.fill", label: L10n.string("上一首")) { Task { await model.player.previous() } }
                        .opacity(hovering ? 1 : 0)
                }
                CoverPlayButton(model: model)
                if track != nil {
                    CoverRoundButton(symbol: "forward.fill", label: L10n.string("下一首")) { Task { await model.player.next() } }
                        .opacity(hovering ? 1 : 0)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if track != nil { ProgressLine(fraction: progress, height: 2).opacity(hovering ? 1 : 0) }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mini-player-artwork")
    }
}

/// The lyric strip: artwork, the current and next lines, transport and a
/// thin progress line along the bottom edge.
private struct MiniLyricsLayout: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel

    var body: some View {
        let size = MiniPlayerStyle.lyrics.size
        let track = model.player.current
        let progress = MiniPlayerTiming.fraction(position: model.player.position, duration: model.player.duration)
        HStack(spacing: 14) {
            MiniArtworkButton(track: track, side: 56, radius: 8)
            Group {
                if track != nil {
                    CompactLyricLines(model: model, primarySize: 16, secondarySize: 12, showsNextLine: true,
                                      alignment: .leading, fallback: .trackInfo)
                } else {
                    Text(L10n.string("未选择歌曲")).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if track != nil || !model.library.tracks.isEmpty {
                CompactTransport(model: model, playSize: 26)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottom) {
            if track != nil { ProgressLine(fraction: progress, height: 2) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mini-player-lyrics")
    }
}

/// The card: large artwork, title, the current lyric, a scrub bar and the
/// full transport with shuffle and repeat.
private struct MiniCardLayout: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel

    var body: some View {
        let size = MiniPlayerStyle.card.size
        HStack(spacing: 18) {
            MiniArtworkButton(track: model.player.current, side: 132, radius: 10, highResolution: true)
            Group {
                if let track = model.player.current { details(track) } else { empty }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mini-player-card")
    }

    private func details(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
                Text(verbatim: "\(track.artist) · \(track.sourcePlaybackTitle)")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
            }
            // A fixed height keeps the card still while lyrics come and go.
            CompactLyricLines(model: model, primarySize: 14, secondarySize: 11, showsNextLine: true,
                              alignment: .leading, fallback: .hidden)
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
                .padding(.vertical, 10)
            HStack(spacing: 8) {
                ScrubBar(model: model)
                PlayerTimeReadout(model: model)
            }
            controls.padding(.top, 8)
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            SurfaceIconButton(symbol: "shuffle", label: L10n.string("随机播放"), active: model.player.shuffle) { model.player.toggleShuffle() }
            Spacer(minLength: 0)
            CompactTransport(model: model, playSize: 32)
            Spacer(minLength: 0)
            SurfaceIconButton(symbol: repeatSymbol, label: repeatLabel, active: model.player.repeatMode != .off) { model.player.cycleRepeat() }
        }
    }

    private var repeatSymbol: String { model.player.repeatMode == .one ? "repeat.1" : "repeat" }
    private var repeatLabel: String {
        let mode: String
        switch model.player.repeatMode {
        case .off: mode = L10n.string("不循环")
        case .all: mode = L10n.string("列表循环")
        case .one: mode = L10n.string("单曲循环")
        }
        return L10n.string("循环模式：\(mode)")
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("未选择歌曲")).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
            if !model.library.tracks.isEmpty { CompactTransport(model: model, playSize: 32) }
        }
    }
}

/// The artwork as a button back to the main window. VoiceOver uses the
/// expand button instead, which does the same.
private struct MiniArtworkButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    var track: Track?
    var side: CGFloat
    var radius: CGFloat
    var highResolution = false

    var body: some View {
        Button {
            PlayerWindows.switchWindow(to: PlayerWindowID.main, from: PlayerWindowID.miniPlayer,
                                       open: openWindow, dismiss: dismissWindow)
        } label: {
            ArtworkView(track: track, radius: radius, highResolution: highResolution)
                .frame(width: side, height: side)
                .shadow(color: Color.black.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .help(L10n.string("打开主窗口"))
        .accessibilityHidden(true)
    }
}

/// The always-visible play / pause button on the cover, with the same
/// action as `CompactTransport`.
private struct CoverPlayButton: View {
    @Bindable var model: AppModel

    private var isPlaying: Bool { model.player.status == .playing }
    private var canPlay: Bool { model.player.current != nil || !model.library.tracks.isEmpty }
    private var label: String { isPlaying ? L10n.string("暂停") : L10n.string("播放") }
    /// Optically centers the play triangle in its circle.
    private var glyphOffset: CGFloat { isPlaying ? 0 : 1.5 }

    var body: some View {
        Button { Task { await model.toggle() } } label: {
            Group {
                if model.player.status == .loading {
                    ProgressView().controlSize(.mini).tint(Color.white)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .offset(x: glyphOffset)
                }
            }
            .foregroundStyle(Color.white)
            .frame(width: 46, height: 46)
            .background { CoverButtonDisc() }
            .contentShape(.circle)
            .shadow(color: Color.black.opacity(0.3), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .opacity(canPlay ? 1 : 0.5)
        .help(label)
        .accessibilityLabel(label)
        .disabled(!canPlay)
    }
}

/// A small frosted circular button on the cover.
private struct CoverRoundButton: View {
    var symbol: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 26, height: 26)
                .background { CoverButtonDisc() }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Frosted glass with a light dark tint, legible on any cover.
private struct CoverButtonDisc: View {
    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(Color.black.opacity(0.18))
            Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

/// The current artwork, blurred and dimmed, behind a compact player surface.
struct PlayerSurfaceBackdrop: View {
    @Environment(\.appPalette) private var palette
    let track: Track?
    var body: some View {
        ZStack {
            palette.background
            ArtworkView(track: track, radius: 0)
                .scaleEffect(1.5)
                .blur(radius: 28)
                .opacity(0.4)
            LinearGradient(colors: [palette.background.opacity(0.2), palette.background.opacity(0.78)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A small icon-only button for the compact surfaces.
struct SurfaceIconButton: View {
    @Environment(\.appPalette) private var palette
    var symbol: String
    var label: String
    var size: CGFloat = 26
    var active = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium))
                .frame(width: size, height: size).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? palette.accent : palette.text.opacity(0.82))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Previous, play / pause and next, with the same actions as `PlaybackControls`.
struct CompactTransport: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var playSize: CGFloat = 30

    private var isPlaying: Bool { model.player.status == .playing }

    var body: some View {
        HStack(spacing: 8) {
            SurfaceIconButton(symbol: "backward.end.fill", label: L10n.string("上一首")) { Task { await model.player.previous() } }
                .disabled(model.player.current == nil)
            playButton
            SurfaceIconButton(symbol: "forward.end.fill", label: L10n.string("下一首")) { Task { await model.player.next() } }
                .disabled(model.player.current == nil)
        }
    }

    private var playButton: some View {
        Button { Task { await model.toggle() } } label: {
            Group {
                if model.player.status == .loading {
                    ProgressView().controlSize(.mini).tint(palette.onPrimary)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: playSize * 0.42, weight: .medium))
                }
            }
            .frame(width: playSize, height: playSize)
            .foregroundStyle(palette.onPrimary)
            .background(palette.primary, in: .circle)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(isPlaying ? L10n.string("暂停") : L10n.string("播放"))
        .accessibilityLabel(isPlaying ? L10n.string("暂停") : L10n.string("播放"))
        .disabled(model.player.current == nil && model.library.tracks.isEmpty)
    }
}

/// Elapsed and remaining time in monospaced digits.
struct PlayerTimeReadout: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var body: some View {
        let position = model.player.position
        let duration = model.player.duration
        Text(verbatim: "\(MiniPlayerTiming.elapsedText(position: position, duration: duration))  \(MiniPlayerTiming.remainingText(position: position, duration: duration))")
            .font(.system(size: 9, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(palette.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A thin read-only progress line.
struct ProgressLine: View {
    @Environment(\.appPalette) private var palette
    let fraction: Double
    var height: CGFloat = 3
    var body: some View {
        GeometryReader { proxy in
            let shown = fraction.isFinite ? min(1, max(0, fraction)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(palette.text.opacity(0.14))
                Capsule().fill(palette.accent).frame(width: proxy.size.width * CGFloat(shown))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The progress line with a drag-to-seek gesture; disabled while the
/// duration is unknown or live.
struct ScrubBar: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @GestureState private var scrub: Double? = nil
    @State private var hovering = false

    private var canSeek: Bool { MiniPlayerTiming.validDuration(model.player.duration) != nil }

    var body: some View {
        let played = MiniPlayerTiming.fraction(position: model.player.position, duration: model.player.duration)
        let shown = scrub ?? played
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            ZStack(alignment: .leading) {
                ProgressLine(fraction: shown, height: hovering || scrub != nil ? 4 : 3)
                if canSeek && (hovering || scrub != nil) {
                    Circle().fill(palette.text).frame(width: 9, height: 9)
                        .offset(x: width * CGFloat(shown) - 4.5)
                }
            }
            .frame(width: width, height: proxy.size.height)
            .contentShape(.rect)
            .gesture(scrubGesture(width: width))
        }
        .frame(height: 12)
        .onHover { hovering = $0 }
        .allowsHitTesting(canSeek)
        .accessibilityElement()
        .accessibilityLabel(L10n.string("播放进度"))
        .accessibilityValue(MiniPlayerTiming.elapsedText(position: model.player.position, duration: model.player.duration))
        .accessibilityAdjustableAction { direction in adjust(direction) }
        .disabled(!canSeek)
    }

    /// VoiceOver / keyboard seeking in ten-second steps.
    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        guard let total = MiniPlayerTiming.validDuration(model.player.duration) else { return }
        let position = model.player.position
        let now = position.isFinite ? min(total, max(0, position)) : 0
        if direction == .increment {
            model.player.seek(to: min(total, now + 10))
        } else if direction == .decrement {
            model.player.seek(to: max(0, now - 10))
        }
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($scrub) { value, state, _ in
                state = min(1, max(0, Double(value.location.x / width)))
            }
            .onEnded { value in
                let fraction = min(1, max(0, Double(value.location.x / width)))
                if let target = MiniPlayerTiming.seekTarget(fraction: fraction, duration: model.player.duration) {
                    model.player.seek(to: target)
                }
            }
    }
}

/// View menu: switch from the full window to the mini player (⌥⌘M).
struct MiniPlayerCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) { MiniPlayerMenuButton() }
    }
}

struct MiniPlayerMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        Button(L10n.string("迷你播放器")) {
            PlayerWindows.switchWindow(to: PlayerWindowID.miniPlayer, from: PlayerWindowID.main,
                                       open: openWindow, dismiss: dismissWindow)
        }
        .keyboardShortcut("m", modifiers: [.command, .option])
    }
}

/// A menu command whose result only the main window presents (import
/// panels, sheets, immersive, lyrics, the queue). It brings that window
/// forward first, so nothing changes out of sight while only the mini
/// player or the menu bar player is showing.
struct MainWindowCommandButton: View {
    @Environment(\.openWindow) private var openWindow
    let title: String
    var systemImage: String? = nil
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void

    var body: some View {
        button.keyboardShortcut(shortcut)
    }

    @ViewBuilder private var button: some View {
        if let systemImage {
            Button(title, systemImage: systemImage) { perform() }
        } else {
            Button(title) { perform() }
        }
    }

    private func perform() {
        openWindow(id: PlayerWindowID.main)
        action()
    }
}
