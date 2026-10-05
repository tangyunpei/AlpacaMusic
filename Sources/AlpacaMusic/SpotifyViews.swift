import SwiftUI

struct SpotifyConnectionControls: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @State private var showsSetup = false
    @State private var showsLibrary = false
    @State private var showsDevices = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.spotify.isEnabled {
                Button { showsLibrary = true } label: {
                    Label("导入歌单", systemImage: "music.note.list").frame(maxWidth: .infinity)
                }.buttonStyle(QuietButtonStyle()).accessibilityIdentifier("spotify-import-library")
                HStack {
                    Button("播放设备") { showsDevices = true }.buttonStyle(QuietButtonStyle())
                    Spacer()
                    Button("断开") {
                        Task {
                            await model.player.pauseAndWaitForSpotify()
                            await model.spotify.disconnect()
                            model.remoteResults.removeAll { $0.source == .spotify }
                        }
                    }.buttonStyle(.plain).font(.system(size: 11))
                }.disabled(model.spotify.isBusy)
            } else if model.spotify.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在连接…").font(.system(size: 11))
                    Spacer()
                    Button("取消") { model.spotify.cancelConnection() }.buttonStyle(QuietButtonStyle())
                }
            } else {
                Button {
                    if model.spotify.isConfigured { model.spotify.connect() } else { showsSetup = true }
                } label: {
                    Label(model.spotify.isConfigured ? "登录 Spotify" : "配置 Spotify", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(QuietButtonStyle()).accessibilityIdentifier("spotify-connect")
            }
            Button("接入设置") { showsSetup = true }.buttonStyle(.plain)
                .font(.system(size: 10)).foregroundStyle(palette.accent)
            if let error = model.spotify.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showsSetup) { SpotifySetupView(service: model.spotify) }
        .sheet(isPresented: $showsLibrary) { SpotifyLibraryImportView(model: model) }
        .sheet(isPresented: $showsDevices) { SpotifyDevicesView(service: model.spotify) }
    }
}

struct SpotifySetupView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var service: SpotifyService
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeading(title: "连接 Spotify", subtitle: "") { dismiss() }
            Text("1. 打开开发者后台，创建应用并选择 Web API。")
            Link("打开 Spotify Developer Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                .foregroundStyle(palette.accent)
            Text("2. 在应用设置的 Redirect URIs 中添加以下地址并保存。")
            HStack {
                Text(SpotifyAuthorization.redirectURI).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SpotifyAuthorization.redirectURI, forType: .string)
                }.buttonStyle(QuietButtonStyle())
            }.padding(12).background(palette.raised, in: .rect(cornerRadius: 8))
            Text("3. 将应用的 Client ID 填在这里，再返回音源页登录。")
            TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("spotify-client-id").disabled(service.isEnabled || service.isBusy)
            Text("不需要 Client Secret。开发模式要求应用所有者有 Premium，最多允许 5 位测试用户；其他账号需加入应用的用户列表。")
                .foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            Text("歌单和喜欢的歌曲导入到本地。播放由 Spotify 官方 App 或网页播放器输出，需要 Premium 和可用播放设备。")
                .foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            if service.isEnabled { Text("更换 Client ID 前，请先断开当前 Spotify 连接。").foregroundStyle(palette.secondary) }
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Link("官方接入要求", destination: URL(string: "https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide")!)
                Spacer()
                Button("保存") {
                    do { try service.configure(clientID); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(PrimaryButtonStyle()).disabled(service.isEnabled || service.isBusy)
            }
        }.font(.system(size: 12)).lineSpacing(4).padding(28).frame(width: 570)
            .foregroundStyle(palette.text).background(palette.panel)
            .onAppear { clientID = service.clientID }
    }
}

struct SpotifyDevicesView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var service: SpotifyService
    @Environment(\.dismiss) private var dismiss
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeading(title: "Spotify 播放设备", subtitle: "") { dismiss() }
            Text("先在官方 App 或网页播放器播放一次，让设备出现在这里。音频由所选设备输出，AlpacaMusic 控制播放和进度。")
                .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("播放到", selection: $service.selectedDeviceID) {
                Text("Spotify 当前活动设备").tag("")
                ForEach(service.devices.filter { !$0.isRestricted && $0.id != nil }, id: \.id) { device in
                    Text(device.name + (device.isActive ? " · 正在使用" : "")).tag(device.id ?? "")
                }
            }
            if service.devices.isEmpty && !loading { Text("暂未发现可用设备").font(.system(size: 11)).foregroundStyle(palette.secondary) }
            if let error = service.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Link("打开 Spotify 网页播放器", destination: URL(string: "https://open.spotify.com/")!)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("刷新设备") { Task { await refresh() } }.buttonStyle(QuietButtonStyle()).disabled(loading)
            }
        }.padding(28).frame(width: 540).foregroundStyle(palette.text).background(palette.panel)
            .task { await refresh() }
    }
    private func refresh() async { loading = true; await service.refreshDevices(); loading = false }
}

struct SpotifyLibraryImportView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [RemoteMusicPlaylist] = []
    @State private var loading = false
    @State private var importing = false
    @State private var message: String?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var operationID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeading(title: "导入 Spotify 曲库", subtitle: "") { cancel(); dismiss() }
            Text("导入仅保存歌曲资料。开发模式下，Spotify 仅允许读取你创建或参与协作的歌单内容；喜欢的歌曲可单独导入。")
                .font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("喜欢的歌曲").font(.system(size: 13))
                Spacer()
                Button("导入") { startImport(nil) }.buttonStyle(QuietButtonStyle()).disabled(importing)
            }.padding(14).background(palette.raised, in: .rect(cornerRadius: 8))
            if loading { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let message {
                HStack {
                    Text(message).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    Spacer()
                    if importing { Button("取消") { cancel() }.buttonStyle(QuietButtonStyle()) }
                }
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(playlists) { playlist in
                        HStack {
                            Image(systemName: "music.note.list").foregroundStyle(palette.accent)
                            Text(playlist.name).font(.system(size: 12)).lineLimit(2)
                            Spacer()
                            Button("导入") { startImport(playlist) }.buttonStyle(QuietButtonStyle()).disabled(importing)
                        }.padding(14).background(palette.accent.opacity(0.035), in: .rect(cornerRadius: 8))
                    }
                }
            }.frame(minHeight: 140, maxHeight: 330)
            HStack {
                if playlists.isEmpty && !loading { Text("当前没有可列出的歌单").font(.system(size: 11)).foregroundStyle(palette.secondary) }
                Spacer()
                Button("刷新歌单") { Task { await refresh() } }.buttonStyle(QuietButtonStyle()).disabled(loading || importing)
            }
        }.padding(28).frame(width: 550).foregroundStyle(palette.text).background(palette.panel)
            .task { await refresh() }
            .onDisappear { cancel() }
            .onChange(of: model.spotify.sessionID) { _, _ in cancel(); playlists = []; error = "Spotify 连接已变化，请重新打开导入窗口。" }
    }
    private func refresh() async {
        loading = true; error = nil
        defer { loading = false }
        do { playlists = try await model.spotify.playlists() }
        catch is CancellationError { }
        catch { self.error = SpotifyService.message(error) }
    }
    private func cancel() { operationID = UUID(); task?.cancel(); task = nil; importing = false; message = nil }
    private func startImport(_ playlist: RemoteMusicPlaylist?) {
        guard !importing, let account = model.spotify.profile else { return }
        let session = model.spotify.sessionID, operation = UUID(); operationID = operation
        let name = playlist?.name ?? "喜欢的歌曲"
        importing = true; error = nil; message = "正在读取「\(name)」…"
        task = Task { @MainActor in
            defer { if operationID == operation { importing = false; task = nil } }
            do {
                await model.library.load()
                let tracks: [Track]
                if let playlist { tracks = try await model.spotify.tracks(in: playlist) }
                else { tracks = try await model.spotify.savedTracks() }
                try model.spotify.validateSession(session)
                guard operationID == operation else { return }
                let remote = playlist ?? RemoteMusicPlaylist(id: "saved-tracks", name: name, trackCount: tracks.count, source: .spotify)
                _ = try await model.library.importRemotePlaylistAndSave(remote, accountID: account.id, tracks: tracks)
                guard !Task.isCancelled, operationID == operation else { return }
                message = "已导入「\(name)」：\(tracks.count) 首歌曲"
                model.notify(message ?? "导入完成")
            } catch is CancellationError { }
            catch { if operationID == operation { self.error = SpotifyService.message(error); message = nil } }
        }
    }
}
