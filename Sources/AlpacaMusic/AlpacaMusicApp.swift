import AppKit
import SwiftUI

@main
struct AlpacaMusicApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("AlpacaMusic", id: PlayerWindowID.main) {
            ContentView(model: model)
                .environment(\.locale, model.language.locale)
                .frame(minWidth: 1040, minHeight: 720)
                .appTheme(model.immersive ? .listeningRoom : .bauhaus)
                .preferredColorScheme(model.immersive ? .dark : .light)
                .task { delegate.attach(model); await model.load() }
        }
        .defaultSize(width: 1440, height: 940)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.string("关于 AlpacaMusic")) { AboutPanel.show() }
            }
            CommandGroup(after: .newItem) {
                MainWindowCommandButton(title: L10n.string("导入音乐文件…"), systemImage: "plus",
                                        shortcut: KeyboardShortcut("o", modifiers: .command)) { model.beginImport(folder: false) }
                MainWindowCommandButton(title: L10n.string("导入音乐文件夹…"), systemImage: "folder.badge.plus",
                                        shortcut: KeyboardShortcut("o", modifiers: [.command, .shift])) { model.beginImport(folder: true) }
                MainWindowCommandButton(title: L10n.string("添加音频链接…"), systemImage: "link") { model.sheet = .url }
            }
            CommandMenu(L10n.string("播放")) {
                Button(model.player.status == .playing ? L10n.string("暂停") : L10n.string("播放")) { Task { await model.toggle() } }
                    .keyboardShortcut(.space, modifiers: [])
                Button(L10n.string("上一首")) { Task { await model.player.previous() } }.keyboardShortcut(.leftArrow, modifiers: .command)
                Button(L10n.string("下一首")) { Task { await model.player.next() } }.keyboardShortcut(.rightArrow, modifiers: .command)
                Divider()
                Button(L10n.string("切换随机播放")) { model.player.toggleShuffle() }
                Button(L10n.string("切换循环模式")) { model.player.cycleRepeat() }
                Button(L10n.string("静音 / 取消静音")) { model.player.toggleMute() }.keyboardShortcut("m", modifiers: [.command, .shift]).disabled(!model.player.supportsVolumeControl)
            }
            CommandGroup(after: .toolbar) {
                MainWindowCommandButton(title: L10n.string("歌词"),
                                        shortcut: KeyboardShortcut("l", modifiers: [.command, .shift])) { model.revealLyrics() }
                MainWindowCommandButton(title: L10n.string("沉浸模式"),
                                        shortcut: KeyboardShortcut("i", modifiers: [.command, .shift])) { withAnimation(.smooth(duration: 0.25)) { model.immersive.toggle() } }
                MainWindowCommandButton(title: L10n.string("播放队列"),
                                        shortcut: KeyboardShortcut("q", modifiers: [.command, .shift])) { withAnimation(.smooth(duration: 0.22)) { model.queueOpen.toggle() } }
            }
            MiniPlayerCommands()
        }
        Window(L10n.string("迷你播放器"), id: PlayerWindowID.miniPlayer) {
            MiniPlayerView(model: model)
                .environment(\.locale, model.language.locale)
                .appTheme(.listeningRoom)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
        .windowLevel(.floating)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)
        MenuBarExtra(isInserted: $model.showsMenuBarPlayer) {
            MenuBarPlayerView(model: model)
                .environment(\.locale, model.language.locale)
                .preferredColorScheme(.dark)
        } label: {
            MenuBarPlayerLabel(model: model)
        }
        .menuBarExtraStyle(.window)
        Settings {
            ScrollView { VisualSettingsView(model: model).padding(28) }.frame(width: 590, height: 680)
                .environment(\.locale, model.language.locale)
                .background(AppPalette.bauhaus.background).appTheme(.bauhaus).modifier(PanelEntrance(appReduced: model.visual.reduceMotion))
                .preferredColorScheme(.light)
        }
    }
}

@MainActor private enum AboutPanel {
    static func show() {
        let description = L10n.string("本地与在线音乐，沉浸式视觉与动态歌词。")
        let author = "byalpaca"
        let website = "byalpaca.dev"
        let text = "\(description)\n\n\(author)\n\(website)"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 4
        let credits = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        credits.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .medium),
                             range: (text as NSString).range(of: author))
        credits.addAttributes([
            .link: URL(string: "https://byalpaca.dev")!,
            .foregroundColor: NSColor.linkColor
        ], range: (text as NSString).range(of: website))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminating = false
    private var lyricsOverlayController: MenuBarLyricsOverlayController?
    /// Connects the model; the first time it also starts the lyrics shown
    /// below the menu bar. Playback controls live in the menu bar panel.
    func attach(_ model: AppModel) {
        self.model = model
        guard lyricsOverlayController == nil else { return }
        let overlay = MenuBarLyricsOverlayController(model: model)
        lyricsOverlayController = overlay
        overlay.start()
    }
    /// While any menu bar item is shown, closing the last window keeps the
    /// app (and playback) running there; otherwise closing it quits as before.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        model?.hasMenuBarPresence != true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        model.player.pause()
        lyricsOverlayController?.stop()
        model.stopLyricsSync()
        Task {
            await model.library.flushPersistence()
            await model.lyrics.shutdown()
            model.player.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
