import SwiftUI

struct SodaShareImportView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var candidate: SodaShareImport?
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeading(title: "导入汽水音乐") { close() }
            TextField("粘贴歌曲或歌单的分享链接", text: $address)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
                .accessibilityLabel("汽水音乐分享链接").accessibilityIdentifier("soda-share-address")
                .disabled(busy).onSubmit { readShare() }
                .onChange(of: address) { _, _ in candidate = nil; error = nil }
            HStack {
                Text("支持汽水音乐复制的分享文字或官方链接。")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("解析链接") { readShare() }
                    .buttonStyle(QuietButtonStyle()).disabled(busy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("soda-share-read")
            }
            if let candidate {
                Text(candidate.playlistName ?? candidate.tracks.first?.title ?? "歌曲")
                    .font(.system(size: 18, weight: .medium))
                if candidate.playlistName != nil {
                    Text("\(candidate.tracks.count) 首歌曲 · 播放时检查可用片段")
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(candidate.tracks) { track in
                            HStack(spacing: 12) {
                                ArtworkView(track: track, radius: 6).frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(track.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(track.artist).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                                    if let range = track.sodaPlayback, range.isPreview {
                                        Text("试听 \(formattedTime(range.duration)) · 原曲 \(formattedTime(range.start))–\(formattedTime(range.start + range.duration))")
                                            .font(.system(size: 10)).foregroundStyle(palette.accent)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                }.frame(maxHeight: 240)
                Text("导入保存歌曲资料，播放地址会在播放时重新获取。")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("soda-share-error")
            }
            HStack {
                Spacer()
                Button("取消") { close() }.buttonStyle(QuietButtonStyle())
                Button("导入音乐库") { save() }
                    .buttonStyle(PrimaryButtonStyle()).disabled(busy || candidate == nil)
                    .accessibilityIdentifier("soda-share-save")
            }
        }.padding(28).frame(width: 550).background(palette.panel).foregroundStyle(palette.text)
            .onDisappear { cancel() }
    }

    private func cancel() {
        generation = UUID(); task?.cancel(); task = nil; busy = false
    }
    private func close() { cancel(); dismiss() }
    private func readShare() {
        guard !busy else { return }
        let input = address, token = UUID()
        generation = token; busy = true; error = nil; candidate = nil
        task = Task { @MainActor in
            defer { if generation == token { busy = false; task = nil } }
            do {
                let value = try await SodaShareClient().importShare(input)
                try Task.checkCancellation()
                guard generation == token else { return }
                candidate = value
            } catch is CancellationError { }
            catch { if generation == token { self.error = error.localizedDescription } }
        }
    }
    private func save() {
        guard !busy, let candidate else { return }
        let token = UUID(); generation = token; busy = true; error = nil
        task = Task { @MainActor in
            defer { if generation == token { busy = false; task = nil } }
            do {
                if let id = candidate.playlistID, let name = candidate.playlistName {
                    let remote = RemoteMusicPlaylist(id: id, name: name, trackCount: candidate.tracks.count, source: .soda)
                    let saved = try await model.library.importRemotePlaylistAndSave(remote, accountID: "public-share", tracks: candidate.tracks)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    model.navigate(.playlist(saved.id))
                } else {
                    _ = try await model.library.importSodaSongsAndSave(candidate.tracks)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    model.navigate(.library); model.sourceFilter = .soda
                }
                model.notify("已导入 \(candidate.tracks.count) 首汽水音乐")
                dismiss()
            } catch is CancellationError { }
            catch { if generation == token { self.error = error.localizedDescription } }
        }
    }
}

extension Track {
    var sourcePlaybackTitle: String {
        source.title + (source == .soda && sodaPlayback?.isPreview == true ? " · 试听" : "")
    }
}
