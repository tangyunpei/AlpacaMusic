import SwiftUI

private enum PlaylistImportStage: String {
    case reading = "读取歌单歌曲"
    case saving = "保存到音乐库"
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
    var receipt: String { "已导入 \(partial.tracks.count) 首，\(partial.failedCount) 首未导入" }
}

struct RemotePlaylistsView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var source: MusicSource
    @Environment(\.dismiss) private var dismiss
    @State private var importing: String?
    @State private var imported: Set<String> = []
    @State private var importFailure: PlaylistImportFailure?
    @State private var importTask: Task<Void, Never>?
    @State private var importToken = UUID()
    @State private var partialImport: PartialPlaylistCandidate?
    @State private var partialReceipts: [String: String] = [:]
    private var state: ConnectedMusicState { model.accounts.state(source) }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SheetHeading(title: "导入歌单", subtitle: "\(source.title) · \(state.profile?.displayName ?? "尚未连接")") { clearPendingImport(); dismiss() }
            Text("再次导入会补充新歌曲并保留本地编辑。修改仅保存在本机。").font(.system(size: 11)).foregroundStyle(palette.secondary).lineSpacing(5)
            HStack {
                Text("\(state.playlists.count) 个歌单").font(.system(size: 11)).foregroundStyle(palette.secondary)
                Spacer()
                if state.busy { ProgressView().controlSize(.small) }
                Button("刷新") { refresh() }.buttonStyle(QuietButtonStyle()).disabled(state.busy || importing != nil)
            }
            if let message = state.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(source.title) · 获取歌单列表失败", systemImage: "exclamationmark.circle")
                        .font(.system(size: 12, weight: .medium))
                    Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Button("重试获取歌单") { refresh() }.buttonStyle(QuietButtonStyle()).disabled(state.busy || importing != nil)
                }.foregroundStyle(.orange).accessibilityIdentifier("playlist-list-error")
            }
            if let candidate = partialImport {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(source.title) ·「\(candidate.playlist.name)」未完整导入", systemImage: "exclamationmark.circle")
                        .font(.system(size: 12, weight: .medium))
                    Text(candidate.saved ? candidate.receipt : "共 \(candidate.partial.totalCount) 首，可读取 \(candidate.partial.tracks.count) 首，\(candidate.partial.failedCount) 首未能读取。")
                        .font(.system(size: 11, weight: .medium))
                    Text(candidate.partial.message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if let message = candidate.saveError {
                        Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(candidate.saved ? "可重试导入缺少的歌曲。" : "尚未保存，可导入已读取的歌曲或重试整份歌单。")
                        .font(.system(size: 10))
                    HStack {
                        if !candidate.saved {
                            Button("导入可读取的 \(candidate.partial.tracks.count) 首") { savePartial(candidate) }
                                .buttonStyle(QuietButtonStyle())
                                .disabled(importing != nil || state.busy || state.profile?.id != candidate.accountID || candidate.partial.tracks.isEmpty)
                                .accessibilityIdentifier("playlist-import-readable")
                        }
                        Button("重试完整歌单") { startImport(candidate.playlist) }
                            .buttonStyle(QuietButtonStyle()).disabled(importing != nil || state.busy || state.profile?.id != candidate.accountID)
                    }
                }.foregroundStyle(.orange).accessibilityIdentifier("playlist-import-partial")
            }
            if let failure = importFailure {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(source.title) ·「\(failure.playlist.name)」导入失败", systemImage: "exclamationmark.circle")
                        .font(.system(size: 12, weight: .medium))
                    Text("失败阶段：\(failure.stage.rawValue)").font(.system(size: 10))
                    Text(failure.message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Button("重试「\(failure.playlist.name)」") { startImport(failure.playlist) }
                        .buttonStyle(QuietButtonStyle()).disabled(importing != nil || state.busy || state.profile == nil)
                }.foregroundStyle(.orange).accessibilityIdentifier("playlist-import-error")
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(state.playlists) { playlist in
                        HStack(spacing: 14) {
                            Image(systemName: "music.note.list").foregroundStyle(palette.accent).frame(width: 32)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(playlist.name).font(.system(size: 12)).foregroundStyle(palette.text)
                                Text("\(playlist.trackCount) 首歌曲").font(.system(size: 10)).foregroundStyle(palette.secondary)
                                if let receipt = partialReceipts[playlist.id] {
                                    Text(receipt).font(.system(size: 10)).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            if importing == playlist.id { ProgressView().controlSize(.small) }
                            Button(imported.contains(playlist.id) ? "已导入" : partialReceipts[playlist.id] == nil ? "导入" : "重试完整导入") { startImport(playlist) }.buttonStyle(QuietButtonStyle()).disabled(importing != nil || state.busy || imported.contains(playlist.id) || state.profile == nil)
                        }.padding(14).background(palette.accent.opacity(0.04), in: .rect(cornerRadius: 8))
                    }
                    if state.playlistsLoaded && state.playlists.isEmpty && state.error == nil && !state.busy { Text("当前账号没有可读取的歌单").font(.system(size: 12)).foregroundStyle(palette.secondary).padding(.vertical, 40) }
                }
            }.frame(minHeight: 200, maxHeight: 380)
        }.padding(28).frame(width: 580).background(palette.panel).foregroundStyle(palette.text)
        .task { await model.accounts.loadPlaylists(source) }
        .onChange(of: state.profile?.id) { _, _ in clearPendingImport(); imported = []; partialReceipts = [:] }
        .onChange(of: state.busy) { _, busy in if busy { clearPendingImport() } }
        .onChange(of: source) { _, _ in clearPendingImport(); imported = []; partialReceipts = [:] }
        .onDisappear { clearPendingImport() }
    }
    private func clearPendingImport() {
        importToken = UUID(); importTask?.cancel(); importTask = nil
        importing = nil; importFailure = nil; partialImport = nil
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
    private func startImport(_ playlist: RemoteMusicPlaylist) {
        guard let accountID = state.profile?.id, !state.busy, importing == nil else { return }
        let token = UUID(); importToken = token
        importing = playlist.id; importFailure = nil; partialImport = nil
        importTask = Task { @MainActor in
            defer { if importToken == token { importing = nil; importTask = nil } }
            var stage = PlaylistImportStage.reading
            do {
                let tracks = try await model.accounts.client.tracks(in: playlist)
                try await validateAccount(accountID, token: token)
                stage = .saving
                let saved = try await model.library.importRemotePlaylistAndSave(playlist, accountID: accountID, tracks: tracks)
                try await validateAccount(accountID, token: token)
                imported.insert(playlist.id)
                partialReceipts.removeValue(forKey: playlist.id)
                model.notify("已导入「\(saved.name)」：\(tracks.count) 首歌曲")
            } catch MusicError.incompletePlaylist(let partial) {
                do {
                    try await validateAccount(accountID, token: token)
                    partialImport = PartialPlaylistCandidate(playlist: playlist, accountID: accountID, partial: partial)
                } catch { /* Canceled or replaced accounts must not retain old tracks. */ }
            } catch is CancellationError {
                if !Task.isCancelled, importToken == token {
                    importFailure = PlaylistImportFailure(playlist: playlist, stage: stage,
                                                         message: "账号连接已变化，请确认当前账号后重试。")
                }
            }
            catch {
                guard !Task.isCancelled, importToken == token else { return }
                importFailure = PlaylistImportFailure(playlist: playlist, stage: stage,
                                                     message: PlaybackErrorMessage.describe(error, source: source, fallback: "歌单导入失败，请重试。"))
            }
        }
    }
    private func savePartial(_ candidate: PartialPlaylistCandidate) {
        guard importing == nil, !candidate.saved, !candidate.partial.tracks.isEmpty,
              !state.busy, state.profile?.id == candidate.accountID else { return }
        let token = UUID(); importToken = token
        importing = candidate.playlist.id; importFailure = nil
        partialImport?.saveError = nil
        importTask = Task { @MainActor in
            defer { if importToken == token { importing = nil; importTask = nil } }
            do {
                try await validateAccount(candidate.accountID, token: token)
                _ = try await model.library.importRemotePlaylistAndSave(candidate.playlist, accountID: candidate.accountID, tracks: candidate.partial.tracks)
                try await validateAccount(candidate.accountID, token: token)
                var saved = candidate; saved.saved = true; saved.saveError = nil
                partialImport = saved
                partialReceipts[candidate.playlist.id] = saved.receipt
                model.notify(saved.receipt)
            } catch is CancellationError {
                if importToken == token { partialImport = nil }
            } catch {
                guard !Task.isCancelled, importToken == token else { return }
                partialImport?.saveError = PlaybackErrorMessage.describe(error, source: source, fallback: "未能完成保存，请重试。")
            }
        }
    }
}
