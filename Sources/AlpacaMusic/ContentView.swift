import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargeted = false
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var retryingPersistence = false
    @State private var dismissedPlaybackFailureID: UUID?
    var body: some View {
        VStack(spacing: 0) {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(model: model).navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 245)
                // The room hides the sidebar; its toggle would float alone in the top strip.
                .toolbar(removing: model.immersive ? .sidebarToggle : nil)
        } detail: {
            ZStack {
                if model.destination == .home {
                    // The Now page has no header: its stage runs up under the
                    // window's top strip and carries Search and Import, and
                    // the queue opens in the page's own side panel.
                    NowPageView(model: model)
                        .transition(.opacity.combined(with: .offset(y: 7)))
                } else {
                    VStack(spacing: 0) {
                        AppHeader(model: model)
                        HStack(spacing: 0) {
                            ZStack {
                                // The results stay alive, hidden, under a page opened from them,
                                // so Back finds them scrolled exactly where they were.
                                if model.searchResults.active && (model.destination == .search || model.trail.contains(.search)) {
                                    let shown = model.destination == .search
                                    SearchPageView(model: model)
                                        .opacity(shown ? 1 : 0)
                                        .allowsHitTesting(shown)
                                        .accessibilityHidden(!shown)
                                        .transition(.opacity.combined(with: .offset(y: 7)))
                                }
                                if model.destination != .search {
                                    ScrollView {
                                        Group {
                                            switch model.destination {
                                            case .sources: SourcesView(model: model)
                                            case .albums: AlbumsView(model: model)
                                            case .album: AlbumDetailView(model: model)
                                            default: LibraryView(model: model)
                                            }
                                        }.padding(.horizontal, 34).padding(.top, 30).padding(.bottom, 24)
                                    }
                                    .id(model.destination)
                                    .transition(.opacity.combined(with: .offset(y: 7)))
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                            .animation(ExperienceMotion.navigation, value: model.destination)
                            if model.queueOpen && !model.immersive { QueueView(model: model).frame(width: 276).transition(.move(edge: .trailing).combined(with: .opacity)) }
                        }
                    }
                    .transition(.opacity.combined(with: .offset(y: 7)))
                }
            }
            .animation(ExperienceMotion.navigation, value: model.destination == .home)
            .background(palette.background)
                // Only the covered detail content leaves hit testing and the
                // accessibility tree; the overlay is added outside this scope.
                .accessibilityHidden(model.immersive)
                .allowsHitTesting(!model.immersive)
                .overlay { if model.immersive { ImmersiveView(model: model).appTheme(.listeningRoom).transition(.opacity) } }
                // In the room the strip above the content shows the room itself,
                // and on the Now page it shows the stage.
                .toolbarBackgroundVisibility(model.immersive || model.destination == .home ? .hidden : .automatic, for: .windowToolbar)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(palette.accent)
        .background(palette.background)
        // Outside the room the player bar sits below the content; in the room
        // the content fills the window and the bar floats over its edge.
        .padding(.bottom, model.immersive ? 0 : PlayerBar.height)
        }
        .background(palette.background)
        // One bar in both modes, so its hover state carries into the room. In
        // the room it fades while the listener is idle; the room keeps its
        // content clear of the bar either way, so nothing moves when it fades.
        .overlay(alignment: .bottom) {
            let shown = !model.immersive || model.immersiveChrome.isVisible
            PlayerBar(model: model).appTheme(model.immersive ? .listeningRoom : .bauhaus)
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .onHover { model.immersiveChrome.hold(.pointerOnPlayerBar, $0) }
        }
        .onContinuousHover { phase in
            if model.immersive, case .active = phase { model.immersiveChrome.poke() }
        }
        .animation(reduceMotion || model.visual.reduceMotion ? nil : .easeInOut(duration: 0.4), value: model.immersiveChrome.isVisible)
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let failure = model.player.failure, failure.id != dismissedPlaybackFailureID {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .top, spacing: 12) {
                            Label(L10n.string("\(failure.track.source.title) ·「\(failure.track.title)」"), systemImage: "exclamationmark.circle")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                            Spacer(minLength: 8)
                            Button { dismissedPlaybackFailureID = failure.id } label: {
                                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                                    .frame(width: 24, height: 24).contentShape(.rect)
                            }
                            .buttonStyle(.plain).foregroundStyle(palette.secondary)
                            .help(L10n.string("关闭提示")).accessibilityLabel(L10n.string("关闭播放失败提示"))
                            .accessibilityIdentifier("playback-error-dismiss")
                        }
                        Text("\(failure.track.artist) · \(failure.stage.title)").font(.system(size: 10)).foregroundStyle(palette.secondary)
                        Text(failure.message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled).accessibilityIdentifier("playback-error-message")
                        HStack(spacing: 10) {
                            Button(L10n.string("重试这首")) { Task { await model.player.retry() } }.buttonStyle(QuietButtonStyle())
                            Button(L10n.string("下一首")) { Task { await model.player.next() } }.buttonStyle(QuietButtonStyle())
                            if QQOfficialPlaybackPolicy.detailURL(for: failure.track) != nil {
                                Button(L10n.string("查看官网播放状态")) { model.showOfficialQQPlayback(failure.track) }
                                    .buttonStyle(QuietButtonStyle()).accessibilityIdentifier("qqOfficialPlaybackOpen")
                            }
                            Spacer()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(palette.raised, in: .rect(cornerRadius: 9))
                }
                if let error = model.library.persistenceError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.string("音乐库保存需要处理"), systemImage: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                        Text(error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled).accessibilityIdentifier("library-storage-error")
                        Button(retryingPersistence ? L10n.string("正在保存…") : L10n.string("重试保存")) {
                            retryingPersistence = true
                            Task { await model.library.retryPersistence(); retryingPersistence = false }
                        }.buttonStyle(QuietButtonStyle()).disabled(retryingPersistence)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(palette.raised, in: .rect(cornerRadius: 9))
                }
                // `busy` toggles together with `localImport`; only the card reads
                // the per-file progress so ticks do not re-render the app shell.
                if model.library.busy {
                    LocalImportProgressCard(library: model.library)
                        .environment(\.appReducedMotion, model.visual.reduceMotion)
                        .transition(AnyTransition.opacity.combined(with: .offset(y: 6)))
                }
                // `isActive` flips only when a run starts or ends; only the card
                // reads the live status, so progress ticks stay inside it.
                if model.autoImport.isActive {
                    AutoImportProgressCard(coordinator: model.autoImport)
                        .environment(\.appReducedMotion, model.visual.reduceMotion)
                        .transition(AnyTransition.opacity.combined(with: .offset(y: 6)))
                }
                if let notice = model.notice {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle").foregroundStyle(palette.accent)
                        Text(notice).font(.system(size: 11)).lineLimit(3).help(notice)
                        Button { model.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain)
                            .help(L10n.string("关闭提示")).accessibilityLabel(L10n.string("关闭提示"))
                    }.padding(14).background(palette.raised, in: .rect(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(palette.accent.opacity(0.14)))
                }
            }.foregroundStyle(palette.text).padding(.horizontal, 40).padding(.bottom, 112).frame(maxWidth: 800)
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: model.importFolder ? [.folder] : [.audio], allowsMultipleSelection: true) { result in
            switch result { case .success(let urls): Task { await model.importURLs(urls) }; case .failure(let error): model.notify(error.localizedDescription) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL); guard !files.isEmpty else { return false }
            Task { await model.importURLs(files) }; return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                VStack(spacing: 18) { Image(systemName: "square.and.arrow.down").font(.system(size: 38, weight: .light)); Text(L10n.string("松开以导入音乐")).font(.system(size: 25, weight: .light)) }
                    .foregroundStyle(palette.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.background.opacity(0.93)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(palette.accent.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [8, 8])).padding(10)).allowsHitTesting(false)
            }
        }
        .sheet(item: $model.sheet) { sheet in AppSheetView(model: model, sheet: sheet).modifier(PanelEntrance(appReduced: model.visual.reduceMotion)) }
        .fileImporter(isPresented: $model.showLyricsImporter, allowedContentTypes: [.plainText, .text,
            UTType(filenameExtension: "lrc") ?? .plainText, UTType(filenameExtension: "srt") ?? .plainText], allowsMultipleSelection: false) { result in
            guard let target = model.lyricImportTarget else { return }
            model.lyricImportTarget = nil
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    do { try await model.lyrics.importFile(url: url, for: target); model.notify(L10n.string("已为「\(target.title)」保存歌词")) }
                    catch { model.notify(L10n.string("歌词未能导入：\(error.localizedDescription)")) }
                }
            case .failure(let error): model.notify(error.localizedDescription)
            }
        }
        .animation(ExperienceMotion.panel, value: model.queueOpen)
        .animation(ExperienceMotion.panel, value: model.immersive)
        .animation(ExperienceMotion.control, value: model.notice)
        .animation(ExperienceMotion.control, value: model.player.failure?.id)
        .animation(ExperienceMotion.control, value: dismissedPlaybackFailureID)
        .animation(ExperienceMotion.control, value: model.library.persistenceError)
        .animation(reduceMotion || model.visual.reduceMotion ? nil : ExperienceMotion.control, value: model.library.busy)
        .animation(reduceMotion || model.visual.reduceMotion ? nil : ExperienceMotion.control, value: model.autoImport.isActive)
        .onChange(of: model.library.sources) { _, sources in model.player.sourceConfigurations = sources }
        .onChange(of: model.immersive) { _, enabled in
            withAnimation(.smooth(duration: 0.25)) { columns = enabled ? .detailOnly : .all }
        }
        // The room's controls stay while the queue or a sheet is in use.
        .onChange(of: model.queueOpen, initial: true) { _, open in model.immersiveChrome.hold(.queue, open) }
        .onChange(of: model.sheet != nil || model.showLyricsImporter || model.showImporter, initial: true) { _, open in
            model.immersiveChrome.hold(.sheet, open)
        }
        // No hover exit arrives for views of a closed window.
        .onDisappear { model.immersiveChrome.forgetPointerHolds() }
        .onExitCommand {
            if model.queueOpen { model.queueOpen = false }
            else if model.immersive { model.immersive = false }
            else if model.destination == .home, model.browse.opened != nil { model.browse.close() }
            else { model.escape() }
        }
        .transaction { if reduceMotion || model.visual.reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
    }
}

/// Floating progress for local file and folder imports.
private struct LocalImportProgressCard: View {
    @Environment(\.appPalette) private var palette
    var library: MusicLibrary

    var body: some View {
        ImportProgressPanel(title: L10n.string("正在导入本地音乐"), progress: library.localImport ?? ImportProgress(),
                            symbol: "square.and.arrow.down", onCancel: { library.cancelLocalImport() })
            .background(palette.raised, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.accent.opacity(0.14)))
            .frame(maxWidth: 380)
            .accessibilityIdentifier("local-import-progress")
    }
}

/// Floating progress for the background import after an account connects.
private struct AutoImportProgressCard: View {
    @Environment(\.appPalette) private var palette
    var coordinator: AutoImportCoordinator

    var body: some View {
        AutoImportStatusPanel(coordinator: coordinator)
            .background(palette.raised, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.accent.opacity(0.14)))
            .frame(maxWidth: 380)
            .accessibilityIdentifier("auto-import-progress")
    }
}

struct SidebarView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppBrandLogo().frame(width: 38, height: 38)
                Text("\(Text("alpaca").fontWeight(.semibold))\(Text("music").fontWeight(.light))").font(.system(size: 22)).tracking(-1)
            }.padding(.horizontal, 19).padding(.top, 23).padding(.bottom, 30)
            VStack(spacing: 6) {
                nav(L10n.string("此刻"), "opticaldisc", .home)
                nav(L10n.string("音乐库"), "square.stack.3d.up", .library)
                nav(L10n.string("专辑库"), "square.grid.2x2", .albums)
                nav(L10n.string("喜欢的音乐"), "heart", .favorites)
                nav(L10n.string("音源"), "antenna.radiowaves.left.and.right", .sources)
            }.padding(.horizontal, 15)
            HStack { Text(L10n.string("我的歌单")).font(.system(size: 10)).tracking(1).foregroundStyle(palette.faint); Spacer(); ToolButton(symbol: "plus", label: L10n.string("创建歌单")) { model.sheet = .playlist } }.padding(.horizontal, 25).padding(.top, 22)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(model.library.playlists) { playlist in nav(playlist.name, "music.note.list", .playlist(playlist.id)) }
                    if model.library.playlists.isEmpty {
                        Button { model.sheet = .playlist } label: { Label(L10n.string("创建歌单"), systemImage: "plus").font(.system(size: 10)).foregroundStyle(palette.secondary).padding(.vertical, 10) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 15)
            }
            Spacer(minLength: 15)
            Button { model.beginImport(folder: false) } label: { Label(L10n.string("导入音乐"), systemImage: "plus").frame(maxWidth: .infinity) }
                .buttonStyle(QuietButtonStyle()).disabled(model.library.busy).padding(.horizontal, 17).padding(.bottom, 20)
        }.background(palette.panel.opacity(0.35))
    }
    private func nav(_ name: String, _ icon: String, _ destination: Destination) -> some View {
        let selected = model.destination == destination || (destination == .albums && model.selectedAlbum != nil)
        return Button { model.navigate(destination) } label: {
            HStack(spacing: 12) { Image(systemName: icon).font(.system(size: 15)).frame(width: 18); Text(name).font(.system(size: 12)).lineLimit(2).fixedSize(horizontal: false, vertical: true); Spacer(); if selected { Capsule().fill(palette.accent).frame(width: 3, height: 14) } }
                .foregroundStyle(selected ? palette.accent : palette.secondary).padding(.leading, 13).padding(.trailing, 5).frame(minHeight: 40)
                .background(selected ? palette.accent.opacity(0.065) : .clear, in: .rect(cornerRadius: 7)).contentShape(.rect)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier(destination == .albums ? "sidebar-albums" : "sidebar-\(name)")
            .animation(ExperienceMotion.control, value: model.destination)
    }
}

struct AppHeader: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool
    var body: some View {
        HStack(spacing: 18) {
            if model.canGoBack || model.destination == .search {
                HStack(spacing: 10) {
                    Button { model.goBack() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 28).contentShape(.rect)
                    }
                    .buttonStyle(.plain).foregroundStyle(palette.secondary).disabled(!model.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help(L10n.string("返回")).accessibilityLabel(L10n.string("返回")).accessibilityIdentifier("search-back")
                    trail
                }
            } else {
                Text(model.pageTitle).foregroundStyle(palette.secondary).lineLimit(1).font(.system(size: 10))
            }
            Spacer(minLength: 10)
            MusicSearchField(model: model, focused: $searchFocused, fill: palette.panel, line: palette.line, hint: palette.faint)
            Button { searchFocused = true } label: { EmptyView() }.keyboardShortcut("k", modifiers: .command).hidden().frame(width: 0)
            ImportMenu(model: model)
        }.padding(.horizontal, 34).frame(height: 57).overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }
    /// Where the listener is: the search, then the page opened from it.
    @ViewBuilder private var trail: some View {
        let results = L10n.string("搜索「\(model.searchResults.term)」")
        HStack(spacing: 6) {
            if model.destination == .search {
                Text(results).foregroundStyle(palette.secondary)
            } else if model.trail.last == .search {
                Button(results) { model.goBack() }.buttonStyle(.plain).foregroundStyle(palette.accent)
                Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold)).foregroundStyle(palette.faint)
                Text(model.pageTitle).foregroundStyle(palette.secondary)
            } else {
                Text(model.pageTitle).foregroundStyle(palette.secondary)
            }
        }
        .font(.system(size: 10)).lineLimit(1)
    }
}

struct ImmersiveView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    private var reduced: Bool { systemReduced || model.visual.reduceMotion }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // The room owns an opaque surface; its ambient gradient must
                // never reveal search results or library text underneath. Both
                // reach under the window's top strip, so it takes their colour.
                palette.background.ignoresSafeArea()
                RadialGradient(colors: [palette.raised.opacity(0.65), palette.background], center: .center, startRadius: 40, endRadius: 800)
                    .ignoresSafeArea()
                if !model.lyricsVisible {
                    // Keep the light Bauhaus paper clear of the room's light-on-dark chrome.
                    ListeningScene(model: model)
                        .padding(.top, model.shownVisualMode == .bauhaus ? 68 : 56)
                        .padding(.bottom, model.shownVisualMode == .bauhaus ? 116 : 56)
                } else if model.lyricPresentation == .scroll {
                    HStack(spacing: 30) {
                        VStack(spacing: 12) {
                            ListeningScene(model: model).frame(maxHeight: .infinity)
                            Text(model.activeTrack?.album ?? "").font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                        }.frame(width: max(250, geometry.size.width * 0.40))
                        ImmersiveLyricsPanel(model: model).padding(.trailing, 28)
                    }.padding(.top, 82).padding(.bottom, 108)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                } else {
                    // Full bleed, so the top strip and the space under the bar
                    // show the scene too. The point cloud takes drags, so it
                    // stays out of the strip where the window is dragged.
                    ListeningScene(model: model).modifier(KineticBackdrop(mode: model.shownVisualMode))
                        .ignoresSafeArea(edges: model.shownVisualMode == .pointCloud ? .bottom : .all)
                    ImmersiveLyricsPanel(model: model).padding(.horizontal, geometry.size.width < 700 ? 24 : 42).padding(.top, 82).padding(.bottom, 105)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
                ImmersiveChrome(model: model, availableWidth: geometry.size.width)
            }
            .accessibilityHidden(model.queueOpen)
            .overlay { ImmersiveQueueOverlay(model: model, availableSize: geometry.size) }
            .animation(reduced ? nil : ExperienceMotion.panel, value: model.lyricPresentation)
            .animation(reduced ? nil : ExperienceMotion.panel, value: model.lyricsVisible)
        }
        // The player bar floats over the bottom of the room: its height stays
        // reserved for the content, while the backgrounds run under it.
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: PlayerBar.height).allowsHitTesting(false) }
        // Idle hiding runs only while the room is on screen.
        .onAppear { model.immersiveChrome.activate() }
        .onDisappear { model.immersiveChrome.deactivate() }
        .accessibilityIdentifier("immersive-listening-room")
    }
}

/// Float above the room without resizing or replacing its audio-driven scene.
/// The dismissal surface covers only the room; transport controls stay usable.
private struct ImmersiveQueueOverlay: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    let availableSize: CGSize
    var body: some View {
        if model.queueOpen {
            ZStack(alignment: .topTrailing) {
                Button { model.queueOpen = false } label: {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("收起播放队列"))
                QueueView(model: model, floating: true)
                    .frame(width: min(340, max(0, availableSize.width - 32)),
                           height: min(620, max(0, availableSize.height - 112)))
                    .clipShape(.rect(cornerRadius: 16))
                    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(palette.accent.opacity(0.16)) }
                    .shadow(color: .black.opacity(0.35), radius: 22, x: 0, y: 8)
                    .contentShape(.rect(cornerRadius: 16))
                    .padding(.top, 80).padding(.trailing, 16)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("immersive-playback-queue")
        }
    }
}

/// Observe the playback clock only inside the lyrics subtree. Keeping this in
/// a computed property of ImmersiveView also invalidates its native menus.
private struct ImmersiveLyricsPanel: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    private var reduced: Bool { systemReduced || model.visual.reduceMotion }
    var body: some View {
        VStack(spacing: 12) {
            LyricsPresentationView(document: model.lyrics.document, status: model.lyrics.status, error: model.lyrics.error,
                                   mode: model.lyricPresentation, position: model.player.position,
                                   isPlaying: model.player.status == .playing, reduceMotion: reduced,
                                   onSeek: { model.player.seek(to: $0) }, onImport: { model.beginLyricsImport() },
                                   onRetry: { Task { await model.lyrics.load(track: model.player.current) } },
                                   signal: { model.player.readLevels() })
            if model.player.current?.source == .appleMusic && model.lyrics.status == .loading {
                Text(L10n.string("在 LRCLIB 匹配当前歌曲 · 仅查询歌名、歌手、专辑和时长"))
                    .font(.system(size: 10)).foregroundStyle(palette.faint).multilineTextAlignment(.center)
            }
            if model.player.current != nil && (model.lyrics.status == .unavailable || model.lyrics.status == .failed) {
                VStack(spacing: 7) {
                    Button(L10n.string("在线查找歌词"), systemImage: "magnifyingglass") { lookupLyrics() }
                        .buttonStyle(QuietButtonStyle()).accessibilityIdentifier("lyrics-online-lookup")
                    Text(L10n.string("将歌曲名、歌手、专辑和时长发送至 LRCLIB 查找。"))
                        .font(.system(size: 10)).foregroundStyle(palette.faint).multilineTextAlignment(.center)
                }
            }
        }
    }
    private func lookupLyrics() {
        guard let track = model.player.current else { return }
        Task { await model.lyrics.lookupOnline(for: track) }
    }
}

/// Controls have their own observation boundary and do not read playback time.
private struct ImmersiveChrome: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    let availableWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    private var reduced: Bool { systemReduced || model.visual.reduceMotion }
    private var coverWaiting: String { L10n.string("\(model.visualMode.title)需要实时音频，这个音源没有，暂由专辑封面代替。") }
    private var sourceStatus: String {
        let source = model.activeTrack?.sourcePlaybackTitle ?? L10n.string("未选择音源")
        if reduced { return L10n.string("\(source) · 减少动态效果开启") }
        if model.player.status != .playing { return L10n.string("\(source) · 已暂停") }
        // When the cover stands in, the effect button says why; the source line stays plain.
        if model.activeTrack?.source.supportsAudioAnalysis == false, !model.visualMode.isSignalDisplay {
            return L10n.string("\(source) · 氛围动画")
        }
        return source
    }
    var body: some View {
        let shown = model.immersiveChrome.isVisible
        VStack {
            HStack(spacing: 0) {
                Spacer(minLength: 12)
            // The player bar has the lyrics and exit buttons; the room keeps
            // only its own switches, which fade with the bar when idle.
            HStack(spacing: availableWidth < 720 ? 10 : 14) {
                // Off hides the lyrics and keeps the room, which the player
                // bar's lyrics button does not when it opened the room.
                Picker(L10n.string("字幕效果"), selection: lyricChoice) {
                    Text(L10n.string("滚动歌词")).tag(LyricPresentationMode?.some(.scroll))
                    Text(L10n.string("动态字幕")).tag(LyricPresentationMode?.some(.kinetic))
                    Text(L10n.string("关闭歌词")).tag(LyricPresentationMode?.none)
                }.pickerStyle(.segmented).labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(L10n.string("字幕效果")).accessibilityIdentifier("lyric-presentation-picker")
                Menu {
                    VisualizationModePicker(selection: $model.visualMode)
                    Divider()
                    Button(L10n.string("调整视觉效果…")) { model.sheet = .visual }
                    Button(L10n.string("导入本地歌词…")) { model.beginLyricsImport() }
                    Button(L10n.string("在 LRCLIB 查找歌词")) { lookupLyrics() }.disabled(model.player.current == nil)
                    Toggle(L10n.string("自动匹配 Apple Music 歌词（LRCLIB）"), isOn: $model.automaticAppleMusicLyrics)
                    Toggle(L10n.string("Apple Music 使用网易云/QQ 逐字时间"), isOn: $model.appleMusicPlatformWordLyrics)
                        .help(L10n.string("已登录网易云音乐或 QQ 音乐时，按歌名、歌手和时长查找同一录音的逐字歌词；找不到时使用 LRCLIB。"))
                    Toggle(L10n.string("后台音频字幕对齐"), isOn: $model.automaticLyricAudioAlignment)
                        .help(L10n.string("在本机提前分析人声；首次可能下载语言模型。只缓存时间，不保存音频。"))
                    Text(model.lyrics.audioAlignmentStatus.description).font(.caption)
                } label: {
                    if availableWidth >= 540 {
                        // While the cover stands in, the chosen effect is named dimmed with the reason.
                        Label(model.coverStandsIn ? L10n.string("\(model.visualMode.title) · 无实时音频") : model.visualMode.title,
                              systemImage: model.visualMode.symbol).font(.system(size: 11)).lineLimit(1)
                    } else {
                        Image(systemName: model.visualMode.symbol).font(.system(size: 13))
                    }
                }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(model.coverStandsIn ? palette.secondary : palette.accent)
                    .accessibilityIdentifier("immersive-visual-effects-menu")
                    .accessibilityLabel(L10n.string("选择视觉效果，当前为\(model.visualMode.title)"))
                    .accessibilityValue(model.coverStandsIn ? coverWaiting : "")
                    .help(model.coverStandsIn ? coverWaiting : L10n.string("视觉效果：\(model.visualMode.title)"))
            }
            .onHover { model.immersiveChrome.hold(.pointerOnTopControls, $0) }
            }
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: sourceStatus).lineLimit(1).accessibilityLabel(sourceStatus)
                    Text(model.activeTrack?.title ?? L10n.string("未选择歌曲")).font(.system(size: 24, weight: .light)).tracking(1).foregroundStyle(palette.text).lineLimit(1)
                    if let track = model.activeTrack {
                        Text(track.artist).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 20)
                Text(model.lyricsVisible && model.lyrics.document?.timing != .plain && model.lyrics.document != nil ? L10n.string("点击歌词跳转 · Esc 退出") : L10n.string("Esc 退出沉浸")).font(.system(size: 9)).foregroundStyle(palette.faint)
                    .lineLimit(2).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    .opacity(shown ? 1 : 0)
            }
        }.padding(28)
    }
    private func lookupLyrics() {
        guard let track = model.player.current else { return }
        Task { await model.lyrics.lookupOnline(for: track) }
    }
    /// The shown lyric style, or nil when lyrics are off.
    private var lyricChoice: Binding<LyricPresentationMode?> {
        Binding(get: { model.lyricsVisible ? model.lyricPresentation : nil },
                set: { choice in
                    if let choice { model.lyricPresentation = choice; model.lyricsVisible = true } else { model.lyricsVisible = false }
                })
    }
}

/// Keep the selected scene visible around the type. A local contrast scrim
/// protects white lyrics without flattening the entire animation to black.
struct KineticBackdrop: ViewModifier {
    let mode: VisualizationMode
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .opacity(mode == .pointCloud ? 0.28 : mode == .artwork || mode == .bauhaus ? 0.30 : 0.72)
                .overlay {
                    RadialGradient(colors: [.black.opacity(0.38), .black.opacity(0.10), .clear],
                                   center: .center, startRadius: 0,
                                   endRadius: max(1, min(geometry.size.width, geometry.size.height) * 0.72))
                        .allowsHitTesting(false)
                }
        }
    }
}

/// The room's scene: the chosen effect, or the cover standing in for a
/// "Needs live audio" effect while the song's source gives no live audio.
struct ListeningScene: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        let mode = model.shownVisualMode
        ZStack {
            MusicVisualizationView(track: model.activeTrack, mode: mode, settings: model.visual,
                                   isPlaying: model.player.status == .playing, signal: { model.player.readLevels() }, showsStatus: false,
                                   // Each effect shows its own waiting state; a label here would land on the song's title.
                                   showsMissingAudioStatus: false)
                .id(mode).transition(.opacity)
        }.animation(reduced || model.visual.reduceMotion ? nil : ExperienceMotion.visualization, value: mode)
    }
}
