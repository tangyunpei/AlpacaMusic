import SwiftUI

struct SodaShareImportView: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var candidate: SodaShareImport?
    @State private var busy = false
    /// True while `busy` belongs to saving rather than reading the link.
    @State private var saving = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    private var motion: Animation? { systemReduced || appReduced ? nil : ExperienceMotion.panel }
    private var panelTransition: AnyTransition {
        systemReduced || appReduced ? AnyTransition.opacity : AnyTransition.move(edge: .top).combined(with: .opacity)
    }
    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeading(title: L10n.string("导入汽水音乐")) { close() }
            addressRow
            if busy {
                progressPanel.transition(panelTransition)
            }
            if let candidate {
                candidateSection(candidate).transition(AnyTransition.opacity)
            }
            if let error {
                PlatformImportErrorLine(message: error, retryLabel: L10n.string("重试"), retryDisabled: busy,
                                        retry: { retry() })
                    .accessibilityIdentifier("soda-share-error")
                    .transition(AnyTransition.opacity)
            }
            HStack {
                Spacer()
                Button(L10n.string("取消")) { close() }.buttonStyle(QuietButtonStyle())
                Button(L10n.string("导入音乐库")) { save() }
                    .buttonStyle(PrimaryButtonStyle()).disabled(busy || candidate == nil)
                    .accessibilityIdentifier("soda-share-save")
            }
        }.padding(28).frame(width: 550).background(palette.panel).foregroundStyle(palette.text)
            .animation(motion, value: busy)
            .animation(motion, value: candidate == nil)
            .animation(motion, value: error)
            .onDisappear { cancel() }
    }

    private var addressRow: some View {
        HStack(spacing: 8) {
            TextField(L10n.string("粘贴歌曲或歌单的分享链接"), text: $address)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
                .accessibilityLabel(L10n.string("汽水音乐分享链接")).accessibilityIdentifier("soda-share-address")
                .disabled(busy).onSubmit { readShare() }
                .onChange(of: address) { _, _ in candidate = nil; error = nil }
            InfoHint(text: L10n.string("支持汽水音乐复制的分享文字或官方链接。"))
            Button(L10n.string("解析链接")) { readShare() }
                .buttonStyle(QuietButtonStyle()).disabled(busy || trimmedAddress.isEmpty)
                .accessibilityIdentifier("soda-share-read")
        }
    }

    @ViewBuilder private var progressPanel: some View {
        if saving, let candidate {
            // No cancel while saving: the library has already changed by then.
            ImportProgressPanel(title: L10n.string("正在保存 \(candidate.tracks.count) 首歌曲…"),
                                symbol: "tray.and.arrow.down")
        } else {
            ImportProgressPanel(title: L10n.string("正在解析链接…"), symbol: "link", onCancel: { cancel() })
        }
    }

    private func candidateSection(_ candidate: SodaShareImport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(candidate.playlistName ?? candidate.tracks.first?.title ?? L10n.string("歌曲"))
                    .font(.system(size: 18, weight: .medium)).lineLimit(1).truncationMode(.tail)
                if candidate.playlistName != nil {
                    Text(L10n.string("\(candidate.tracks.count) 首歌曲")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                InfoHint(text: L10n.string("导入保存歌曲资料，播放地址会在播放时重新获取。"))
                Spacer(minLength: 0)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(candidate.tracks) { track in
                        trackRow(track)
                    }
                }
            }.frame(maxHeight: 240)
        }
    }

    private func trackRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            ArtworkView(track: track, radius: 6).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(track.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(track.artist).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                if let range = track.sodaPlayback, range.isPreview {
                    Text(L10n.string("试听 \(formattedTime(range.duration)) · 原曲 \(formattedTime(range.start))–\(formattedTime(range.start + range.duration))"))
                        .font(.system(size: 10)).foregroundStyle(palette.accent)
                }
            }
            Spacer()
        }
    }

    private func cancel() {
        generation = UUID(); task?.cancel(); task = nil; busy = false; saving = false
    }
    private func close() { cancel(); dismiss() }
    private func retry() {
        if candidate != nil { save() } else { readShare() }
    }
    private func readShare() {
        guard !busy else { return }
        let input = address, token = UUID()
        generation = token; busy = true; saving = false; error = nil; candidate = nil
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
        let token = UUID(); generation = token; busy = true; saving = true; error = nil
        task = Task { @MainActor in
            defer { if generation == token { busy = false; saving = false; task = nil } }
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
                model.notify(L10n.string("已导入 \(candidate.tracks.count) 首汽水音乐"))
                dismiss()
            } catch is CancellationError { }
            catch { if generation == token { self.error = error.localizedDescription } }
        }
    }
}

extension Track {
    var sourcePlaybackTitle: String {
        source.title + (source == .soda && sodaPlayback?.isPreview == true ? L10n.string(" · 试听") : "")
    }
}
