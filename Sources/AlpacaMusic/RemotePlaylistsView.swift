import SwiftUI

private enum PlaylistImportStage {
    case reading, saving

    var title: String {
        switch self {
        case .reading: L10n.string("读取歌单歌曲")
        case .saving: L10n.string("保存到音乐库")
        }
    }
}
private struct PlaylistImportFailure {
    let playlist: RemoteMusicPlaylist
    let stage: PlaylistImportStage
    let message: String
}
private struct PartialPlaylistCandidate {
    let playlist: RemoteMusicPlaylist
    let accountID: String
    let partial: PartialPlaylistImport
    var saved = false
    var saveError: String?
    var receipt: String { L10n.string("已导入 \(partial.tracks.count) 首，\(partial.failedCount) 首未导入") }
}
private enum PlaylistImportOutcome {
    case imported
    case partial
    case failed
    case connectionChanged
    case stopped
}

struct RemotePlaylistsView: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    @Bindable var model: AppModel
    var source: MusicSource
    @Environment(\.dismiss) private var dismiss
    /// The playlist a single import is reading or saving.
    @State private var importing: RemoteMusicPlaylist?
    @State private var savingCount: Int?
    /// The sequential "import all" run; never overlaps a single import.
    @State private var batch: PlatformImportBatch?
    @State private var imported: Set<String> = []
    /// Transient row states (queued, working, failed, unsaved partial).
    @State private var rowStates: [String: ImportRowState] = [:]
    /// Songs read so far for the playlist being read, as the platform reports pages.
    @State private var rowProgress: [String: ImportProgress] = [:]
    @State private var rowErrors: [String: String] = [:]
    @State private var importFailure: PlaylistImportFailure?
    @State private var importTask: Task<Void, Never>?
    @State private var importToken = UUID()
    @State private var partialImport: PartialPlaylistCandidate?
    @State private var partialReceipts: [String: String] = [:]
    private var state: ConnectedMusicState { model.accounts.state(source) }
    private var isImporting: Bool { importing != nil || batch != nil }
    private var showsSkeleton: Bool { state.busy && !state.playlistsLoaded }
    private var motion: Animation? { systemReduced || appReduced ? nil : ExperienceMotion.panel }
    private var panelTransition: AnyTransition {
        systemReduced || appReduced ? AnyTransition.opacity : AnyTransition.move(edge: .top).combined(with: .opacity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeading(title: L10n.string("导入歌单"), subtitle: "\(source.title) · \(state.profile?.displayName ?? L10n.string("尚未连接"))") { clearPendingImport(); dismiss() }
            header
            if isImporting {
                activityPanel.transition(panelTransition)
            }
            notices
            playlistList
        }
        .padding(28).frame(width: 580).background(palette.panel).foregroundStyle(palette.text)
        .animation(motion, value: isImporting)
        .animation(motion, value: importFailure != nil)
        .animation(motion, value: partialImport != nil)
        .animation(motion, value: state.error)
        .animation(motion, value: showsSkeleton)
        .task { await model.accounts.loadPlaylists(source) }
        .onChange(of: state.profile?.id) { _, _ in resetRows() }
        .onChange(of: state.busy) { _, busy in if busy { clearPendingImport() } }
        .onChange(of: source) { _, _ in resetRows() }
        .onDisappear { clearPendingImport() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            if state.playlistsLoaded {
                Text(L10n.string("\(state.playlists.count) 个歌单")).font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
            InfoHint(text: L10n.string("再次导入会补充新歌曲并保留本地编辑。修改仅保存在本机。"))
            Spacer(minLength: 8)
            if state.busy && state.playlistsLoaded {
                ProgressView().controlSize(.small).frame(width: 30, height: 30)
                    .accessibilityLabel(L10n.string("刷新歌单"))
            } else {
                ToolButton(symbol: "arrow.clockwise", label: L10n.string("刷新歌单")) { refresh() }
                    .disabled(state.busy || isImporting)
            }
            Button { startBatchImport() } label: {
                Label(L10n.string("全部导入"), systemImage: "square.and.arrow.down.on.square")
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(isImporting || state.busy || state.playlists.isEmpty || state.profile == nil)
            .accessibilityIdentifier("playlist-import-all")
        }
    }

    @ViewBuilder private var activityPanel: some View {
        if let batch {
            ImportProgressPanel(title: batch.currentName, progress: batch.progress,
                                fraction: batch.fraction(current: rowProgress[batch.currentID]?.fraction),
                                symbol: "square.stack", onCancel: { clearPendingImport() })
                .accessibilityIdentifier("playlist-import-progress")
        } else if let importing {
            ImportProgressPanel(title: singleTitle(importing), progress: savingCount == nil ? rowProgress[importing.id] : nil,
                                symbol: savingCount == nil ? "waveform" : "tray.and.arrow.down",
                                onCancel: singleCancel)
                .accessibilityIdentifier("playlist-import-progress")
        }
    }

    /// Reading can be cancelled; saving cannot, because the library has
    /// already changed by then, so the panel offers no cancel while saving.
    private var singleCancel: (() -> Void)? {
        guard savingCount == nil else { return nil }
        return { clearPendingImport() }
    }

    private func singleTitle(_ playlist: RemoteMusicPlaylist) -> String {
        if let savingCount { return L10n.string("正在保存 \(savingCount) 首歌曲…") }
        return L10n.string("正在读取「\(playlist.name)」…")
    }

    @ViewBuilder private var notices: some View {
        if let message = state.error {
            PlatformImportErrorLine(message: L10n.string("获取歌单失败：\(message)"),
                                    retryLabel: L10n.string("重试获取歌单"),
                                    retryDisabled: state.busy || isImporting,
                                    retry: { refresh() })
                .accessibilityIdentifier("playlist-list-error")
                .transition(AnyTransition.opacity)
        }
        if let candidate = partialImport {
            partialPanel(candidate).transition(AnyTransition.opacity)
        }
        if let failure = importFailure {
            failureLine(failure).transition(AnyTransition.opacity)
        }
    }

    private func failureLine(_ failure: PlaylistImportFailure) -> some View {
        let detail = L10n.string("失败阶段：\(failure.stage.title)") + "\n" + failure.message
        return PlatformImportErrorLine(message: L10n.string("「\(failure.playlist.name)」导入失败：\(failure.message)"),
                                       detail: detail,
                                       retryLabel: L10n.string("重试「\(failure.playlist.name)」"),
                                       retryDisabled: isImporting || state.busy || state.profile == nil,
                                       retry: { startImport(failure.playlist) })
            .accessibilityIdentifier("playlist-import-error")
    }

    /// One compact line: playlist, a short summary and the two recovery actions.
    /// The provider's full explanation stays in the tooltip and selectable text.
    private func partialPanel(_ candidate: PartialPlaylistCandidate) -> some View {
        let locked = isImporting || state.busy || state.profile?.id != candidate.accountID
        let summary = candidate.saveError ?? (candidate.saved ? candidate.receipt : L10n.string("\(candidate.partial.failedCount) 首未能读取"))
        let parts: [String?] = [
            L10n.string("共 \(candidate.partial.totalCount) 首，可读取 \(candidate.partial.tracks.count) 首，\(candidate.partial.failedCount) 首未能读取。"),
            candidate.partial.message,
            candidate.saveError,
        ]
        let detail = parts.compactMap { $0 }.joined(separator: "\n")
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 11)).accessibilityHidden(true)
            Text(candidate.playlist.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Text(summary).font(.system(size: 11)).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
            Spacer(minLength: 6)
            if !candidate.saved {
                Button(L10n.string("导入可读取的 \(candidate.partial.tracks.count) 首")) { savePartial(candidate) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.accent)
                    .disabled(locked || candidate.partial.tracks.isEmpty)
                    .accessibilityIdentifier("playlist-import-readable")
            }
            Button { startImport(candidate.playlist) } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22).contentShape(.rect)
            }
            .buttonStyle(.plain).disabled(locked)
            .help(L10n.string("重试完整歌单")).accessibilityLabel(L10n.string("重试完整歌单"))
        }
        .foregroundStyle(.orange)
        .help(detail)
        .accessibilityIdentifier("playlist-import-partial")
    }

    private var playlistList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if showsSkeleton {
                    ImportSkeletonRows(count: 4).transition(AnyTransition.opacity)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(state.playlists) { playlist in
                            playlistRow(playlist).id(playlist.id)
                        }
                        if state.playlistsLoaded && state.playlists.isEmpty && state.error == nil && !state.busy {
                            Text(L10n.string("当前账号没有可读取的歌单")).font(.system(size: 12))
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

    private func playlistRow(_ playlist: RemoteMusicPlaylist) -> some View {
        let current = rowState(playlist.id)
        return PlatformPlaylistImportRow(title: playlist.name, artwork: artwork(for: playlist),
                                         caption: caption(for: playlist, state: current),
                                         state: current, actionLabel: L10n.string("导入「\(playlist.name)」"),
                                         disabled: isImporting || state.busy || state.profile == nil) {
            startImport(playlist)
        }
    }

    // MARK: Row state

    private func rowState(_ id: String) -> ImportRowState {
        if let value = rowStates[id] { return value }
        if partialReceipts[id] != nil { return .partial }
        return imported.contains(id) ? .done : .idle
    }

    private func caption(for playlist: RemoteMusicPlaylist, state current: ImportRowState) -> PlatformRowCaption {
        if current == .failed {
            return PlatformRowCaption(text: L10n.string("导入失败"), warning: true, detail: rowErrors[playlist.id])
        }
        if let receipt = partialReceipts[playlist.id] {
            return PlatformRowCaption(text: receipt, warning: true)
        }
        return PlatformRowCaption(text: L10n.string("\(playlist.trackCount) 首歌曲"))
    }

    private func artwork(for playlist: RemoteMusicPlaylist) -> Track? {
        guard let url = playlist.artworkURL else { return nil }
        return Track(id: "playlist:\(source.rawValue):\(playlist.id)", title: playlist.name, artist: "", album: "",
                     duration: 0, source: source, artworkURL: url)
    }

    // MARK: Lifecycle

    private func resetRows() {
        clearPendingImport()
        imported = []; partialReceipts = [:]; rowStates = [:]; rowErrors = [:]
    }
    private func clearPendingImport() {
        importToken = UUID(); importTask?.cancel(); importTask = nil
        importing = nil; savingCount = nil; batch = nil
        importFailure = nil; partialImport = nil
        settleRows()
    }
    /// Clears the running operation's UI once it ends on its own.
    private func finishOperation() {
        importTask = nil; importing = nil; savingCount = nil; batch = nil
        settleRows()
    }
    private func settleRows() {
        rowStates = rowStates.filter { !$0.value.isActive }
        rowProgress = [:]
    }
    /// Page progress from the platform; ignored once the operation is replaced.
    private func report(_ value: ImportProgress, id: String, token: UUID) {
        guard importToken == token else { return }
        rowProgress[id] = value
        rowStates[id] = .working(value.fraction)
    }
    private func refresh() {
        clearPendingImport()
        Task { await model.accounts.loadPlaylists(source) }
    }
    private func validateAccount(_ accountID: String, token: UUID) async throws {
        try Task.checkCancellation()
        guard importToken == token, !state.busy, state.profile?.id == accountID else { throw CancellationError() }
        guard await model.accounts.client.isConnected(source, accountID: accountID) else { throw CancellationError() }
        try Task.checkCancellation()
        guard importToken == token, !state.busy, state.profile?.id == accountID else { throw CancellationError() }
    }

    // MARK: Importing

    private func startImport(_ playlist: RemoteMusicPlaylist) {
        guard let accountID = state.profile?.id, !state.busy, !isImporting else { return }
        let token = UUID(); importToken = token
        importing = playlist; savingCount = nil; importFailure = nil; partialImport = nil
        importTask = Task { @MainActor in
            defer { if importToken == token { finishOperation() } }
            _ = await runImport(playlist, accountID: accountID, token: token, inBatch: false)
        }
    }

    /// Imports every listed playlist one after another. A failing playlist is
    /// marked and skipped; an incomplete one keeps its readable tracks. A
    /// changed account or cancel stops the run.
    private func startBatchImport() {
        guard let accountID = state.profile?.id, !state.busy, !isImporting, let first = state.playlists.first else { return }
        let queue = state.playlists
        let token = UUID(); importToken = token
        importFailure = nil; partialImport = nil; savingCount = nil
        for playlist in queue {
            rowStates[playlist.id] = .queued
            rowErrors.removeValue(forKey: playlist.id)
        }
        batch = PlatformImportBatch(count: queue.count, currentID: first.id, currentName: first.name)
        importTask = Task { @MainActor in
            defer { if importToken == token { finishOperation() } }
            var completed = 0
            var failed = 0
            for (index, playlist) in queue.enumerated() {
                guard !Task.isCancelled, importToken == token else { return }
                batch?.currentID = playlist.id
                batch?.currentName = playlist.name
                let outcome = await runImport(playlist, accountID: accountID, token: token, inBatch: true)
                guard importToken == token else { return }
                switch outcome {
                case .imported, .partial: completed += 1
                case .failed: failed += 1
                case .connectionChanged, .stopped: return
                }
                batch?.finished = index + 1
            }
            model.notify(PlatformImportBatch.summary(imported: completed, failed: failed))
        }
    }

    /// Reads, validates and saves one playlist. Success is reported only after
    /// the library has been persisted for the same account and import token.
    private func runImport(_ playlist: RemoteMusicPlaylist, accountID: String, token: UUID, inBatch: Bool) async -> PlaylistImportOutcome {
        // A cancel that lands before this task starts must not resurrect UI
        // state for an operation that is already dead.
        guard !Task.isCancelled, importToken == token else { return .stopped }
        let id = playlist.id
        rowStates[id] = .working(nil)
        rowProgress[id] = ImportProgress(completed: 0, total: playlist.trackCount > 0 ? playlist.trackCount : nil)
        rowErrors.removeValue(forKey: id)
        savingCount = nil
        var stage = PlaylistImportStage.reading
        do {
            let tracks = try await model.accounts.client.tracks(in: playlist, progress: { value in
                report(value, id: id, token: token)
            })
            try await validateAccount(accountID, token: token)
            stage = .saving
            savingCount = tracks.count
            rowStates[id] = .working(nil)
            let saved = try await model.library.importRemotePlaylistAndSave(playlist, accountID: accountID, tracks: tracks)
            try await validateAccount(accountID, token: token)
            imported.insert(playlist.id)
            partialReceipts.removeValue(forKey: playlist.id)
            rowStates.removeValue(forKey: playlist.id)
            if !inBatch { model.notify(L10n.string("已导入「\(saved.name)」：\(tracks.count) 首歌曲")) }
            return .imported
        } catch MusicError.incompletePlaylist(let partial) {
            do {
                try await validateAccount(accountID, token: token)
            } catch {
                // Canceled or replaced accounts must not retain old tracks.
                guard !Task.isCancelled, importToken == token else { return .stopped }
                markConnectionChanged(playlist, stage: .reading)
                return .connectionChanged
            }
            let candidate = PartialPlaylistCandidate(playlist: playlist, accountID: accountID, partial: partial)
            guard inBatch else {
                partialImport = candidate
                rowStates[playlist.id] = .partial
                return .partial
            }
            return await saveReadable(candidate, token: token)
        } catch is CancellationError {
            guard !Task.isCancelled, importToken == token else { return .stopped }
            markConnectionChanged(playlist, stage: stage)
            return .connectionChanged
        } catch {
            guard !Task.isCancelled, importToken == token else { return .stopped }
            let message = PlaybackErrorMessage.describe(error, source: source, fallback: L10n.string("歌单导入失败，请重试。"))
            rowStates[playlist.id] = .failed
            rowErrors[playlist.id] = message
            if !inBatch { importFailure = PlaylistImportFailure(playlist: playlist, stage: stage, message: message) }
            return .failed
        }
    }

    /// Batch mode keeps what could be read from an incomplete playlist, using
    /// the same validated save as "import readable tracks".
    private func saveReadable(_ candidate: PartialPlaylistCandidate, token: UUID) async -> PlaylistImportOutcome {
        let id = candidate.playlist.id
        guard !candidate.partial.tracks.isEmpty else {
            rowStates[id] = .failed
            rowErrors[id] = candidate.partial.message
            return .failed
        }
        do {
            try await validateAccount(candidate.accountID, token: token)
            savingCount = candidate.partial.tracks.count
            _ = try await model.library.importRemotePlaylistAndSave(candidate.playlist, accountID: candidate.accountID, tracks: candidate.partial.tracks)
            try await validateAccount(candidate.accountID, token: token)
            partialReceipts[id] = candidate.receipt
            rowStates.removeValue(forKey: id)
            return .partial
        } catch is CancellationError {
            guard !Task.isCancelled, importToken == token else { return .stopped }
            markConnectionChanged(candidate.playlist, stage: .saving)
            return .connectionChanged
        } catch {
            guard !Task.isCancelled, importToken == token else { return .stopped }
            rowStates[id] = .failed
            rowErrors[id] = PlaybackErrorMessage.describe(error, source: source, fallback: L10n.string("未能完成保存，请重试。"))
            return .failed
        }
    }

    private func markConnectionChanged(_ playlist: RemoteMusicPlaylist, stage: PlaylistImportStage) {
        let message = L10n.string("账号连接已变化，请确认当前账号后重试。")
        rowStates[playlist.id] = .failed
        rowErrors[playlist.id] = message
        importFailure = PlaylistImportFailure(playlist: playlist, stage: stage, message: message)
    }

    private func savePartial(_ candidate: PartialPlaylistCandidate) {
        guard !isImporting, !candidate.saved, !candidate.partial.tracks.isEmpty,
              !state.busy, state.profile?.id == candidate.accountID else { return }
        let token = UUID(); importToken = token
        importing = candidate.playlist; savingCount = candidate.partial.tracks.count; importFailure = nil
        partialImport?.saveError = nil
        rowStates[candidate.playlist.id] = .working(nil)
        importTask = Task { @MainActor in
            defer { if importToken == token { finishOperation() } }
            do {
                try await validateAccount(candidate.accountID, token: token)
                _ = try await model.library.importRemotePlaylistAndSave(candidate.playlist, accountID: candidate.accountID, tracks: candidate.partial.tracks)
                try await validateAccount(candidate.accountID, token: token)
                var saved = candidate; saved.saved = true; saved.saveError = nil
                partialImport = saved
                partialReceipts[candidate.playlist.id] = saved.receipt
                rowStates.removeValue(forKey: candidate.playlist.id)
                model.notify(saved.receipt)
            } catch is CancellationError {
                if importToken == token { partialImport = nil }
            } catch {
                guard !Task.isCancelled, importToken == token else { return }
                partialImport?.saveError = PlaybackErrorMessage.describe(error, source: source, fallback: L10n.string("未能完成保存，请重试。"))
                rowStates[candidate.playlist.id] = .partial
            }
        }
    }
}

// MARK: - Shared platform import pieces (also used by SpotifyLibraryImportView)

/// A sequential "import all" run: rows finished so far and the current one.
struct PlatformImportBatch: Equatable {
    var count: Int
    var finished = 0
    var currentID: String
    var currentName: String

    var progress: ImportProgress { ImportProgress(completed: finished, total: count) }
    /// Overall fraction, including the reported share of the row being read.
    func fraction(current: Double?) -> Double? {
        ImportProgress.batchFraction(finished: finished, count: count, current: current)
    }

    /// One short notification for the whole run.
    static func summary(imported: Int, failed: Int) -> String {
        failed == 0 ? L10n.string("已导入 \(imported) 个歌单") : L10n.string("已导入 \(imported) 个歌单，\(failed) 个失败")
    }
}

/// The single caption under a playlist row. `detail` feeds the tooltip.
struct PlatformRowCaption {
    var text: String?
    var warning = false
    var detail: String? = nil
}

/// One playlist: optional artwork, name, one caption and an icon-only action.
struct PlatformPlaylistImportRow: View {
    @Environment(\.appPalette) private var palette
    var title: String
    var artwork: Track?
    var symbol = "music.note.list"
    var caption: PlatformRowCaption
    var state: ImportRowState
    var actionLabel: String
    var disabled: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            thumbnail.frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12)).foregroundStyle(palette.text).lineLimit(1).truncationMode(.tail)
                captionText
            }
            Spacer(minLength: 8)
            ImportRowAction(state: state, label: actionLabel, disabled: disabled, action: action)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(palette.accent.opacity(state.isActive ? 0.07 : 0.035), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder private var captionText: some View {
        if let text = caption.text {
            Text(text).font(.system(size: 10)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(caption.warning ? Color.orange : palette.secondary)
                .help(caption.detail ?? text)
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let artwork {
            ArtworkView(track: artwork, radius: 6)
        } else {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(palette.accent)
        }
    }
}

/// A compact orange line with an icon retry. The full text stays selectable
/// and in the tooltip.
struct PlatformImportErrorLine: View {
    var message: String
    var detail: String? = nil
    var retryLabel: String = ""
    var retryDisabled = false
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).accessibilityHidden(true)
            Text(message).font(.system(size: 11)).lineLimit(2).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).help(detail ?? message)
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
