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

/// The compact floating player: artwork, title, transport and a scrubbable
/// progress line over a softly blurred copy of the current artwork.
struct MiniPlayerView: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Bindable var model: AppModel

    private var reduced: Bool { systemReduced || model.visual.reduceMotion }

    var body: some View {
        content
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(width: 360, height: 104)
            .background { PlayerSurfaceBackdrop(track: model.player.current).ignoresSafeArea() }
            .foregroundStyle(palette.text)
            .animation(reduced ? nil : ExperienceMotion.panel, value: model.player.current?.id)
            .transaction { if reduced { $0.animation = nil; $0.disablesAnimations = true } }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mini-player")
    }

    @ViewBuilder private var content: some View {
        if let track = model.player.current {
            HStack(spacing: 14) {
                artworkButton(track)
                VStack(alignment: .leading, spacing: 0) {
                    header(track)
                    Spacer(minLength: 4)
                    HStack(spacing: 6) {
                        CompactTransport(model: model, playSize: 28)
                        Spacer(minLength: 4)
                        PlayerTimeReadout(model: model)
                    }
                    ScrubBar(model: model).padding(.top, 5)
                }
            }
        } else {
            emptyContent
        }
    }

    private func artworkButton(_ track: Track) -> some View {
        Button { showMainWindow() } label: {
            ArtworkView(track: track, radius: 9).frame(width: 72, height: 72)
                .shadow(color: Color.black.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .help(L10n.string("打开主窗口"))
        .accessibilityHidden(true)
    }

    private func header(_ track: Track) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
                Text(verbatim: "\(track.artist) · \(track.sourcePlaybackTitle)")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            SurfaceIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: L10n.string("打开主窗口"), size: 22) { showMainWindow() }
        }
    }

    private var emptyContent: some View {
        HStack(spacing: 14) {
            ArtworkView(track: nil, radius: 9).frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.string("未选择歌曲")).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
                HStack(spacing: 8) {
                    if !model.library.tracks.isEmpty { CompactTransport(model: model, playSize: 28) }
                    SurfaceIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: L10n.string("打开主窗口"), size: 26) { showMainWindow() }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func showMainWindow() {
        PlayerWindows.switchWindow(to: PlayerWindowID.main, from: PlayerWindowID.miniPlayer,
                                   open: openWindow, dismiss: dismissWindow)
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
