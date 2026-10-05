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
        } detail: {
            VStack(spacing: 0) {
                AppHeader(model: model)
                HStack(spacing: 0) {
                    ZStack {
                        ScrollView {
                            Group {
                                switch model.destination {
                                case .home: HomeView(model: model)
                                case .sources: SourcesView(model: model)
                                default: LibraryView(model: model)
                                }
                            }.padding(.horizontal, 34).padding(.top, 30).padding(.bottom, 24)
                        }
                        .id(model.destination)
                        .transition(.opacity.combined(with: .offset(y: 7)))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .animation(ExperienceMotion.navigation, value: model.destination)
                    if model.queueOpen && !model.immersive { QueueView(model: model).frame(width: 276).transition(.move(edge: .trailing).combined(with: .opacity)) }
                }
            }.background(palette.background)
                // Only the covered detail content leaves hit testing and the
                // accessibility tree; the overlay is added outside this scope.
                .accessibilityHidden(model.immersive)
                .allowsHitTesting(!model.immersive)
                .overlay { if model.immersive { ImmersiveView(model: model).appTheme(.listeningRoom).transition(.opacity) } }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(palette.accent)
        .background(palette.background)
        PlayerBar(model: model).appTheme(model.immersive ? .listeningRoom : .bauhaus)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let failure = model.player.failure, failure.id != dismissedPlaybackFailureID {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .top, spacing: 12) {
                            Label("\(failure.track.source.title) ·「\(failure.track.title)」", systemImage: "exclamationmark.circle")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                            Spacer(minLength: 8)
                            Button { dismissedPlaybackFailureID = failure.id } label: {
                                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                                    .frame(width: 24, height: 24).contentShape(.rect)
                            }
                            .buttonStyle(.plain).foregroundStyle(palette.secondary)
                            .help("关闭提示").accessibilityLabel("关闭播放失败提示")
                            .accessibilityIdentifier("playback-error-dismiss")
                        }
                        Text("\(failure.track.artist) · \(failure.stage.rawValue)").font(.system(size: 10)).foregroundStyle(palette.secondary)
                        Text(failure.message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled).accessibilityIdentifier("playback-error-message")
                        HStack(spacing: 10) {
                            Button("重试这首") { Task { await model.player.retry() } }.buttonStyle(QuietButtonStyle())
                            Button("下一首") { Task { await model.player.next() } }.buttonStyle(QuietButtonStyle())
                            if QQOfficialPlaybackPolicy.detailURL(for: failure.track) != nil {
                                Button("查看官网播放状态") { model.showOfficialQQPlayback(failure.track) }
                                    .buttonStyle(QuietButtonStyle()).accessibilityIdentifier("qqOfficialPlaybackOpen")
                            }
                            Spacer()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(palette.raised, in: .rect(cornerRadius: 9))
                }
                if let error = model.library.persistenceError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("音乐库保存需要处理", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                        Text(error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled).accessibilityIdentifier("library-storage-error")
                        Button(retryingPersistence ? "正在保存…" : "重试保存") {
                            retryingPersistence = true
                            Task { await model.library.retryPersistence(); retryingPersistence = false }
                        }.buttonStyle(QuietButtonStyle()).disabled(retryingPersistence)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(palette.raised, in: .rect(cornerRadius: 9))
                }
                if let notice = model.notice {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle").foregroundStyle(palette.accent)
                        Text(notice).font(.system(size: 11)).lineLimit(3)
                        Button { model.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain)
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
                VStack(spacing: 18) { Image(systemName: "square.and.arrow.down").font(.system(size: 38, weight: .light)); Text("松开以导入音乐").font(.system(size: 25, weight: .light)) }
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
                    do { try await model.lyrics.importFile(url: url, for: target); model.notify("已为「\(target.title)」保存歌词") }
                    catch { model.notify("歌词未能导入：\(error.localizedDescription)") }
                }
            case .failure(let error): model.notify(error.localizedDescription)
            }
        }
        .task(id: model.player.current.map { LyricsIdentity.key(for: $0) }) { await model.lyrics.load(track: model.player.current) }
        .animation(ExperienceMotion.panel, value: model.queueOpen)
        .animation(ExperienceMotion.panel, value: model.immersive)
        .animation(ExperienceMotion.control, value: model.notice)
        .animation(ExperienceMotion.control, value: model.player.failure?.id)
        .animation(ExperienceMotion.control, value: dismissedPlaybackFailureID)
        .animation(ExperienceMotion.control, value: model.library.persistenceError)
        .onChange(of: model.library.sources) { _, sources in model.player.sourceConfigurations = sources }
        .onChange(of: model.immersive) { _, enabled in
            withAnimation(.smooth(duration: 0.25)) { columns = enabled ? .detailOnly : .all }
        }
        .onExitCommand {
            if model.queueOpen { model.queueOpen = false }
            else if model.immersive { model.immersive = false }
            else { model.navigate(model.destination) }
        }
        .transaction { if reduceMotion || model.visual.reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
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
                nav("此刻", "opticaldisc", .home)
                nav("音乐库", "square.stack.3d.up", .library)
                nav("喜欢的音乐", "heart", .favorites)
                nav("音源", "antenna.radiowaves.left.and.right", .sources)
            }.padding(.horizontal, 15)
            HStack { Text("我的歌单").font(.system(size: 10)).tracking(1).foregroundStyle(palette.faint); Spacer(); ToolButton(symbol: "plus", label: "创建歌单") { model.sheet = .playlist } }.padding(.horizontal, 25).padding(.top, 22)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(model.library.playlists) { playlist in nav(playlist.name, "music.note.list", .playlist(playlist.id)) }
                    if model.library.playlists.isEmpty {
                        Button { model.sheet = .playlist } label: { Label("创建歌单", systemImage: "plus").font(.system(size: 10)).foregroundStyle(palette.secondary).padding(.vertical, 10) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 15)
            }
            Spacer(minLength: 15)
            Button { model.beginImport(folder: false) } label: { Label("导入音乐", systemImage: "plus").frame(maxWidth: .infinity) }
                .buttonStyle(QuietButtonStyle()).padding(.horizontal, 17).padding(.bottom, 20)
        }.background(palette.panel.opacity(0.35))
    }
    private func nav(_ name: String, _ icon: String, _ destination: Destination) -> some View {
        Button { model.navigate(destination) } label: {
            HStack(spacing: 12) { Image(systemName: icon).font(.system(size: 15)).frame(width: 18); Text(name).font(.system(size: 12)).lineLimit(1); Spacer(); if model.destination == destination { Capsule().fill(palette.accent).frame(width: 3, height: 14) } }
                .foregroundStyle(model.destination == destination ? palette.accent : palette.secondary).padding(.leading, 13).padding(.trailing, 5).frame(height: 40)
                .background(model.destination == destination ? palette.accent.opacity(0.065) : .clear, in: .rect(cornerRadius: 7)).contentShape(.rect)
        }.buttonStyle(.plain).accessibilityAddTraits(model.destination == destination ? [.isSelected] : [])
            .animation(ExperienceMotion.control, value: model.destination)
    }
}

struct AppHeader: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool
    var body: some View {
        HStack(spacing: 18) {
            Text(model.pageTitle).foregroundStyle(palette.secondary).lineLimit(1).font(.system(size: 10))
            Spacer(minLength: 10)
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(palette.secondary)
                TextField("搜索歌曲、艺术家或专辑", text: $model.query).textFieldStyle(.plain).font(.system(size: 11)).focused($searchFocused).onSubmit { model.search() }.accessibilityIdentifier("music-search")
                if !model.query.isEmpty { Button { model.navigate(model.destination) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).help("清除搜索") }
                else { Text("⌘ K").font(.system(size: 9)).foregroundStyle(palette.faint) }
            }.padding(.horizontal, 11).frame(width: 270, height: 33).background(palette.panel, in: .rect(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.line))
            Button { searchFocused = true } label: { EmptyView() }.keyboardShortcut("k", modifiers: .command).hidden().frame(width: 0)
            Menu { Button("选择音频文件…") { model.beginImport(folder: false) }; Button("导入文件夹…") { model.beginImport(folder: true) }; Divider(); Button("添加音频链接…") { model.sheet = .url } } label: { Label("导入", systemImage: "plus").font(.system(size: 11)) }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(palette.accent)
        }.padding(.horizontal, 34).frame(height: 57).overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }
}

struct HomeView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HeroView(model: model)
            if model.library.tracks.contains(where: { $0.source == .demo }) {
                VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("原创试听").font(.system(size: 16, weight: .medium))
                    Spacer(); Button { model.navigate(.library) } label: { HStack(spacing: 5) { Text("全部音乐"); Image(systemName: "chevron.right") }.font(.system(size: 10)).foregroundStyle(palette.secondary) }.buttonStyle(.plain)
                }
                HStack(spacing: 20) {
                    ForEach(Array(model.library.tracks.filter { $0.source == .demo }.prefix(3).enumerated()), id: \.element.id) { index, track in SessionCard(track: track, index: index, model: model) }
                }
                }
            } else if !model.library.ready {
                ProgressView("正在加载音乐…").controlSize(.small).frame(maxWidth: .infinity).padding(30)
            } else if model.library.tracks.isEmpty {
                EmptyState(symbol: "music.note", title: "音乐库为空") { model.beginImport(folder: false) }
            }
            if model.library.tracks.contains(where: { $0.source != .demo }) {
                VStack(alignment: .leading, spacing: 12) { Text("最近添加").font(.system(size: 15, weight: .medium)); TrackList(model: model, tracks: Array(model.library.tracks.filter { $0.source != .demo }.suffix(3).reversed()), compact: true) }
            }
        }.foregroundStyle(palette.text)
    }
}

struct HeroView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.player.current == nil ? "播放预览" : "当前歌曲").font(.system(size: 11)).foregroundStyle(palette.secondary)
                    Text(model.activeTrack?.title ?? "未选择歌曲")
                        .font(.system(size: geometry.size.width < 780 ? 32 : 38, weight: .light))
                        .lineLimit(3).foregroundStyle(palette.text).padding(.top, 19)
                    if let track = model.activeTrack {
                        Text(track.artist).font(.system(size: 12)).foregroundStyle(palette.secondary).lineLimit(1).padding(.top, 12)
                    }
                    HStack(spacing: 20) {
                        Button { if let track = model.activeTrack { model.play(track, context: model.library.tracks) } } label: { Label("播放", systemImage: "play.fill") }.buttonStyle(PrimaryButtonStyle()).disabled(model.activeTrack == nil).accessibilityIdentifier("start-listening")
                        Button { withAnimation(.smooth(duration: 0.25)) { model.immersive = true } } label: { Label("沉浸模式", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(palette.secondary)
                    }.padding(.top, 24)
                    Spacer(minLength: 12)
                    Label(model.visualMode.title, systemImage: model.visualMode.symbol).font(.system(size: 10)).foregroundStyle(palette.secondary)
                }.padding(.leading, 33).padding(.vertical, 29).frame(width: geometry.size.width * 0.47, alignment: .leading)
                HeroVisualStage(model: model).appTheme(.listeningRoom)
            }
        }.frame(height: 354).background(palette.panel)
            .clipShape(.rect(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(palette.line))
    }
}

/// The home preview has its own dark surface; its controls inherit the room
/// palette while the current-track summary remains part of the light library.
private struct HeroVisualStage: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var body: some View {
        ZStack(alignment: .bottom) {
            if !model.immersive { ListeningScene(model: model) }
            if model.visualMode == .pointCloud {
                Text("拖动旋转 · 双击复位").font(.system(size: 9)).foregroundStyle(palette.secondary)
                    .padding(.bottom, 21).allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        .overlay(alignment: .topTrailing) {
            ToolButton(symbol: "slider.horizontal.3", label: "调整视觉效果") { model.sheet = .visual }.padding(15)
        }
    }
}

struct SessionCard: View {
    @Environment(\.appPalette) private var palette
    var track: Track
    var index: Int
    @Bindable var model: AppModel
    @State private var hovered = false
    var body: some View {
        Button { model.play(track, context: model.library.tracks.filter { $0.source == .demo }) } label: {
            VStack(alignment: .leading, spacing: 12) {
                GeometryReader { geometry in
                    ArtworkView(track: track, highResolution: true).frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .overlay(alignment: .topLeading) { Text("0\(index + 1)").font(.system(size: 8, design: .monospaced)).tracking(1.5).foregroundStyle(.white.opacity(0.7)).padding(13) }
                        .overlay(alignment: .bottomTrailing) { Image(systemName: model.player.current?.id == track.id && model.player.status == .playing ? "waveform" : "play.fill").font(.system(size: 14)).frame(width: 33, height: 33).foregroundStyle(palette.onPrimary).background(palette.primary, in: .circle).padding(12).opacity(hovered || model.player.current?.id == track.id ? 1 : 0) }
                }.frame(height: model.queueOpen ? 115 : 147).clipShape(.rect(cornerRadius: 8))
                HStack {
                    Text(track.title).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
                    Spacer(minLength: 5); Text(formattedTime(track.duration)).font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.faint)
                }
            }.frame(maxWidth: .infinity).contentShape(.rect)
        }.buttonStyle(.plain).onHover { hovered = $0 }.animation(.smooth(duration: 0.2), value: hovered).accessibilityLabel("播放 \(track.title)")
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
                // never reveal search results or library text underneath.
                palette.background
                RadialGradient(colors: [palette.raised.opacity(0.65), palette.background], center: .center, startRadius: 40, endRadius: 800)
                if !model.lyricsVisible {
                    ListeningScene(model: model).padding(.vertical, 56)
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
                    ListeningScene(model: model).modifier(KineticBackdrop(mode: model.visualMode))
                    ImmersiveLyricsPanel(model: model).padding(.horizontal, geometry.size.width < 700 ? 24 : 42).padding(.top, 82).padding(.bottom, 105)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
                ImmersiveChrome(model: model, availableWidth: geometry.size.width)
            }
            .accessibilityHidden(model.queueOpen)
            .overlay { ImmersiveQueueOverlay(model: model, availableSize: geometry.size) }
            .animation(reduced ? nil : ExperienceMotion.panel, value: model.lyricPresentation)
            .animation(reduced ? nil : ExperienceMotion.panel, value: model.lyricsVisible)
        }.accessibilityIdentifier("immersive-listening-room")
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
                .accessibilityLabel("收起播放队列")
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
                Text("在 LRCLIB 匹配当前歌曲 · 仅查询歌名、歌手、专辑和时长")
                    .font(.system(size: 10)).foregroundStyle(palette.faint).multilineTextAlignment(.center)
            }
            if model.player.current != nil && (model.lyrics.status == .unavailable || model.lyrics.status == .failed) {
                VStack(spacing: 7) {
                    Button("在线查找歌词", systemImage: "magnifyingglass") { lookupLyrics() }
                        .buttonStyle(QuietButtonStyle()).accessibilityIdentifier("lyrics-online-lookup")
                    Text("将歌曲名、歌手、专辑和时长发送至 LRCLIB 查找。")
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
    private var sourceStatus: String {
        let source = model.activeTrack?.sourcePlaybackTitle ?? "未选择音源"
        if reduced { return source + " · 减少动态效果开启" }
        if model.player.status != .playing { return source + " · 已暂停" }
        if model.activeTrack?.source.supportsAudioAnalysis == false {
            return source + (model.visualMode.isSignalDisplay ? " · 尚无实时音频采样" : " · 氛围动画")
        }
        return source
    }
    var body: some View {
        VStack {
            HStack(spacing: availableWidth < 720 ? 10 : 14) {
                Spacer(minLength: 12)
                Picker("字幕效果", selection: $model.lyricPresentation) {
                    Text("滚动歌词").tag(LyricPresentationMode.scroll)
                    Text("动态字幕").tag(LyricPresentationMode.kinetic)
                }.pickerStyle(.segmented).labelsHidden()
                    .frame(width: availableWidth < 520 ? 164 : 178).disabled(!model.lyricsVisible)
                    .accessibilityLabel("字幕效果").accessibilityIdentifier("lyric-presentation-picker")
                ToolButton(symbol: "quote.bubble", label: model.lyricsVisible ? "隐藏歌词" : "显示歌词", active: model.lyricsVisible) { model.lyricsVisible.toggle() }
                Menu {
                    Picker("视觉效果", selection: $model.visualMode) {
                        ForEach(VisualizationMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                    }.pickerStyle(.inline)
                    Divider()
                    Button("调整视觉效果…") { model.sheet = .visual }
                    Button("导入本地歌词…") { model.beginLyricsImport() }
                    Button("在 LRCLIB 查找歌词") { lookupLyrics() }.disabled(model.player.current == nil)
                    Toggle("自动匹配 Apple Music 歌词（LRCLIB）", isOn: $model.automaticAppleMusicLyrics)
                } label: {
                    if availableWidth >= 540 {
                        Label(model.visualMode.title, systemImage: model.visualMode.symbol).font(.system(size: 11)).lineLimit(1)
                    } else {
                        Image(systemName: model.visualMode.symbol).font(.system(size: 13))
                    }
                }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(palette.accent)
                    .accessibilityIdentifier("immersive-visual-effects-menu")
                    .accessibilityLabel("选择视觉效果，当前为" + model.visualMode.title).help("视觉效果：" + model.visualMode.title)
                ToolButton(symbol: "arrow.down.right.and.arrow.up.left", label: "退出沉浸模式") { model.immersive = false }
            }
            Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: sourceStatus).lineLimit(1).accessibilityLabel(sourceStatus)
                    Text(model.activeTrack?.title ?? "未选择歌曲").font(.system(size: 24, weight: .light)).tracking(1).foregroundStyle(palette.text).lineLimit(1)
                    if let track = model.activeTrack {
                        Text(track.artist).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 20)
                Text(model.lyricsVisible && model.lyrics.document?.timing != .plain && model.lyrics.document != nil ? "点击歌词跳转 · Esc 退出" : "Esc 退出沉浸").font(.system(size: 9)).foregroundStyle(palette.faint)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
        }.padding(28)
    }
    private func lookupLyrics() {
        guard let track = model.player.current else { return }
        Task { await model.lyrics.lookupOnline(for: track) }
    }
}

/// Keep the selected scene visible around the type. A local contrast scrim
/// protects white lyrics without flattening the entire animation to black.
struct KineticBackdrop: ViewModifier {
    let mode: VisualizationMode
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .opacity(mode == .pointCloud ? 0.28 : mode == .artwork ? 0.30 : 0.72)
                .overlay {
                    RadialGradient(colors: [.black.opacity(0.38), .black.opacity(0.10), .clear],
                                   center: .center, startRadius: 0,
                                   endRadius: max(1, min(geometry.size.width, geometry.size.height) * 0.72))
                        .allowsHitTesting(false)
                }
        }
    }
}

struct ListeningScene: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        ZStack {
            MusicVisualizationView(track: model.activeTrack, mode: model.visualMode, settings: model.visual,
                                   isPlaying: model.player.status == .playing, signal: { model.player.readLevels() }, showsStatus: false)
                .id(model.visualMode).transition(.opacity)
            if model.activeTrack?.source.supportsAudioAnalysis == false, model.visualMode.isSignalDisplay,
               !model.immersive || !model.lyricsVisible || model.lyricPresentation == .scroll {
                VStack(spacing: 10) {
                    Text("\(model.activeTrack?.source.title ?? "当前音源") 暂无实时波形与频谱")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text)
                    Text("当前播放通道无法获取音频采样。")
                        .font(.system(size: 10)).foregroundStyle(palette.secondary)
                        .multilineTextAlignment(.center)
                    Button("使用流光绸缎") { model.visualMode = .ribbons }
                        .buttonStyle(QuietButtonStyle()).accessibilityIdentifier("apple-waveform-ambience")
                }.padding(18).frame(maxWidth: 310)
                    .background(palette.background.opacity(0.92), in: .rect(cornerRadius: 12))
                    .padding(18)
            }
        }.animation(reduced || model.visual.reduceMotion ? nil : ExperienceMotion.visualization, value: model.visualMode)
    }
}
