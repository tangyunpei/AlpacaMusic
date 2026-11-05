import SwiftUI

private struct AlbumImportFailure {
    let album: RemoteMusicAlbum
    let message: String
}
private enum AlbumImportOutcome {
    case imported
    case failed
    case connectionChanged
    case stopped
}

/// Albums add their songs to the local library. They are not represented as
/// remote playlists, and no subscription or collection changes are sent back.
struct RemoteAlbumsView: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    var source: MusicSource
    @State private var albums: [RemoteMusicAlbum] = []
    @State private var isLoading = false
    @State private var listError: String?
    @State private var refreshID = UUID()
    @State private var operationID = UUID()
    /// The album a single import is reading or saving.
    @State private var importing: RemoteMusicAlbum?
    @State private var savingCount: Int?
    /// The sequential "import all" run; never overlaps a single import.
    @State private var batch: PlatformImportBatch?
    @State private var importTask: Task<Void, Never>?
    @State private var importFailure: AlbumImportFailure?
    @State private var receipts: [String: Int] = [:]
    /// Transient row states (queued, working, failed).
    @State private var rowStates: [String: ImportRowState] = [:]
    @State private var rowErrors: [String: String] = [:]
    private var state: ConnectedMusicState { model.accounts.state(source) }
    private var isImporting: Bool { importing != nil || batch != nil }
    /// A post-connection auto import owns the library writes while it runs.
    private var autoImporting: Bool { model.autoImport.isRunning(source) }
    private var importLocked: Bool { isImporting || autoImporting }
    private var actionsDisabled: Bool { importLocked || isLoading || state.busy || state.profile == nil }
    private var showsSkeleton: Bool { isLoading && albums.isEmpty }
    private var motion: Animation? { systemReduced || appReduced ? nil : ExperienceMotion.panel }
    private var panelTransition: AnyTransition {
        systemReduced || appReduced ? AnyTransition.opacity : AnyTransition.move(edge: .top).combined(with: .opacity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeading(title: L10n.string("导入收藏专辑"), subtitle: source.title) {
                cancelImport(); dismiss()
            }
            if autoImporting {
                AutoImportStatusPanel(coordinator: model.autoImport, source: source)
                    .accessibilityIdentifier("album-auto-import-progress")
                    .transition(panelTransition)
            }
            header
            if isImporting {
                activityPanel.transition(panelTransition)
            }
            notices
            albumList
        }
        .padding(28).frame(width: 590).background(palette.panel).foregroundStyle(palette.text)
        .animation(motion, value: isImporting)
        .animation(motion, value: autoImporting)
        .animation(motion, value: importFailure != nil)
        .animation(motion, value: listError)
        .animation(motion, value: showsSkeleton)
        .task(id: refreshID) { await loadAlbums() }
        .onChange(of: state.profile?.id) { _, _ in resetAccount() }
        .onChange(of: state.busy) { _, _ in resetAccount() }
        .onChange(of: source) { _, _ in resetAccount() }
        .onDisappear { cancelImport() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            if !showsSkeleton {
                Text(L10n.string("\(albums.count) 张专辑")).font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            InfoHint(text: L10n.string("导入的专辑会出现在专辑库中，平台上的收藏不会被修改。"))
            Spacer(minLength: 8)
            if isLoading && !albums.isEmpty {
                ProgressView().controlSize(.small).frame(width: 30, height: 30)
                    .accessibilityLabel(L10n.string("刷新专辑"))
            } else {
                ToolButton(symbol: "arrow.clockwise", label: L10n.string("刷新专辑")) { refreshID = UUID() }
                    .disabled(actionsDisabled)
            }
            Button { startBatchImport() } label: {
                Label(L10n.string("全部导入"), systemImage: "square.and.arrow.down.on.square")
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(actionsDisabled || albums.isEmpty)
            .accessibilityIdentifier("album-import-all")
        }
    }

    @ViewBuilder private var activityPanel: some View {
        if let batch {
            ImportProgressPanel(title: batch.currentName, progress: batch.progress,
                                fraction: batch.fraction(current: nil),
                                symbol: "square.stack", onCancel: { cancelImport() })
                .accessibilityIdentifier("album-import-progress")
        } else if let importing {
            // NetEase returns an album in one request, so reading stays indeterminate.
            ImportProgressPanel(title: singleTitle(importing),
                                symbol: savingCount == nil ? "waveform" : "tray.and.arrow.down",
                                onCancel: singleCancel)
                .accessibilityIdentifier("album-import-progress")
        }
    }

    /// Reading can be cancelled; saving cannot, because the library has
    /// already changed by then, so the panel offers no cancel while saving.
    private var singleCancel: (() -> Void)? {
        guard savingCount == nil else { return nil }
        return { cancelImport() }
    }

    private func singleTitle(_ album: RemoteMusicAlbum) -> String {
        if let savingCount { return L10n.string("正在保存 \(savingCount) 首歌曲…") }
        return L10n.string("正在读取「\(album.name)」…")
    }

    @ViewBuilder private var notices: some View {
        if let listError {
            PlatformImportErrorLine(message: listError,
                                    retryLabel: L10n.string("刷新专辑"),
                                    retryDisabled: isLoading || importLocked || state.busy || state.profile == nil,
                                    retry: { refreshID = UUID() })
                .accessibilityIdentifier("album-list-error")
                .transition(AnyTransition.opacity)
        }
        if let failure = importFailure {
            PlatformImportErrorLine(message: failure.message,
                                    retryLabel: L10n.string("重试「\(failure.album.name)」"),
                                    retryDisabled: actionsDisabled,
                                    retry: { startImport(failure.album) })
                .accessibilityIdentifier("album-import-error")
                .transition(AnyTransition.opacity)
        }
    }

    private var albumList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if showsSkeleton {
                    ImportSkeletonRows(count: 4)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.string("读取收藏专辑"))
                        .transition(AnyTransition.opacity)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(albums) { album in
                            albumRow(album).id(album.id)
                        }
                        if !isLoading && albums.isEmpty && listError == nil {
                            Text(L10n.string("当前账号没有可读取的收藏专辑")).font(.system(size: 12))
                                .foregroundStyle(palette.secondary).padding(.vertical, 40)
                        }
                    }
                    .transition(AnyTransition.opacity)
                }
            }
            .frame(minHeight: 200, maxHeight: 380)
            .onChange(of: batch?.currentID) { _, id in
                guard let id else { return }
                withAnimation(motion) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func albumRow(_ album: RemoteMusicAlbum) -> some View {
        let current = rowState(album.id)
        return PlatformPlaylistImportRow(title: album.name, artwork: artwork(for: album), symbol: "opticaldisc",
                                         caption: caption(for: album, state: current),
                                         state: current, actionLabel: L10n.string("导入专辑 \(album.name)"),
                                         disabled: actionsDisabled) {
            startImport(album)
        }
    }

    // MARK: Row state

    private func rowState(_ id: String) -> ImportRowState {
        if let value = rowStates[id] { return value }
        return importedCount(id) == nil ? .idle : .done
    }

    /// Songs saved for this album, by this sheet or earlier (including an
    /// auto import after connecting). Reading the library keeps rows observed.
    private func importedCount(_ id: String) -> Int? {
        if let count = receipts[id] { return count }
        return model.library.album(id: AlbumGrouping.importedID(source: source, remoteID: id))?.trackIDs.count
    }

    private func caption(for album: RemoteMusicAlbum, state current: ImportRowState) -> PlatformRowCaption {
        if current == .failed {
            return PlatformRowCaption(text: L10n.string("导入失败"), warning: true, detail: rowErrors[album.id])
        }
        if let count = importedCount(album.id) {
            return PlatformRowCaption(text: L10n.string("已导入 \(count) 首歌曲"))
        }
        var parts: [String] = []
        if !album.artist.isEmpty { parts.append(album.artist) }
        if let count = album.trackCount { parts.append(L10n.string("\(count) 首歌曲")) }
        return PlatformRowCaption(text: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    private func artwork(for album: RemoteMusicAlbum) -> Track? {
        guard let url = album.artworkURL else { return nil }
        return Track(id: "album:\(source.rawValue):\(album.id)", title: album.name, artist: album.artist, album: album.name,
                     duration: 0, source: source, artworkURL: url)
    }

    // MARK: Lifecycle

    private func resetAccount() {
        cancelImport()
        albums = []; receipts = [:]; rowStates = [:]; rowErrors = [:]; listError = nil
        refreshID = UUID()
    }
    private func cancelImport() {
        operationID = UUID(); importTask?.cancel(); importTask = nil
        importing = nil; savingCount = nil; batch = nil; importFailure = nil
        settleRows()
    }
    /// Clears the running operation's UI once it ends on its own.
    private func finishOperation() {
        importTask = nil; importing = nil; savingCount = nil; batch = nil
        settleRows()
    }
    private func settleRows() {
        rowStates = rowStates.filter { !$0.value.isActive }
    }

    @MainActor private func loadAlbums() async {
        let requestID = refreshID
        guard state.profile != nil, !state.busy else { isLoading = false; return }
        isLoading = true; listError = nil
        defer { if refreshID == requestID { isLoading = false } }
        do {
            let result = try await model.accounts.client.albums(source)
            try Task.checkCancellation()
            guard requestID == refreshID else { return }
            albums = result
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, requestID == refreshID else { return }
            listError = PlaybackErrorMessage.describe(error, source: source, fallback: L10n.string("专辑读取失败，请重试。"))
        }
    }

    // MARK: Importing

    private func startImport(_ album: RemoteMusicAlbum) {
        guard !importLocked, !state.busy, state.profile != nil else { return }
        let operation = UUID(); operationID = operation
        importing = album; savingCount = nil; importFailure = nil
        importTask = Task { @MainActor in
            defer { if operationID == operation { finishOperation() } }
            _ = await runImport(album, operation: operation, inBatch: false)
        }
    }

    /// Imports every listed album one after another. A failing album is
    /// marked and skipped; a changed account or cancel stops the run.
    private func startBatchImport() {
        guard !importLocked, !isLoading, !state.busy, state.profile != nil, let first = albums.first else { return }
        let queue = albums
        let operation = UUID(); operationID = operation
        importFailure = nil; savingCount = nil
        for album in queue {
            rowStates[album.id] = .queued
            rowErrors.removeValue(forKey: album.id)
        }
        batch = PlatformImportBatch(count: queue.count, currentID: first.id, currentName: first.name)
        importTask = Task { @MainActor in
            defer { if operationID == operation { finishOperation() } }
            var completed = 0
            var failed = 0
            for (index, album) in queue.enumerated() {
                guard !Task.isCancelled, operationID == operation else { return }
                batch?.currentID = album.id
                batch?.currentName = album.name
                let outcome = await runImport(album, operation: operation, inBatch: true)
                guard operationID == operation else { return }
                switch outcome {
                case .imported: completed += 1
                case .failed: failed += 1
                case .connectionChanged, .stopped: return
                }
                batch?.finished = index + 1
            }
            model.notify(failed == 0
                ? L10n.string("已导入 \(completed) 张专辑")
                : L10n.string("已导入 \(completed) 张专辑，\(failed) 个失败"))
        }
    }

    /// Reads, validates and saves one album. Success is reported only after
    /// the library has been persisted for the same account scope and operation.
    private func runImport(_ album: RemoteMusicAlbum, operation: UUID, inBatch: Bool) async -> AlbumImportOutcome {
        // A cancel that lands before this task starts must not resurrect UI
        // state for an operation that is already dead.
        guard !Task.isCancelled, operationID == operation else { return .stopped }
        let id = album.id
        rowStates[id] = .working(nil)
        rowErrors.removeValue(forKey: id)
        savingCount = nil
        do {
            await model.library.load()
            let scope = try await model.accounts.client.libraryScope(for: source)
            let tracks = try await model.accounts.client.tracks(in: album)
            try Task.checkCancellation()
            try await model.accounts.client.validateLibraryScope(scope)
            guard operationID == operation, !state.busy else { throw CancellationError() }
            savingCount = tracks.count
            let count = try await model.library.importRemoteAlbumAndSave(album, tracks: tracks)
            guard operationID == operation, !Task.isCancelled else { return .stopped }
            receipts[id] = count
            rowStates.removeValue(forKey: id)
            if !inBatch { model.notify(L10n.string("已导入「\(album.name)」：\(count) 首歌曲")) }
            return .imported
        } catch is CancellationError {
            guard operationID == operation, !Task.isCancelled else { return .stopped }
            let message = L10n.string("账号连接已变化，请确认当前账号后重试。")
            rowStates[id] = .failed
            rowErrors[id] = message
            importFailure = AlbumImportFailure(album: album, message: message)
            return .connectionChanged
        } catch {
            guard operationID == operation, !Task.isCancelled else { return .stopped }
            let reason = PlaybackErrorMessage.describe(error, source: source, fallback: L10n.string("专辑读取失败，请重试。"))
            rowStates[id] = .failed
            rowErrors[id] = reason
            if !inBatch {
                importFailure = AlbumImportFailure(album: album, message: L10n.string("「\(album.name)」导入失败：\(reason)"))
            }
            return .failed
        }
    }
}

struct AlbumImportArtwork: View {
    @Environment(\.appPalette) private var palette
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "opticaldisc").foregroundStyle(palette.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(palette.accent.opacity(0.08))
        }.frame(width: 42, height: 42).clipShape(.rect(cornerRadius: 6)).accessibilityHidden(true)
    }
}
