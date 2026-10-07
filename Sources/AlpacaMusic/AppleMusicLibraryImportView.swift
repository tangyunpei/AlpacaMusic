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
}

struct AppleMusicLibraryImportView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [AppleMusicLibraryPlaylist] = []
    @State private var isLoading = false
    @State private var listError: String?
    @State private var importError: String?
    @State private var refreshID = UUID()
    @State private var importing: AppleMusicImportSelection?
    @State private var progress: String?
    @State private var receipts: [String: Int] = [:]
    @State private var importTask: Task<Void, Never>?
    @State private var operationID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeading(title: L10n.string("导入 Apple Music 曲库"), subtitle: "") {
                cancelImport(); dismiss()
            }
            Text(L10n.string("仅导入歌曲资料和歌单，不下载音频。再次导入会更新资料并保留本地收藏，修改不会同步回 Apple Music。"))
                .font(.system(size: 11)).foregroundStyle(palette.secondary).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                Image(systemName: "music.note.house").font(.system(size: 24)).foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.string("全部歌曲")).font(.system(size: 13, weight: .medium))
                    Text(L10n.string("个人曲库中的歌曲及专辑曲目")).font(.system(size: 10)).foregroundStyle(palette.secondary)
                    if let count = receipts[AppleMusicImportSelection.songs.id] {
                        Text(L10n.string("已导入 \(count) 首歌曲")).font(.system(size: 10)).foregroundStyle(palette.accent)
                    }
                }
                Spacer()
                Button(receipts[AppleMusicImportSelection.songs.id] == nil ? L10n.string("导入全部歌曲") : L10n.string("再次导入")) { startImport(.songs) }
                    .buttonStyle(QuietButtonStyle()).disabled(importing != nil || !model.appleMusic.isEnabled)
                    .accessibilityIdentifier("apple-music-import-all-songs")
            }.padding(16).background(palette.accent.opacity(0.055), in: .rect(cornerRadius: 10))

            if let progress {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.system(size: 11))
                    Spacer()
                    Button(L10n.string("取消")) { cancelImport() }.buttonStyle(QuietButtonStyle())
                }.accessibilityIdentifier("apple-music-import-progress")
            }
            if let importError {
                Text(importError).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("apple-music-import-error")
            }

            HStack {
                Text(L10n.string("我的歌单")).font(.system(size: 13, weight: .medium))
                Text(L10n.string("\(playlists.count) 个")).font(.system(size: 10)).foregroundStyle(palette.secondary)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button(L10n.string("刷新歌单")) { refreshID = UUID() }.buttonStyle(QuietButtonStyle())
                    .disabled(isLoading || importing != nil)
            }
            if let listError {
                Text(L10n.string("获取歌单失败：\(listError)")).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(playlists) { playlist in
                        HStack(spacing: 14) {
                            Image(systemName: "music.note.list").foregroundStyle(palette.accent).frame(width: 30)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(playlist.name).font(.system(size: 12))
                                if let count = receipts[AppleMusicImportSelection.playlist(playlist).id] {
                                    Text(L10n.string("已导入 \(count) 首歌曲")).font(.system(size: 10)).foregroundStyle(palette.accent)
                                } else {
                                    Text(playlist.trackCount.map { L10n.string("\($0) 首歌曲") } ?? L10n.string("歌曲数量待读取"))
                                        .font(.system(size: 10)).foregroundStyle(palette.secondary)
                                }
                            }
                            Spacer()
                            Button(receipts[AppleMusicImportSelection.playlist(playlist).id] == nil ? L10n.string("导入") : L10n.string("再次导入")) {
                                startImport(.playlist(playlist))
                            }.buttonStyle(QuietButtonStyle()).disabled(importing != nil || !model.appleMusic.isEnabled)
                                .accessibilityLabel(L10n.string("导入 Apple Music 歌单 \(playlist.name)"))
                        }.padding(14).background(palette.accent.opacity(0.035), in: .rect(cornerRadius: 8))
                    }
                    if !isLoading && playlists.isEmpty && listError == nil {
                        Text(L10n.string("当前账号没有可读取的歌单"))
                            .font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.vertical, 24)
                    }
                }
            }.frame(minHeight: 160, maxHeight: 300)
        }.padding(28).frame(width: 590).background(palette.panel).foregroundStyle(palette.text)
        .task(id: refreshID) { await loadPlaylists() }
        .onChange(of: model.appleMusic.librarySessionID) { _, _ in
            cancelImport(); playlists = []; receipts = [:]; refreshID = UUID()
        }
        .onDisappear { cancelImport() }
    }

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

    @MainActor private func cancelImport() {
        operationID = UUID(); importTask?.cancel(); importTask = nil
        importing = nil; progress = nil
    }

    @MainActor private func startImport(_ selection: AppleMusicImportSelection) {
        guard importing == nil else { return }
        let operation = UUID(); operationID = operation
        let session = model.appleMusic.librarySessionID
        importing = selection; importError = nil
        progress = L10n.string("正在读取「\(selection.title)」…")
        importTask = Task { @MainActor in
            defer {
                if operationID == operation { importing = nil; progress = nil; importTask = nil }
            }
            do {
                // Load first so the final main-actor validation and mutation have
                // no intervening disk-load suspension that can change accounts.
                await model.library.load()
                let tracks: [Track]
                switch selection {
                case .songs: tracks = try await model.appleMusic.librarySongs()
                case .playlist(let playlist): tracks = try await model.appleMusic.libraryTracks(in: playlist)
                }
                try Task.checkCancellation()
                try model.appleMusic.validateLibrarySession(session)
                guard operationID == operation else { return }
                progress = L10n.string("正在保存 \(tracks.count) 首歌曲…")
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
                guard !Task.isCancelled, operationID == operation else { return }
                receipts[selection.id] = count
                model.notify(L10n.string("已导入「\(selection.title)」：\(count) 首歌曲"))
            } catch is CancellationError {
                if !Task.isCancelled, operationID == operation {
                    importError = L10n.string("Apple Music 连接已变化，请确认当前账户后重试。")
                }
            } catch {
                guard !Task.isCancelled, operationID == operation else { return }
                importError = L10n.string("「\(selection.title)」导入失败：\(PlaybackErrorMessage.describe(error, source: .appleMusic, fallback: L10n.string("请重试。")))")
            }
        }
    }
}
