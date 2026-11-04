import SwiftUI

private enum AppleMusicImportSelection {
    case songs
    case playlist(AppleMusicLibraryPlaylist)

    var id: String {
        switch self { case .songs: "all-library-songs"; case .playlist(let playlist): "playlist:\(playlist.id)" }
    }
    var title: String {
        switch self { case .songs: L10n.string("全部歌曲"); case .playlist(let playlist): playlist.name }
    }
    /// The count Apple reported before reading, used until the first page arrives.
    var expectedTotal: Int? {
        switch self { case .songs: nil; case .playlist(let playlist): playlist.trackCount }
    }
}

private enum AppleMusicImportOutcome {
    case imported(Int)
    case failed(String)
    case connectionChanged
    case stopped
}

/// Sequential "import all playlists" run: playlists finished so far and the
/// one currently being read or saved.
private struct AppleMusicBatchProgress: Equatable {
    var count: Int
    var finished = 0
    var currentID = ""
    var currentKey = ""
    var currentName = ""
}

struct AppleMusicLibraryImportView: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [AppleMusicLibraryPlaylist] = []
    @State private var isLoading = false
    @State private var listError: String?
    @State private var importError: String?
    @State private var lastFailure: AppleMusicImportSelection?
    @State private var refreshID = UUID()
    @State private var importing: AppleMusicImportSelection?
    @State private var savingCount: Int?
    @State private var batch: AppleMusicBatchProgress?
    @State private var receipts: [String: Int] = [:]
    @State private var rowStates: [String: ImportRowState] = [:]
    @State private var rowProgress: [String: ImportProgress] = [:]
    @State private var importTask: Task<Void, Never>?
    @State private var operationID = UUID()

    private var isBusy: Bool { importing != nil || batch != nil }
    private var importRetry: (() -> Void)? {
        guard lastFailure != nil else { return nil }
        return { retryLastFailure() }
    }
    private var motion: Animation? { systemReduced || appReduced ? nil : ExperienceMotion.panel }
    private var panelTransition: AnyTransition {
        systemReduced || appReduced ? AnyTransition.opacity : AnyTransition.move(edge: .top).combined(with: .opacity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeading(title: L10n.string("导入 Apple Music 曲库")) {
                cancelImport(); dismiss()
            }
            songsRow
            if isBusy {
                activityPanel
                    .accessibilityIdentifier("apple-music-import-progress")
                    .transition(panelTransition)
            }
            if let importError {
                AppleMusicImportErrorLine(message: importError, identifier: "apple-music-import-error",
                                          retryLabel: L10n.string("再次导入"),
                                          retryDisabled: isBusy || !model.appleMusic.isEnabled,
                                          retry: importRetry)
                    .transition(AnyTransition.opacity)
            }
            playlistHeader
            if let listError {
                AppleMusicImportErrorLine(message: L10n.string("获取歌单失败：\(listError)"), identifier: "apple-music-playlist-error",
                                          retryLabel: L10n.string("刷新歌单"), retryDisabled: isLoading || isBusy,
                                          retry: { refreshID = UUID() })
                    .transition(AnyTransition.opacity)
            }
            playlistList
        }
        .padding(28).frame(width: 590).background(palette.panel).foregroundStyle(palette.text)
        .animation(motion, value: isBusy)
        .animation(motion, value: importError)
        .animation(motion, value: listError)
        .animation(motion, value: isLoading)
        .task(id: refreshID) { await loadPlaylists() }
        .onChange(of: model.appleMusic.librarySessionID) { _, _ in
            cancelImport(); playlists = []; receipts = [:]; rowStates = [:]; rowProgress = [:]
            importError = nil; lastFailure = nil; refreshID = UUID()
        }
        .onDisappear { cancelImport() }
    }

    // MARK: Sections

    private var songsRow: some View {
        let key = AppleMusicImportSelection.songs.id
        let state = rowState(key)
        return HStack(spacing: 14) {
            Image(systemName: "music.note.house").font(.system(size: 20)).foregroundStyle(palette.accent)
                .frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("全部歌曲")).font(.system(size: 13, weight: .medium))
                AppleMusicImportCaption(state: state, progress: rowProgress[key], receipt: receipts[key], trackCount: nil)
            }
            Spacer(minLength: 8)
            ImportRowAction(state: state,
                            label: receipts[key] == nil ? L10n.string("导入全部歌曲") : L10n.string("再次导入"),
                            disabled: isBusy || !model.appleMusic.isEnabled) { startImport(.songs) }
                .accessibilityIdentifier("apple-music-import-all-songs")
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(palette.accent.opacity(state.isActive ? 0.08 : 0.055), in: .rect(cornerRadius: 10))
    }

    @ViewBuilder private var activityPanel: some View {
        if let batch {
            ImportProgressPanel(title: batch.currentName,
                                progress: ImportProgress(completed: batch.finished, total: batch.count),
                                fraction: batchFraction(batch),
                                symbol: "square.stack",
                                onCancel: { cancelImport() })
        } else if let savingCount {
            ImportProgressPanel(title: L10n.string("正在保存 \(savingCount) 首歌曲…"),
                                symbol: "tray.and.arrow.down",
                                onCancel: { cancelImport() })
        } else if let importing {
            ImportProgressPanel(title: L10n.string("正在读取「\(importing.title)」…"),
                                progress: rowProgress[importing.id],
                                symbol: "waveform",
                                onCancel: { cancelImport() })
        }
    }

    private var playlistHeader: some View {
        HStack(spacing: 8) {
            Text(L10n.string("我的歌单")).font(.system(size: 13, weight: .medium))
            if !playlists.isEmpty {
                Text(L10n.string("\(playlists.count) 个歌单")).font(.system(size: 10)).foregroundStyle(palette.secondary)
            }
            InfoHint(text: L10n.string("仅导入歌曲资料和歌单，不下载音频。再次导入会更新资料并保留本地收藏，修改不会同步回 Apple Music。"))
            Spacer(minLength: 8)
            if isLoading && !playlists.isEmpty {
                ProgressView().controlSize(.small).frame(width: 30, height: 30)
                    .help(L10n.string("刷新歌单")).accessibilityLabel(L10n.string("刷新歌单"))
            } else {
                ToolButton(symbol: "arrow.clockwise", label: L10n.string("刷新歌单")) { refreshID = UUID() }
                    .disabled(isLoading || isBusy)
            }
            Button { startBatchImport() } label: {
                Label(L10n.string("全部导入"), systemImage: "square.and.arrow.down.on.square")
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(isBusy || isLoading || playlists.isEmpty || !model.appleMusic.isEnabled)
            .accessibilityIdentifier("apple-music-import-all-playlists")
        }
    }

    private var playlistList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if isLoading && playlists.isEmpty {
                    ImportSkeletonRows(count: 4).transition(AnyTransition.opacity)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(playlists) { playlist in
                            playlistRow(playlist).id(playlist.id)
                        }
                        if !isLoading && playlists.isEmpty && listError == nil {
                            Text(L10n.string("当前账号没有可读取的歌单"))
                                .font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.vertical, 24)
                        }
                    }
                    .transition(AnyTransition.opacity)
                }
            }
            .frame(minHeight: 160, maxHeight: 300)
            .onChange(of: batch?.currentID) { _, id in
                guard let id, !id.isEmpty else { return }
                withAnimation(motion) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func playlistRow(_ playlist: AppleMusicLibraryPlaylist) -> some View {
        let key = AppleMusicImportSelection.playlist(playlist).id
        return AppleMusicPlaylistImportRow(playlist: playlist, state: rowState(key), progress: rowProgress[key],
                                           receipt: receipts[key],
                                           disabled: isBusy || !model.appleMusic.isEnabled) {
            startImport(.playlist(playlist))
        }
    }

    // MARK: State helpers

    private func rowState(_ key: String) -> ImportRowState {
        if let state = rowStates[key] { return state }
        return receipts[key] == nil ? .idle : .done
    }

    private func batchFraction(_ batch: AppleMusicBatchProgress) -> Double? {
        ImportProgress.batchFraction(finished: batch.finished, count: batch.count,
                                     current: rowProgress[batch.currentKey]?.fraction)
    }

    @MainActor private func report(_ value: ImportProgress, key: String, operation: UUID) {
        guard operationID == operation else { return }
        rowProgress[key] = value
        rowStates[key] = .working(value.fraction)
    }

    @MainActor private func settleRows() {
        rowStates = rowStates.filter { !$0.value.isActive }
    }

    // MARK: Loading

    @MainActor private func loadPlaylists() async {
        let requestID = refreshID
        isLoading = true; listError = nil
        defer { if refreshID == requestID { isLoading = false } }
        do {
            let values = try await model.appleMusic.libraryPlaylists()
            try Task.checkCancellation()
            guard refreshID == requestID else { return }
            playlists = values
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, refreshID == requestID else { return }
            listError = PlaybackErrorMessage.describe(error, source: .appleMusic, fallback: L10n.string("请检查 Apple Music 连接后重试。"))
        }
    }

    // MARK: Importing

    @MainActor private func cancelImport() {
        operationID = UUID(); importTask?.cancel(); importTask = nil
        importing = nil; savingCount = nil; batch = nil
        settleRows()
    }

    /// Clears the running operation's UI once it ends on its own.
    @MainActor private func finishOperation() {
        importTask = nil; importing = nil; savingCount = nil; batch = nil
        settleRows()
    }

    @MainActor private func retryLastFailure() {
        guard let lastFailure else { return }
        startImport(lastFailure)
    }

    @MainActor private func startImport(_ selection: AppleMusicImportSelection) {
        guard importing == nil, batch == nil else { return }
        let operation = UUID(); operationID = operation
        let session = model.appleMusic.librarySessionID
        importing = selection; importError = nil; lastFailure = nil
        importTask = Task { @MainActor in
            defer { if operationID == operation { finishOperation() } }
            let outcome = await runImport(selection, operation: operation, session: session)
            guard operationID == operation else { return }
            switch outcome {
            case .imported(let count):
                model.notify(L10n.string("已导入「\(selection.title)」：\(count) 首歌曲"))
            case .failed(let message):
                lastFailure = selection
                importError = L10n.string("「\(selection.title)」导入失败：\(message)")
            case .connectionChanged:
                lastFailure = selection
                importError = L10n.string("Apple Music 连接已变化，请确认当前账户后重试。")
            case .stopped:
                break
            }
        }
    }

    /// Imports every listed playlist one after another. A failing playlist is
    /// marked and skipped over; a changed connection or cancel stops the run.
    @MainActor private func startBatchImport() {
        guard importing == nil, batch == nil, let first = playlists.first else { return }
        let queue = playlists
        let operation = UUID(); operationID = operation
        let session = model.appleMusic.librarySessionID
        importError = nil; lastFailure = nil
        for playlist in queue { rowStates[AppleMusicImportSelection.playlist(playlist).id] = .queued }
        batch = AppleMusicBatchProgress(count: queue.count, currentID: first.id,
                                        currentKey: AppleMusicImportSelection.playlist(first).id, currentName: first.name)
        importing = .playlist(first)
        importTask = Task { @MainActor in
            defer { if operationID == operation { finishOperation() } }
            var imported = 0
            var failed = 0
            for (index, playlist) in queue.enumerated() {
                guard !Task.isCancelled, operationID == operation else { return }
                let selection = AppleMusicImportSelection.playlist(playlist)
                batch?.currentID = playlist.id
                batch?.currentKey = selection.id
                batch?.currentName = playlist.name
                let outcome = await runImport(selection, operation: operation, session: session)
                guard operationID == operation else { return }
                switch outcome {
                case .imported:
                    imported += 1
                case .failed(let message):
                    failed += 1
                    lastFailure = selection
                    importError = L10n.string("「\(playlist.name)」导入失败：\(message)")
                case .connectionChanged:
                    lastFailure = selection
                    importError = L10n.string("Apple Music 连接已变化，请确认当前账户后重试。")
                    return
                case .stopped:
                    return
                }
                batch?.finished = index + 1
            }
            if failed == 0 {
                model.notify(L10n.string("已导入 \(imported) 个歌单"))
            } else {
                model.notify(L10n.string("已导入 \(imported) 个歌单，\(failed) 个失败"))
            }
        }
    }

    /// Reads, validates and saves one selection. Success is reported only
    /// after the library has been persisted for the same session and operation.
    @MainActor private func runImport(_ selection: AppleMusicImportSelection, operation: UUID, session: UUID) async -> AppleMusicImportOutcome {
        // A cancel that lands before this task starts must not resurrect UI
        // state for an operation that is already dead.
        guard !Task.isCancelled, operationID == operation else { return .stopped }
        let key = selection.id
        importing = selection; savingCount = nil
        rowProgress[key] = ImportProgress(completed: 0, total: selection.expectedTotal)
        rowStates[key] = .working(nil)
        do {
            // Load first so the final main-actor validation and mutation have
            // no intervening disk-load suspension that can change accounts.
            await model.library.load()
            let tracks: [Track]
            switch selection {
            case .songs:
                tracks = try await model.appleMusic.librarySongs(progress: { value in
                    report(value, key: key, operation: operation)
                })
            case .playlist(let playlist):
                tracks = try await model.appleMusic.libraryTracks(in: playlist, progress: { value in
                    report(value, key: key, operation: operation)
                })
            }
            try Task.checkCancellation()
            try model.appleMusic.validateLibrarySession(session)
            guard operationID == operation else { return .stopped }
            savingCount = tracks.count
            rowStates[key] = .working(nil)
            let count: Int
            switch selection {
            case .songs:
                count = try await model.library.importAppleMusicSongsAndSave(tracks)
            case .playlist(let playlist):
                let remote = RemoteMusicPlaylist(id: playlist.id, name: playlist.name, trackCount: tracks.count,
                                                 artworkURL: playlist.artworkURL, source: .appleMusic)
                // This is a provider namespace, not an Apple Account ID.
                // The personal library playlist resource ID identifies the copy.
                _ = try await model.library.importRemotePlaylistAndSave(remote, accountID: "musickit-library", tracks: tracks)
                count = Set(tracks.map(\.id)).count
            }
            guard !Task.isCancelled, operationID == operation else { return .stopped }
            savingCount = nil
            receipts[key] = count
            rowStates[key] = .done
            return .imported(count)
        } catch is CancellationError {
            guard !Task.isCancelled, operationID == operation else { return .stopped }
            savingCount = nil
            rowStates[key] = .failed
            return .connectionChanged
        } catch {
            guard !Task.isCancelled, operationID == operation else { return .stopped }
            savingCount = nil
            rowStates[key] = .failed
            return .failed(PlaybackErrorMessage.describe(error, source: .appleMusic, fallback: L10n.string("请重试。")))
        }
    }
}

/// One playlist: thumbnail, name, a single caption and an icon-only action.
private struct AppleMusicPlaylistImportRow: View {
    @Environment(\.appPalette) private var palette
    var playlist: AppleMusicLibraryPlaylist
    var state: ImportRowState
    var progress: ImportProgress?
    var receipt: Int?
    var disabled: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            thumbnail.frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                AppleMusicImportCaption(state: state, progress: progress, receipt: receipt, trackCount: playlist.trackCount)
            }
            Spacer(minLength: 8)
            ImportRowAction(state: state, label: L10n.string("导入 Apple Music 歌单 \(playlist.name)"),
                            disabled: disabled, action: action)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(palette.accent.opacity(state.isActive ? 0.06 : 0.035), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = playlist.artworkURL {
            ArtworkView(track: Track(id: "apple-playlist:\(playlist.id)", title: playlist.name, artist: "", album: "",
                                     duration: 0, source: .appleMusic, artworkURL: url),
                        radius: 6)
        } else {
            Image(systemName: "music.note.list").font(.system(size: 14)).foregroundStyle(palette.accent)
        }
    }
}

/// The single caption under a row: a live counter while reading, the import
/// receipt afterwards, or Apple's track count before anything happened.
private struct AppleMusicImportCaption: View {
    @Environment(\.appPalette) private var palette
    var state: ImportRowState
    var progress: ImportProgress?
    var receipt: Int?
    var trackCount: Int?

    var body: some View {
        if state.isActive, let progress, progress.completed > 0 || progress.total != nil {
            ImportCounter(progress: progress)
        } else if let receipt {
            Text(L10n.string("已导入 \(receipt) 首歌曲")).font(.system(size: 10)).foregroundStyle(palette.accent)
        } else if let trackCount {
            Text(L10n.string("\(trackCount) 首歌曲")).font(.system(size: 10)).foregroundStyle(palette.secondary)
        }
    }
}

/// A compact orange line: full text stays selectable and in the tooltip.
private struct AppleMusicImportErrorLine: View {
    var message: String
    var identifier: String
    var retryLabel: String
    var retryDisabled: Bool
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).accessibilityHidden(true)
            Text(message).font(.system(size: 11)).lineLimit(2).truncationMode(.tail)
                .textSelection(.enabled).help(message)
                .accessibilityIdentifier(identifier)
            Spacer(minLength: 4)
            if let retry {
                Button(action: retry) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22).contentShape(.rect)
                }
                .buttonStyle(.plain).disabled(retryDisabled)
                .help(retryLabel).accessibilityLabel(retryLabel)
            }
        }
        .foregroundStyle(.orange)
    }
}
