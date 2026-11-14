import SwiftUI

/// What the panel beside the Now page shows.
enum NowPanelContent: Equatable {
    case queue
    case list(BrowseCollection)

    /// The queue while it is open, else the list the listener opened.
    @MainActor static func current(_ model: AppModel) -> NowPanelContent? {
        if model.queueOpen { return .queue }
        return model.browse.opened.map { .list($0) }
    }
}

/// The panel at the page's right edge: an opened chart or playlist, or the
/// queue. It docks beside the page where there is room and floats over it
/// where there is not.
struct NowSidePanel: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.nowMotion) private var motion
    let model: AppModel
    let content: NowPanelContent?
    /// How much of the panel is in view, and how far it floats over the page.
    let shown: CGFloat
    let floating: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            palette.panel
            switch content {
            case .queue:
                // The queue's own heading starts under the strip that drags the window.
                QueueView(model: model).padding(.top, NowLayout.stripHeight - 8)
                    .transition(.opacity)
            case .list(let collection):
                NowListPanel(model: model, collection: collection)
                    .id(collection.id)
                    .transition(.opacity)
            case nil:
                EmptyView()
            }
        }
        .animation(motion.panel, value: content)
        .overlay(alignment: .leading) { Rectangle().fill(palette.line).frame(width: 1) }
        .compositingGroup()
        .shadow(color: Color(red: 0.055, green: 0.07, blue: 0.1).opacity(0.28 * Double(floating * shown)), radius: 20, x: -18, y: 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("打开的列表"))
        .accessibilityIdentifier("now-panel")
    }
}

/// An opened list: what it is, a button that plays all of it, its first
/// songs and a way to see the rest.
private struct NowListPanel: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.nowMotion) private var motion
    let model: AppModel
    let collection: BrowseCollection
    @State private var showsAll = false
    private static let shownRows = 10

    var body: some View {
        let store = model.browse
        let state = store.tracksState(for: collection)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                ArtworkView(track: collection.coverTrack, radius: 8, highResolution: true).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 0) {
                    Eyebrow(text: kindTitle).textCase(.uppercase).lineLimit(1)
                    Text(collection.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.text).lineLimit(1).padding(.top, 5)
                    Text(detail(state)).font(.system(size: 10.5)).foregroundStyle(palette.secondary).lineLimit(1).padding(.top, 4)
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ToolButton(symbol: "xmark", label: L10n.string("收起列表")) { store.close() }
                    .accessibilityIdentifier("now-panel-close")
            }
            // Pressing it while the songs load plays them once they arrive.
            Button { model.play(collection) } label: {
                Group {
                    if store.pendingPlay == collection.id {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small).tint(palette.onPrimary).scaleEffect(0.6).frame(width: 12, height: 12)
                            Text(L10n.string("播放全部"))
                        }
                    } else {
                        Label(L10n.string("播放全部"), systemImage: "play.fill")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(!playable(state)).opacity(playable(state) ? 1 : 0.5)
            .padding(.top, 16)
            .accessibilityIdentifier("now-browse-play-all")
            ScrollView {
                songs(state)
                    .animation(motion.panel, value: state)
                    .animation(motion.panel, value: showsAll)
            }
            .padding(.top, 12)
        }
        .padding(.top, 64).padding(.horizontal, 18).padding(.bottom, 18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-browse-collection")
    }

    @ViewBuilder private func songs(_ state: BrowseStore.TracksState?) -> some View {
        switch state {
        case .loaded(let tracks):
            if tracks.isEmpty {
                Text(L10n.string("这个列表暂时没有可显示的歌曲。")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array((showsAll ? tracks : Array(tracks.prefix(Self.shownRows))).enumerated()), id: \.element.id) { index, track in
                        NowPanelRow(model: model, track: track, index: index, queue: tracks)
                    }
                    if tracks.count > Self.shownRows {
                        NowLink(title: showsAll ? L10n.string("只显示前 \(Self.shownRows) 首") : L10n.string("显示全部 \(tracks.count) 首"), size: 11) {
                            showsAll.toggle()
                        }
                        .padding(.top, 12)
                    }
                }
                .transition(.opacity)
            }
        case .failed(let message):
            PlatformImportErrorLine(message: L10n.string("读取歌曲失败：\(message)"), retryLabel: L10n.string("重试")) {
                model.browse.reloadTracks(collection)
            }
            .foregroundStyle(.orange).padding(.top, 8)
        case .loading, nil:
            // As tall as the rows that replace it.
            NowPanelSkeletons(count: max(1, min(collection.trackCount ?? Self.shownRows, Self.shownRows)))
                .transition(.opacity)
        }
    }

    private var kindTitle: String {
        if collection.isSongList { return collection.source.title }
        return switch collection.kind {
        case .chart: L10n.string("榜单")
        case .playlist: L10n.string("歌单")
        case .album: L10n.string("专辑")
        }
    }
    private func detail(_ state: BrowseStore.TracksState?) -> String {
        let count: Int? = if case .loaded(let tracks) = state { tracks.count } else { collection.trackCount }
        let parts = [collection.detail.isEmpty ? collection.caption : collection.detail, count.map { L10n.string("\($0) 首歌") } ?? ""].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }
    /// Off only once the songs are known and none can play.
    private func playable(_ state: BrowseStore.TracksState?) -> Bool {
        if case .loaded(let tracks) = state { return tracks.contains { !$0.unavailable } }
        return true
    }
}

/// One song of an opened list: its place, cover, name and length.
private struct NowPanelRow: View {
    @Environment(\.appPalette) private var palette
    let model: AppModel
    let track: Track
    let index: Int
    let queue: [Track]
    @State private var hovered = false

    var body: some View {
        let current = model.player.current?.id == track.id
        Button { model.play(track, context: queue) } label: {
            HStack(spacing: 10) {
                Group {
                    if current && model.player.status == .playing { Image(systemName: "waveform").font(.system(size: 9)) }
                    else if hovered && !track.unavailable { Image(systemName: "play.fill").font(.system(size: 8)) }
                    else { Text(String(format: "%02d", index + 1)).font(.system(size: 9, design: .monospaced)) }
                }
                .foregroundStyle(current ? palette.accent : palette.secondary).frame(width: 16, alignment: .leading)
                ArtworkView(track: track, radius: 6).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: track.title).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(current ? palette.accent : palette.text).lineLimit(1)
                    Text(verbatim: track.unavailable ? L10n.string("\(track.artist) · 当前不可播放") : track.artist)
                        .font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(track.duration > 0 ? formattedTime(track.duration) : "—").font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(palette.secondary)
            }
            .frame(height: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(track.unavailable).opacity(track.unavailable ? 0.55 : 1)
        .background(hovered ? palette.hover : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.text.opacity(0.07)).frame(height: 1) }
        .onHover { hovered = $0 }
        .contextMenu {
            if !model.isLibraryTrack(track) {
                Button(L10n.string("添加到音乐库"), systemImage: "plus") { model.addToLibrary(track) }
            }
            TrackActions(track: track, model: model)
        }
        .accessibilityLabel(L10n.string("播放 \(track.title)，\(track.artist)"))
    }
}

/// The panel's rows while a list's songs load.
private struct NowPanelSkeletons: View {
    @Environment(\.appPalette) private var palette
    let count: Int
    private static let widths: [CGFloat] = [150, 110, 170, 128, 160]
    var body: some View {
        NowPulse { phase in
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    let tint = palette.accent.opacity(0.05 + 0.07 * phase(index))
                    HStack(spacing: 10) {
                        Capsule().fill(tint).frame(width: 12, height: 6).frame(width: 16, alignment: .leading)
                        RoundedRectangle(cornerRadius: 6).fill(tint).frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 7) {
                            Capsule().fill(tint).frame(width: Self.widths[index % Self.widths.count], height: 9)
                            Capsule().fill(tint.opacity(0.7)).frame(width: 70, height: 7)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 52)
                    .overlay(alignment: .bottom) { Rectangle().fill(palette.text.opacity(0.07)).frame(height: 1) }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.string("正在读取歌曲"))
    }
}
