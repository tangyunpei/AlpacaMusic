import AppKit
import SwiftUI

/// The status item artwork: the alpaca the build copies into the app bundle
/// (Resources/Brand/MenuBarIcon-Headphones.svg), drawn as a template so it
/// follows the menu bar's color. A bare SwiftPM build has no bundle resources
/// and shows a symbol instead: a waveform while playing, a note otherwise.
enum MenuBarPlayerIcon {
    static let artworkSize = NSSize(width: 18, height: 18)

    @MainActor static let artwork: NSImage? = artwork(at: Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"))

    static func symbol(for status: PlaybackStatus) -> String {
        status == .playing ? "waveform" : "music.note"
    }

    /// A template image at menu bar size, or nil when the file is missing or unreadable.
    static func artwork(at url: URL?) -> NSImage? {
        guard let url, let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        image.size = artworkSize
        image.isTemplate = true
        return image
    }
}

/// The status bar item: a template image only, with no text or motion.
struct MenuBarPlayerLabel: View {
    @Bindable var model: AppModel
    var body: some View {
        Group {
            if let artwork = MenuBarPlayerIcon.artwork {
                Image(nsImage: artwork).renderingMode(.template)
            } else {
                Image(systemName: MenuBarPlayerIcon.symbol(for: model.player.status)).renderingMode(.template)
            }
        }
        .accessibilityLabel(Text(verbatim: "AlpacaMusic"))
    }
}

/// The menu bar panel: now playing, progress, transport and window shortcuts.
struct MenuBarPlayerView: View {
    @Bindable var model: AppModel
    var body: some View {
        MenuBarPlayerPanel(model: model)
            .appTheme(.listeningRoom)
    }
}

private struct MenuBarPlayerPanel: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            nowPlaying
            if model.player.current != nil { progress }
            controls
            Divider().overlay(palette.line)
            actions
        }
        .padding(16)
        .frame(width: 300)
        .background { PlayerSurfaceBackdrop(track: model.player.current) }
        .foregroundStyle(palette.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu-bar-player")
    }

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            ArtworkView(track: model.player.current, radius: 8).frame(width: 56, height: 56)
                .shadow(color: Color.black.opacity(0.3), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.player.current?.title ?? L10n.string("未选择歌曲"))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
                if let track = model.player.current {
                    Text(track.artist).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                    Text(track.sourcePlaybackTitle).font(.system(size: 9)).foregroundStyle(palette.faint).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var progress: some View {
        VStack(spacing: 5) {
            ProgressLine(fraction: MiniPlayerTiming.fraction(position: model.player.position, duration: model.player.duration))
            HStack {
                Text(verbatim: MiniPlayerTiming.elapsedText(position: model.player.position, duration: model.player.duration))
                Spacer(minLength: 0)
                Text(verbatim: MiniPlayerTiming.remainingText(position: model.player.position, duration: model.player.duration))
            }
            .font(.system(size: 9, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(palette.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("播放进度"))
        .accessibilityValue(MiniPlayerTiming.elapsedText(position: model.player.position, duration: model.player.duration))
    }

    private var controls: some View {
        HStack {
            ToolButton(symbol: "shuffle", label: L10n.string("随机播放"), active: model.player.shuffle) { model.player.toggleShuffle() }
            Spacer(minLength: 0)
            CompactTransport(model: model, playSize: 34)
            Spacer(minLength: 0)
            ToolButton(symbol: model.player.repeatMode == .one ? "repeat.1" : "repeat", label: L10n.string("循环模式：\(model.player.repeatMode == .off ? L10n.string("不循环") : model.player.repeatMode == .all ? L10n.string("列表循环") : L10n.string("单曲循环"))"), active: model.player.repeatMode != .off) { model.player.cycleRepeat() }
        }
    }

    private var actions: some View {
        VStack(spacing: 2) {
            MenuPanelRow(title: L10n.string("迷你播放器"), symbol: "pip.enter") {
                PlayerWindows.switchWindow(to: PlayerWindowID.miniPlayer, from: PlayerWindowID.main,
                                           open: openWindow, dismiss: dismissWindow)
                NSApp.activate()
            }
            MenuPanelRow(title: L10n.string("菜单栏歌词"), symbol: "quote.bubble", checked: model.showsMenuBarLyrics) {
                model.showsMenuBarLyrics.toggle()
            }
            MenuPanelRow(title: L10n.string("打开 AlpacaMusic"), symbol: "macwindow") {
                openWindow(id: PlayerWindowID.main)
                NSApp.activate()
            }
            MenuPanelRow(title: L10n.string("退出 AlpacaMusic"), symbol: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

/// A compact, menu-like text button with a hover highlight. A row that
/// toggles a setting passes `checked` and shows a checkmark while it is on.
private struct MenuPanelRow: View {
    @Environment(\.appPalette) private var palette
    var title: String
    var symbol: String
    var checked: Bool? = nil
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 11, weight: .regular)).frame(width: 16)
                    .foregroundStyle(palette.secondary)
                Text(title).font(.system(size: 12)).foregroundStyle(palette.text).lineLimit(1)
                Spacer(minLength: 0)
                if checked == true {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(.rect)
            .background(hovering ? palette.text.opacity(0.08) : Color.clear, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(checked == true ? [.isSelected] : [])
        .onHover { hovering = $0 }
    }
}
