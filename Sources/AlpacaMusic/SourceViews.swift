import SwiftUI

private struct PlatformSheet: Identifiable { var source: MusicSource; var id = UUID() }

struct SourcesView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @State private var editing: SourceConfiguration?
    @State private var testing: String?
    @State private var results: [String: String] = [:]
    @State private var login: PlatformSheet?
    @State private var playlists: PlatformSheet?
    @State private var sodaShare = false
    @State private var advanced = false
    private var enabledCount: Int { 1 + DirectMusicAccess.visibleSources.filter { source in model.accounts.state(source).profile != nil || model.library.sources.contains { $0.kind == source && $0.enabled && !$0.endpoint.isEmpty } }.count + (model.appleMusic.isEnabled ? 1 : 0) + (model.spotify.isEnabled ? 1 : 0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack {
                Text("音源").font(.system(size: 29, weight: .regular)).foregroundStyle(palette.text)
                Spacer(); Text("\(enabledCount) 个已启用音源").font(.system(size: 10)).foregroundStyle(palette.accent.opacity(0.75)).padding(.horizontal, 13).padding(.vertical, 9).overlay(Capsule().strokeBorder(palette.accent.opacity(0.17)))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 18, alignment: .topLeading)], alignment: .leading, spacing: 18) {
                sourceCard(source: .local, status: "随时可用", detail: "\(model.library.tracks.filter { $0.source == .local }.count) 首已导入") {
                    Button { model.beginImport(folder: false) } label: { Label("导入音乐", systemImage: "folder.badge.plus").frame(maxWidth: .infinity) }.buttonStyle(QuietButtonStyle())
                }
                sourceCard(source: .appleMusic, status: model.appleMusic.authorizationDescription, detail: model.appleMusic.subscriptionDescription) {
                    AppleMusicConnectionControls(model: model)
                }
                sourceCard(source: .spotify, status: model.spotify.isBusy ? "正在连接…" : model.spotify.isEnabled ? "已连接" : model.spotify.isConfigured ? "尚未登录" : "待配置", detail: model.spotify.profile?.displayName ?? "官方授权 · 歌单导入 · 设备播放") {
                    SpotifyConnectionControls(model: model)
                }
                ForEach(DirectMusicAccess.visibleSources, id: \.self) { source in
                    let state = model.accounts.state(source)
                    sourceCard(source: source, status: state.busy ? "正在连接…" : state.profile == nil ? "尚未登录" : "已连接", detail: state.profile?.displayName ?? (source == .soda ? "汽水 App 扫码 · 分享链接导入" : source == .qq ? "QQ / 微信扫码登录" : "网易云音乐 App 扫码登录")) {
                        VStack(alignment: .leading, spacing: 10) {
                            if state.profile != nil {
                                HStack(spacing: 10) {
                                    Button { playlists = PlatformSheet(source: source) } label: { Label("导入歌单", systemImage: "music.note.list").frame(maxWidth: .infinity) }.buttonStyle(QuietButtonStyle())
                                    Button("退出") { Task { await model.disconnectAccount(source) } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(palette.secondary).disabled(state.busy)
                                }
                                Button("重新登录或切换账号") { login = PlatformSheet(source: source) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(palette.accent).disabled(state.busy)
                            } else {
                                Button { login = PlatformSheet(source: source) } label: { Label("登录\(source.title)", systemImage: "person.crop.circle").frame(maxWidth: .infinity) }.buttonStyle(QuietButtonStyle()).disabled(state.busy)
                            }
                            if source == .soda {
                                Button { sodaShare = true } label: {
                                    Label("导入分享链接", systemImage: "link").frame(maxWidth: .infinity)
                                }.buttonStyle(QuietButtonStyle()).accessibilityIdentifier("soda-share-open")
                                Text("当前播放使用官方分享音频，可能仅提供试听。")
                                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if state.profile == nil {
                                    Toggle("参与公开曲库搜索", isOn: $model.sodaPublicSearch)
                                        .toggleStyle(.checkbox).font(.system(size: 10)).tint(palette.accent)
                                }
                            }
                            if let error = state.error { Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
            }
            HStack(spacing: 20) {
                Image(systemName: "link").font(.system(size: 26, weight: .light)).foregroundStyle(palette.accent).frame(width: 50, height: 50).background(palette.accent.opacity(0.07), in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 8) { Text("音频链接").font(.system(size: 15, weight: .medium)).foregroundStyle(palette.text); Text("音频直链 · 网络电台 · HLS").font(.system(size: 10)).foregroundStyle(palette.secondary) }
                Spacer()
                Button { model.sheet = .url } label: { Label("添加链接", systemImage: "plus") }.buttonStyle(QuietButtonStyle())
            }.padding(22).background(palette.panel, in: .rect(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.line))
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "cloud").font(.system(size: 19)).foregroundStyle(palette.faint)
                VStack(alignment: .leading, spacing: 9) { Text("登录与隐私").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondary); Text("登录凭证保存在本机钥匙串。导入仅保存歌单与歌曲资料；播放受订阅、购买和地区权限限制。平台接口变化后可能需要重新登录。").font(.system(size: 10)).foregroundStyle(palette.faint).lineSpacing(6) }
            }.padding(.top, 3)
            DisclosureGroup("高级：自定义服务", isExpanded: $advanced) {
                VStack(spacing: 12) {
                    Text("已登录的平台优先使用账号连接，登录凭证不会发送给自定义服务。").font(.system(size: 10)).foregroundStyle(palette.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(model.library.sources) { config in
                        HStack {
                            Text(config.name).font(.system(size: 12)); Spacer()
                            if let result = results[config.id] { Text(result).font(.system(size: 10)).foregroundStyle(palette.secondary) }
                            if !config.endpoint.isEmpty {
                                Button("测试连接") { Task { testing = config.id; let result = await model.sourceService.test(config); results[config.id] = result.message; testing = nil } }.disabled(testing != nil)
                            }
                            Button(config.endpoint.isEmpty ? "配置" : "编辑配置") { editing = config }
                        }.buttonStyle(QuietButtonStyle())
                    }
                }.padding(.top, 16)
            }.font(.system(size: 11)).foregroundStyle(palette.secondary)
        }
        .sheet(item: $editing) { config in SourceEditor(model: model, initial: config).modifier(PanelEntrance(appReduced: model.visual.reduceMotion)) }
        .sheet(item: $login) { item in
            Group {
                if item.source == .soda {
                    SodaLoginView(onConnect: { try await connect(item, cookies: $0) },
                                  onCancel: { Task { await model.accounts.cancelConnection(item.source, attemptID: item.id) } },
                                  onComplete: { Task { await model.accounts.completeConnection(item.source, attemptID: item.id) } })
                } else {
                    QRLoginView(source: item.source, onConnect: { try await connect(item, cookies: $0) },
                                    onCancel: { Task { await model.accounts.cancelConnection(item.source, attemptID: item.id) } },
                                    onComplete: { Task { await model.accounts.completeConnection(item.source, attemptID: item.id) } })
                }
            }.modifier(PanelEntrance(appReduced: model.visual.reduceMotion))
        }
        .sheet(item: $playlists) { item in RemotePlaylistsView(model: model, source: item.source).modifier(PanelEntrance(appReduced: model.visual.reduceMotion)) }
        .sheet(isPresented: $sodaShare) { SodaShareImportView(model: model).modifier(PanelEntrance(appReduced: model.visual.reduceMotion)) }
    }
    private func connect(_ item: PlatformSheet, cookies: [MusicSessionCookie]) async throws {
        let previous = model.accounts.state(item.source).profile?.id
        try await model.accounts.connect(item.source, cookies: cookies, attemptID: item.id)
        if previous != model.accounts.state(item.source).profile?.id, model.player.current?.source == item.source { model.player.pause() }
        model.notify("已连接\(item.source.title)，可以搜索歌曲或导入歌单")
    }
    private func sourceCard<Actions: View>(source: MusicSource, status: String, detail: String, @ContentBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Image(systemName: source.symbol).font(.system(size: 26, weight: .light)).foregroundStyle(source == .netease ? palette.primary : palette.accent).frame(width: 47, height: 47).background(palette.accent.opacity(0.04), in: .rect(cornerRadius: 12)); Spacer(); HStack(spacing: 5) { Circle().fill(palette.secondary).frame(width: 4, height: 4); Text(status).font(.system(size: 9)) }.foregroundStyle(palette.secondary) }
            Text(source.title).font(.system(size: 19, weight: .regular)).foregroundStyle(palette.text).padding(.top, 24)
            Text(detail).font(.system(size: 9)).foregroundStyle(palette.faint).lineLimit(2).padding(.top, 14).padding(.bottom, 20)
            actions()
        }.padding(23).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 242, alignment: .top).background(LinearGradient(colors: [palette.raised.opacity(0.55), palette.panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(palette.line))
    }
}

struct AppleMusicConnectionControls: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @State private var showsLibrary = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.appleMusic.isEnabled {
                Button { showsLibrary = true } label: {
                    Label("导入曲库", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }.buttonStyle(QuietButtonStyle()).disabled(model.appleMusic.isBusy)
                    .accessibilityIdentifier("apple-music-import-library")
                HStack {
                    Button("检查状态") { Task { await model.appleMusic.refresh() } }.buttonStyle(QuietButtonStyle()).disabled(model.appleMusic.isBusy)
                    Button("停用") { model.disconnectAppleMusic() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
            } else {
                Button { Task { await model.appleMusic.connect() } } label: {
                    HStack(spacing: 8) { if model.appleMusic.isBusy { ProgressView().controlSize(.mini) }; Text("连接 Apple Music").frame(maxWidth: .infinity) }
                }.buttonStyle(QuietButtonStyle()).disabled(!model.appleMusic.isConfigured || model.appleMusic.isBusy).opacity(model.appleMusic.isConfigured ? 1 : 0.45)
            }
            Button(model.appleMusic.isConfigured ? "关于 Apple Music 播放" : "完成开发者配置") { model.sheet = .appleMusicSetup }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(palette.accent)
            if let error = model.appleMusic.error { Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .sheet(isPresented: $showsLibrary) { AppleMusicLibraryImportView(model: model).modifier(PanelEntrance(appReduced: model.visual.reduceMotion)) }
    }
}

struct SourceEditor: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var initial: SourceConfiguration
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var enabled = true
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            SheetHeading(title: "连接\(initial.name)", subtitle: "填写你自己部署或信任的兼容 API 地址。") { dismiss() }
            VStack(alignment: .leading, spacing: 10) { Text("服务地址").font(.system(size: 11)).foregroundStyle(palette.secondary); TextField(initial.kind == .netease ? "http://127.0.0.1:3000" : "http://127.0.0.1:3300", text: $address).textFieldStyle(.roundedBorder).font(.system(size: 12)).accessibilityLabel("音源服务地址") }
            Toggle("启用此音源", isOn: $enabled).toggleStyle(.checkbox).font(.system(size: 11)).tint(palette.accent)
            Text(initial.kind == .netease ? "兼容 NeteaseCloudMusicApi 的 /cloudsearch 与 /song/url 接口。账号登录由你自己的服务管理。" : "兼容 jsososo/QQMusicApi 的 /search 与 /song/urls 接口。账号登录由你自己的服务管理。").font(.system(size: 10)).foregroundStyle(palette.secondary).lineSpacing(6)
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                if !initial.endpoint.isEmpty { Button("移除配置", role: .destructive) { do { try model.saveSource(.init(kind: initial.kind)); dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(.plain).font(.system(size: 10)) }
                Spacer(); Button("保存配置") { do { try model.saveSource(.init(kind: initial.kind, endpoint: address.trimmingCharacters(in: .whitespacesAndNewlines), enabled: enabled)); model.notify("音源配置已保存"); dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }.padding(29).frame(width: 460).background(palette.panel).foregroundStyle(palette.text).onAppear { address = initial.endpoint; enabled = initial.enabled || initial.endpoint.isEmpty }
    }
}
