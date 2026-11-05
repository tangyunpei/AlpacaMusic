import SwiftUI

struct SpotifyConnectionControls: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @State private var showsSetup = false
    @State private var showsLibrary = false
    @State private var showsDevices = false
    /// Set by a login the user started here; restores never auto-import.
    @State private var awaitingLogin = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.spotify.isEnabled {
                Button { showsLibrary = true } label: {
                    Label(L10n.string("导入歌单"), systemImage: "music.note.list").frame(maxWidth: .infinity)
                }.buttonStyle(QuietButtonStyle()).accessibilityIdentifier("spotify-import-library")
                HStack {
                    Button(L10n.string("播放设备")) { showsDevices = true }.buttonStyle(QuietButtonStyle())
                    Spacer()
                    Button(L10n.string("断开")) {
                        model.autoImport.cancel(.spotify)
                        Task {
                            await model.player.pauseAndWaitForSpotify()
                            await model.spotify.disconnect()
                            model.clearSearchResults(for: .spotify)
                        }
                    }.buttonStyle(.plain).font(.system(size: 11))
                }.disabled(model.spotify.isBusy)
            } else if model.spotify.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L10n.string("正在连接…")).font(.system(size: 11))
                    Spacer()
                    Button(L10n.string("取消")) { awaitingLogin = false; model.spotify.cancelConnection() }.buttonStyle(QuietButtonStyle())
                }
            } else {
                Button {
                    if model.spotify.isConfigured {
                        model.spotify.connect()
                        awaitingLogin = model.spotify.isBusy
                    } else { showsSetup = true }
                } label: {
                    Label(model.spotify.isConfigured ? L10n.string("登录 Spotify") : L10n.string("配置 Spotify"), systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(QuietButtonStyle()).accessibilityIdentifier("spotify-connect")
            }
            Button(L10n.string("接入设置")) { showsSetup = true }.buttonStyle(.plain)
                .font(.system(size: 10)).foregroundStyle(palette.accent)
            if let error = model.spotify.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).help(error)
            }
        }
        .onChange(of: model.spotify.isEnabled) { _, enabled in
            guard enabled, awaitingLogin else { return }
            awaitingLogin = false
            // Imports in the background; the floating card shows progress.
            model.autoImport.cancel(.spotify)
            model.autoImport.start(.spotify)
        }
        .onChange(of: model.spotify.isBusy) { _, busy in
            if !busy && !model.spotify.isEnabled { awaitingLogin = false }
        }
        .onChange(of: model.spotify.error) { _, error in
            if error != nil { awaitingLogin = false }
        }
        .sheet(isPresented: $showsSetup) { SpotifySetupView(service: model.spotify) }
        .sheet(isPresented: $showsLibrary) {
            SpotifyLibraryImportView(model: model).modifier(PanelEntrance(appReduced: model.visual.reduceMotion))
        }
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
            SheetHeading(title: L10n.string("连接 Spotify"), subtitle: "") { dismiss() }
            Text(L10n.string("1. 打开开发者后台，创建应用并选择 Web API。"))
            Link(L10n.string("打开 Spotify Developer Dashboard"), destination: URL(string: "https://developer.spotify.com/dashboard")!)
                .foregroundStyle(palette.accent)
            Text(L10n.string("2. 在应用设置的 Redirect URIs 中添加以下地址并保存。"))
            HStack {
                Text(SpotifyAuthorization.redirectURI).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button(L10n.string("复制")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SpotifyAuthorization.redirectURI, forType: .string)
                }.buttonStyle(QuietButtonStyle())
            }.padding(12).background(palette.raised, in: .rect(cornerRadius: 8))
            Text(L10n.string("3. 将应用的 Client ID 填在这里，再返回音源页登录。"))
            TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("spotify-client-id").disabled(service.isEnabled || service.isBusy)
            Text(L10n.string("不需要 Client Secret。开发模式要求应用所有者有 Premium，最多允许 5 位测试用户；其他账号需加入应用的用户列表。"))
                .foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.string("歌单和喜欢的歌曲导入到本地。播放由 Spotify 官方 App 或网页播放器输出，需要 Premium 和可用播放设备。"))
                .foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            if service.isEnabled { Text(L10n.string("更换 Client ID 前，请先断开当前 Spotify 连接。")).foregroundStyle(palette.secondary) }
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Link(L10n.string("官方接入要求"), destination: URL(string: "https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide")!)
                Spacer()
                Button(L10n.string("保存")) {
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
            SheetHeading(title: L10n.string("Spotify 播放设备"), subtitle: "") { dismiss() }
            Text(L10n.string("先在官方 App 或网页播放器播放一次，让设备出现在这里。音频由所选设备输出，AlpacaMusic 控制播放和进度。"))
                .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            Picker(L10n.string("播放到"), selection: $service.selectedDeviceID) {
                Text(L10n.string("Spotify 当前活动设备")).tag("")
                ForEach(service.devices.filter { !$0.isRestricted && $0.id != nil }, id: \.id) { device in
                    Text(device.name + (device.isActive ? L10n.string(" · 正在使用") : "")).tag(device.id ?? "")
                }
            }
            if service.devices.isEmpty && !loading { Text(L10n.string("暂未发现可用设备")).font(.system(size: 11)).foregroundStyle(palette.secondary) }
            if let error = service.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Link(L10n.string("打开 Spotify 网页播放器"), destination: URL(string: "https://open.spotify.com/")!)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button(L10n.string("刷新设备")) { Task { await refresh() } }.buttonStyle(QuietButtonStyle()).disabled(loading)
            }
        }.padding(28).frame(width: 540).foregroundStyle(palette.text).background(palette.panel)
            .task { await refresh() }
    }
    private func refresh() async { loading = true; await service.refreshDevices(); loading = false }
}

/// "Liked songs" or one playlist; liked songs reuse the existing saved-tracks id.
private struct SpotifyImportItem: Equatable {
    var playlist: RemoteMusicPlaylist?
    static let savedTracksID = "saved-tracks"
    var id: String { playlist?.id ?? Self.savedTracksID }
    var name: String { playlist?.name ?? L10n.string("喜欢的歌曲") }
}

private enum SpotifyImportOutcome {
    case imported(Int)
    case failed(String)
    case stopped
}

struct SpotifyLibraryImportView: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [RemoteMusicPlaylist] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var listError: String?
    @State private var importError: String?
    @State private var lastFailure: SpotifyImportItem?
    @State private var importing: SpotifyImportItem?
    @State private var savingCount: Int?
    @State private var batch: PlatformImportBatch?
    @State private var receipts: [String: Int] = [:]
    @State private var rowStates: [String: ImportRowState] = [:]
    /// Items read so far for the row being read, as Spotify reports pages.
    @State private var rowProgress: [String: ImportProgress] = [:]
    @State private var rowErrors: [String: String] = [:]
    @State private var task: Task<Void, Never>?
    @State private var operationID = UUID()
    private var isImporting: Bool { importing != nil || batch != nil }
    /// A background import of this account is running; manual imports would overlap it.
    private var autoImporting: Bool { model.autoImport.isRunning(.spotify) }
    private var locked: Bool { isImporting || autoImporting || !model.spotify.isEnabled }
    private var motion: Animation? { systemReduced || appReduced ? nil : ExperienceMotion.panel }
    private var panelTransition: AnyTransition {
        systemReduced || appReduced ? AnyTransition.opacity : AnyTransition.move(edge: .top).combined(with: .opacity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeading(title: L10n.string("导入 Spotify 曲库"), subtitle: model.spotify.profile?.displayName ?? "") { cancel(); dismiss() }
            if autoImporting {
                AutoImportStatusPanel(coordinator: model.autoImport, source: .spotify)
                    .accessibilityIdentifier("spotify-auto-import-progress")
                    .transition(panelTransition)
            }
            savedRow
            if isImporting {
                activityPanel.transition(panelTransition)
            }
            if let importError {
                PlatformImportErrorLine(message: importError, retryLabel: L10n.string("再次导入"),
                                        retryDisabled: locked,
                                        retry: retryAction)
                    .transition(AnyTransition.opacity)
            }
            header
            if let listError {
                PlatformImportErrorLine(message: L10n.string("获取歌单失败：\(listError)"), retryLabel: L10n.string("刷新歌单"),
                                        retryDisabled: loading || isImporting,
                                        retry: { Task { await refresh() } })
                    .transition(AnyTransition.opacity)
            }
            playlistList
        }
        .padding(28).frame(width: 550).foregroundStyle(palette.text).background(palette.panel)
        .animation(motion, value: isImporting)
        .animation(motion, value: autoImporting)
        .animation(motion, value: importError)
        .animation(motion, value: listError)
        .animation(motion, value: loading)
        .task { await refresh() }
        .onDisappear { cancel() }
        .onChange(of: model.spotify.sessionID) { _, _ in
            cancel(); playlists = []; loaded = false; receipts = [:]; rowStates = [:]; rowErrors = [:]
            lastFailure = nil; importError = L10n.string("Spotify 连接已变化，请重新打开导入窗口。")
        }
    }

    // MARK: Sections

    private var savedRow: some View {
        let item = SpotifyImportItem(playlist: nil)
        let current = rowState(item.id)
        return PlatformPlaylistImportRow(title: item.name, artwork: nil, symbol: "heart",
                                         caption: caption(for: item, state: current), state: current,
                                         actionLabel: L10n.string("导入「\(item.name)」"),
                                         disabled: locked) {
            startImport(item)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L10n.string("我的歌单")).font(.system(size: 13, weight: .medium))
            if loaded {
                Text(L10n.string("\(playlists.count) 个歌单")).font(.system(size: 10)).foregroundStyle(palette.secondary)
            }
            InfoHint(text: L10n.string("导入仅保存歌曲资料。开发模式下，Spotify 仅允许读取你创建或参与协作的歌单内容；喜欢的歌曲可单独导入。"))
            Spacer(minLength: 8)
            if loading && loaded {
                ProgressView().controlSize(.small).frame(width: 30, height: 30)
                    .accessibilityLabel(L10n.string("刷新歌单"))
            } else {
                ToolButton(symbol: "arrow.clockwise", label: L10n.string("刷新歌单")) { Task { await refresh() } }
                    .disabled(loading || isImporting)
            }
            Button { startBatchImport() } label: {
                Label(L10n.string("全部导入"), systemImage: "square.and.arrow.down.on.square")
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(locked || loading)
            .accessibilityIdentifier("spotify-import-all")
        }
    }

    @ViewBuilder private var activityPanel: some View {
        if let batch {
            ImportProgressPanel(title: batch.currentName, progress: batch.progress,
                                fraction: batch.fraction(current: rowProgress[batch.currentID]?.fraction),
                                symbol: "square.stack", onCancel: { cancel() })
                .accessibilityIdentifier("spotify-import-progress")
        } else if let importing {
            ImportProgressPanel(title: singleTitle(importing), progress: savingCount == nil ? rowProgress[importing.id] : nil,
                                symbol: savingCount == nil ? "waveform" : "tray.and.arrow.down",
                                onCancel: singleCancel)
                .accessibilityIdentifier("spotify-import-progress")
        }
    }

    /// Reading can be cancelled; saving cannot, because the library has
    /// already changed by then, so the panel offers no cancel while saving.
    private var singleCancel: (() -> Void)? {
        guard savingCount == nil else { return nil }
        return { cancel() }
    }

    private func singleTitle(_ item: SpotifyImportItem) -> String {
        if let savingCount { return L10n.string("正在保存 \(savingCount) 首歌曲…") }
        return L10n.string("正在读取「\(item.name)」…")
    }

    private var playlistList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if loading && !loaded {
                    ImportSkeletonRows(count: 4).transition(AnyTransition.opacity)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(playlists) { playlist in
                            playlistRow(playlist).id(playlist.id)
                        }
                        if loaded && playlists.isEmpty && !loading && listError == nil {
                            Text(L10n.string("当前没有可列出的歌单")).font(.system(size: 11))
                                .foregroundStyle(palette.secondary).padding(.vertical, 24)
                        }
                    }
                    .transition(AnyTransition.opacity)
                }
            }
            .frame(minHeight: 140, maxHeight: 330)
            .onChange(of: batch?.currentID) { _, id in
                guard let id, id != SpotifyImportItem.savedTracksID else { return }
                withAnimation(motion) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func playlistRow(_ playlist: RemoteMusicPlaylist) -> some View {
        let item = SpotifyImportItem(playlist: playlist)
        let current = rowState(item.id)
        return PlatformPlaylistImportRow(title: playlist.name, artwork: artwork(for: playlist),
                                         caption: caption(for: item, state: current), state: current,
                                         actionLabel: L10n.string("导入「\(playlist.name)」"),
                                         disabled: locked) {
            startImport(item)
        }
    }

    // MARK: Row state

    private var retryAction: (() -> Void)? {
        guard lastFailure != nil else { return nil }
        return { retryLastFailure() }
    }

    private func rowState(_ id: String) -> ImportRowState {
        if let value = rowStates[id] { return value }
        return receipts[id] == nil ? .idle : .done
    }

    private func caption(for item: SpotifyImportItem, state current: ImportRowState) -> PlatformRowCaption {
        if current == .failed {
            return PlatformRowCaption(text: L10n.string("导入失败"), warning: true, detail: rowErrors[item.id])
        }
        if let receipt = receipts[item.id] {
            return PlatformRowCaption(text: L10n.string("已导入 \(receipt) 首歌曲"))
        }
        guard let playlist = item.playlist, playlist.trackCount > 0 else { return PlatformRowCaption(text: nil) }
        return PlatformRowCaption(text: L10n.string("\(playlist.trackCount) 首歌曲"))
    }

    private func artwork(for playlist: RemoteMusicPlaylist) -> Track? {
        guard let url = playlist.artworkURL else { return nil }
        return Track(id: "playlist:\(MusicSource.spotify.rawValue):\(playlist.id)", title: playlist.name, artist: "", album: "",
                     duration: 0, source: .spotify, artworkURL: url)
    }

    // MARK: Loading

    private func refresh() async {
        loading = true; listError = nil
        defer { loading = false }
        do {
            playlists = try await model.spotify.playlists()
            loaded = true
        }
        catch is CancellationError { }
        catch { self.listError = SpotifyService.message(error) }
    }

    // MARK: Importing

    private func cancel() {
        operationID = UUID(); task?.cancel(); task = nil
        importing = nil; savingCount = nil; batch = nil
        settleRows()
    }
    /// Clears the running operation's UI once it ends on its own.
    private func finishOperation() {
        task = nil; importing = nil; savingCount = nil; batch = nil
        settleRows()
    }
    private func settleRows() {
        rowStates = rowStates.filter { !$0.value.isActive }
        rowProgress = [:]
    }
    /// Page progress from Spotify; ignored once the operation is replaced.
    private func report(_ value: ImportProgress, key: String, operation: UUID) {
        guard operationID == operation else { return }
        rowProgress[key] = value
        rowStates[key] = .working(value.fraction)
    }
    private func retryLastFailure() {
        guard let lastFailure else { return }
        startImport(lastFailure)
    }

    private func startImport(_ item: SpotifyImportItem) {
        guard !isImporting, !autoImporting, let account = model.spotify.profile else { return }
        let session = model.spotify.sessionID, operation = UUID(); operationID = operation
        importing = item; importError = nil; lastFailure = nil
        task = Task { @MainActor in
            defer { if operationID == operation { finishOperation() } }
            let outcome = await runImport(item, accountID: account.id, session: session, operation: operation)
            guard operationID == operation else { return }
            switch outcome {
            case .imported(let count):
                model.notify(L10n.string("已导入「\(item.name)」：\(count) 首歌曲"))
            case .failed(let message):
                lastFailure = item
                importError = L10n.string("「\(item.name)」导入失败：\(message)")
            case .stopped:
                break
            }
        }
    }

    /// Liked songs first, then every playlist, one after another. A failing
    /// row is marked and skipped; a changed session or cancel stops the run.
    private func startBatchImport() {
        guard !isImporting, !autoImporting, let account = model.spotify.profile else { return }
        let queue = [SpotifyImportItem(playlist: nil)] + playlists.map { SpotifyImportItem(playlist: $0) }
        guard let first = queue.first else { return }
        let session = model.spotify.sessionID, operation = UUID(); operationID = operation
        importError = nil; lastFailure = nil
        for item in queue {
            rowStates[item.id] = .queued
            rowErrors.removeValue(forKey: item.id)
        }
        batch = PlatformImportBatch(count: queue.count, currentID: first.id, currentName: first.name)
        task = Task { @MainActor in
            defer { if operationID == operation { finishOperation() } }
            var completed = 0
            var failed = 0
            for (index, item) in queue.enumerated() {
                guard !Task.isCancelled, operationID == operation else { return }
                batch?.currentID = item.id
                batch?.currentName = item.name
                let outcome = await runImport(item, accountID: account.id, session: session, operation: operation)
                guard operationID == operation else { return }
                switch outcome {
                case .imported: completed += 1
                case .failed: failed += 1
                case .stopped: return
                }
                batch?.finished = index + 1
            }
            model.notify(PlatformImportBatch.summary(imported: completed, failed: failed))
        }
    }

    /// Reads and saves one row for the session it started in. The receipt is
    /// recorded only after the library has been persisted.
    private func runImport(_ item: SpotifyImportItem, accountID: String, session: UUID, operation: UUID) async -> SpotifyImportOutcome {
        // A cancel that lands before this task starts must not resurrect UI
        // state for an operation that is already dead.
        guard !Task.isCancelled, operationID == operation else { return .stopped }
        let key = item.id
        rowStates[key] = .working(nil)
        let expected = item.playlist.map(\.trackCount) ?? 0
        rowProgress[key] = ImportProgress(completed: 0, total: expected > 0 ? expected : nil)
        rowErrors.removeValue(forKey: key)
        savingCount = nil
        do {
            await model.library.load()
            let progress: @MainActor @Sendable (ImportProgress) -> Void = { value in
                report(value, key: key, operation: operation)
            }
            let tracks: [Track]
            if let playlist = item.playlist { tracks = try await model.spotify.tracks(in: playlist, progress: progress) }
            else { tracks = try await model.spotify.savedTracks(progress: progress) }
            try model.spotify.validateSession(session)
            guard operationID == operation else { return .stopped }
            savingCount = tracks.count
            rowStates[key] = .working(nil)
            let remote = item.playlist ?? RemoteMusicPlaylist(id: SpotifyImportItem.savedTracksID, name: item.name, trackCount: tracks.count, source: .spotify)
            _ = try await model.library.importRemotePlaylistAndSave(remote, accountID: accountID, tracks: tracks)
            guard !Task.isCancelled, operationID == operation else { return .stopped }
            savingCount = nil
            receipts[key] = tracks.count
            rowStates.removeValue(forKey: key)
            return .imported(tracks.count)
        } catch is CancellationError {
            return .stopped
        } catch {
            guard operationID == operation else { return .stopped }
            let message = SpotifyService.message(error)
            rowStates[key] = .failed
            rowErrors[key] = message
            return .failed(message)
        }
    }
}
