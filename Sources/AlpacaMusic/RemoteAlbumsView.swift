import SwiftUI

/// Albums add their songs to the local library. They are not represented as
/// remote playlists, and no subscription or collection changes are sent back.
struct RemoteAlbumsView: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    var source: MusicSource
    @State private var albums: [RemoteMusicAlbum] = []
    @State private var isLoading = false
    @State private var message: String?
    @State private var refreshID = UUID()
    @State private var operationID = UUID()
    @State private var importing: String?
    @State private var importTask: Task<Void, Never>?
    @State private var receipts: [String: Int] = [:]
    private var state: ConnectedMusicState { model.accounts.state(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeading(title: L10n.string("导入收藏专辑"), subtitle: source.title) {
                cancelImport(); dismiss()
            }
            HStack {
                Text(L10n.string("\(albums.count) 张专辑")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                Spacer()
                if isLoading || importing != nil { ProgressView().controlSize(.small) }
                if importing != nil {
                    Button(L10n.string("取消")) { cancelImport() }.buttonStyle(QuietButtonStyle())
                }
                Button(L10n.string("刷新")) { refreshID = UUID() }.buttonStyle(QuietButtonStyle())
                    .disabled(isLoading || importing != nil || state.busy || state.profile == nil)
            }
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("album-import-error")
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(albums) { album in
                        HStack(spacing: 14) {
                            AlbumImportArtwork(url: album.artworkURL)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(album.name).font(.system(size: 12)).lineLimit(2)
                                if !album.artist.isEmpty {
                                    Text(album.artist).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                                }
                                if let count = receipts[album.id] {
                                    Text(L10n.string("已导入 \(count) 首歌曲")).font(.system(size: 10)).foregroundStyle(palette.accent)
                                } else if let count = album.trackCount {
                                    Text(L10n.string("\(count) 首歌曲")).font(.system(size: 10)).foregroundStyle(palette.secondary)
                                }
                            }
                            Spacer()
                            if importing == album.id { ProgressView().controlSize(.mini) }
                            Button(receipts[album.id] == nil ? L10n.string("导入") : L10n.string("再次导入")) { startImport(album) }
                                .buttonStyle(QuietButtonStyle())
                                .disabled(importing != nil || isLoading || state.busy || state.profile == nil)
                                .accessibilityLabel(L10n.string("导入专辑 \(album.name)"))
                        }.padding(14).background(palette.accent.opacity(0.035), in: .rect(cornerRadius: 8))
                    }
                    if !isLoading && albums.isEmpty && message == nil {
                        Text(L10n.string("当前账号没有可读取的收藏专辑"))
                            .font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.vertical, 30)
                    }
                }
            }.frame(minHeight: 200, maxHeight: 380)
        }.padding(28).frame(width: 590).background(palette.panel).foregroundStyle(palette.text)
        .task(id: refreshID) { await loadAlbums() }
        .onChange(of: state.profile?.id) { _, _ in resetAccount() }
        .onChange(of: state.busy) { _, _ in resetAccount() }
        .onChange(of: source) { _, _ in resetAccount() }
        .onDisappear { cancelImport() }
    }

    private func resetAccount() {
        cancelImport(); albums = []; receipts = [:]; message = nil; refreshID = UUID()
    }
    private func cancelImport() {
        operationID = UUID(); importTask?.cancel(); importTask = nil; importing = nil
    }
    @MainActor private func loadAlbums() async {
        let requestID = refreshID
        guard state.profile != nil, !state.busy else { isLoading = false; return }
        isLoading = true; message = nil
        defer { if refreshID == requestID { isLoading = false } }
        do {
            let result = try await model.accounts.client.albums(source)
            try Task.checkCancellation()
            guard requestID == refreshID else { return }
            albums = result
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, requestID == refreshID else { return }
            message = PlaybackErrorMessage.describe(error, source: source, fallback: L10n.string("专辑读取失败，请重试。"))
        }
    }
    @MainActor private func startImport(_ album: RemoteMusicAlbum) {
        guard importing == nil, !state.busy, state.profile != nil else { return }
        let operation = UUID(); operationID = operation; importing = album.id; message = nil
        importTask = Task { @MainActor in
            defer { if operationID == operation { importing = nil; importTask = nil } }
            do {
                await model.library.load()
                let scope = try await model.accounts.client.libraryScope(for: source)
                let tracks = try await model.accounts.client.tracks(in: album)
                try Task.checkCancellation()
                try await model.accounts.client.validateLibraryScope(scope)
                guard operationID == operation, !state.busy else { throw CancellationError() }
                let count = try await model.library.importRemoteAlbumAndSave(album, tracks: tracks)
                guard operationID == operation, !Task.isCancelled else { return }
                receipts[album.id] = count
                model.notify(L10n.string("已导入「\(album.name)」：\(count) 首歌曲"))
            } catch is CancellationError {
                if operationID == operation, !Task.isCancelled { message = L10n.string("账号连接已变化，请确认当前账号后重试。") }
            } catch {
                guard operationID == operation, !Task.isCancelled else { return }
                message = L10n.string("「\(album.name)」导入失败：\(PlaybackErrorMessage.describe(error, source: source, fallback: L10n.string("专辑读取失败，请重试。")))")
            }
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
