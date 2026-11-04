import AppKit
import SwiftUI

@main
struct AlpacaMusicApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("AlpacaMusic", id: "main") {
            ContentView(model: model)
                .environment(\.locale, model.language.locale)
                .frame(minWidth: 1040, minHeight: 720)
                .appTheme(model.immersive ? .listeningRoom : .bauhaus)
                .preferredColorScheme(model.immersive ? .dark : .light)
                .task { delegate.model = model; await model.load() }
        }
        .defaultSize(width: 1440, height: 940)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.string("关于 AlpacaMusic")) { AboutPanel.show() }
            }
            CommandGroup(after: .newItem) {
                Button(L10n.string("导入音乐文件…"), systemImage: "plus") { model.beginImport(folder: false) }
                    .keyboardShortcut("o", modifiers: .command)
                Button(L10n.string("导入音乐文件夹…"), systemImage: "folder.badge.plus") { model.beginImport(folder: true) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button(L10n.string("添加音频链接…"), systemImage: "link") { model.sheet = .url }
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
                Button(L10n.string("歌词")) { model.revealLyrics() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button(L10n.string("沉浸模式")) { withAnimation(.smooth(duration: 0.25)) { model.immersive.toggle() } }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button(L10n.string("播放队列")) { withAnimation(.smooth(duration: 0.22)) { model.queueOpen.toggle() } }
                    .keyboardShortcut("q", modifiers: [.command, .shift])
            }
        }
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
        let author = "Junpei Tang · byalpaca"
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        model.player.pause()
        Task {
            await model.library.flushPersistence()
            await model.lyrics.shutdown()
            model.player.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
