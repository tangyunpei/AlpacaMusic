import SwiftUI

/// Lately: the listener's own library. A tile for the songs they liked, then
/// what they added most recently.
struct NowLatelySection: View {
    let model: AppModel
    let metrics: NowRowMetrics

    /// A tile, the gap under it and its two lines of text.
    static let rowHeight: CGFloat = 172

    var body: some View {
        NowSectionFrame(title: L10n.string("最近"), eyebrow: L10n.string("你的音乐库").uppercased(), metrics: metrics,
                        padding: NowLayout.latelyPadding, rowHeight: Self.rowHeight) {
            NowLink(title: L10n.string("打开音乐库")) { model.navigate(.library) }.padding(.top, 20)
        } headExtras: {
            NowLink(title: L10n.string("打开音乐库"), size: 11) { model.navigate(.library) }
        } row: {
            ScrollView(.horizontal) {
                NowLatelyTiles(model: model)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("now-lately")
    }
}

/// The tiles depend on the library alone, so a change of layout leaves them be.
private struct NowLatelyTiles: View {
    @Environment(\.appPalette) private var palette
    let model: AppModel
    private static let shown = 24

    var body: some View {
        let library = model.library
        let recent = Self.recent(library.tracks)
        LazyHStack(alignment: .top, spacing: NowLayout.cardGap) {
            NowFavoritesTile(model: model)
            if !library.ready {
                ForEach(0..<5, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 10).fill(palette.accent.opacity(0.06)).frame(width: NowLayout.tileWidth, height: NowLayout.tileWidth)
                        Capsule().fill(palette.accent.opacity(0.06)).frame(width: 84, height: 9)
                    }
                }
                .accessibilityLabel(L10n.string("正在加载音乐…"))
            } else if recent.isEmpty {
                NowImportTile(model: model)
            } else {
                ForEach(recent) { track in NowRecentTile(model: model, track: track, queue: recent) }
            }
        }
    }

    /// The newest songs first. Songs that came with the app carry no date and fall to the end.
    private static func recent(_ tracks: [Track]) -> [Track] {
        Array(tracks.enumerated().sorted { first, second in
            first.element.addedAt == second.element.addedAt ? first.offset > second.offset : first.element.addedAt > second.element.addedAt
        }.prefix(shown).map(\.element))
    }
}

private struct NowFavoritesTile: View {
    @Environment(\.appPalette) private var palette
    let model: AppModel
    @State private var hovered = false

    var body: some View {
        let library = model.library
        let count = library.favorites.count
        VStack(alignment: .leading, spacing: 0) {
            Button { model.navigate(.favorites) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: "heart.fill").font(.system(size: 17)).foregroundStyle(palette.primary)
                    Spacer(minLength: 0)
                    Text(L10n.string("\(count) 首歌")).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2)
                        .textCase(.uppercase).foregroundStyle(palette.background).lineLimit(1)
                        .frame(height: 30, alignment: .bottomLeading).padding(.bottom, 2)
                        .contentTransition(.numericText())
                }
                .padding(12)
                .frame(width: NowLayout.tileWidth, height: NowLayout.tileWidth, alignment: .topLeading)
                .background(palette.text.opacity(hovered ? 0.9 : 1), in: .rect(cornerRadius: 10))
                .contentShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("喜欢的音乐"))
            .accessibilityValue(L10n.string("\(count) 首歌"))
            .overlay(alignment: .bottomTrailing) {
                Button { play() } label: {
                    Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(palette.text)
                        .frame(width: 30, height: 30).background(palette.background, in: .circle).contentShape(.circle)
                }
                .buttonStyle(.plain).disabled(count == 0).opacity(count == 0 ? 0.45 : 1)
                .padding(12)
                .help(L10n.string("播放喜欢的音乐")).accessibilityLabel(L10n.string("播放喜欢的音乐"))
            }
            Text(L10n.string("喜欢的音乐")).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text).lineLimit(1).padding(.top, 8)
            Text(L10n.string("你点过喜欢的歌曲")).font(.system(size: 10.5)).foregroundStyle(palette.secondary).lineLimit(1).padding(.top, 3)
        }
        .frame(width: NowLayout.tileWidth, alignment: .leading)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-favorites")
    }

    private func play() {
        let library = model.library
        let tracks = library.tracks.filter { library.favorites.contains($0.id) }
        guard let first = tracks.first(where: { !$0.unavailable }) else { return }
        model.play(first, context: tracks)
    }
}

private struct NowRecentTile: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.nowMotion) private var motion
    let model: AppModel
    let track: Track
    let queue: [Track]
    @State private var hovered = false

    var body: some View {
        let current = model.player.current?.id == track.id
        Button { model.play(track, context: queue) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ArtworkView(track: track, radius: 10, highResolution: true)
                    .frame(width: NowLayout.tileWidth, height: NowLayout.tileWidth)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: current && model.player.status == .playing ? "waveform" : "play.fill").font(.system(size: 11))
                            .frame(width: 30, height: 30).foregroundStyle(palette.onPrimary).background(palette.primary, in: .circle)
                            .padding(8).opacity(hovered || current ? 1 : 0)
                    }
                Text(verbatim: track.title).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(current ? palette.accent : palette.text).lineLimit(1).padding(.top, 8)
                Text(verbatim: track.unavailable ? L10n.string("\(track.artist) · 当前不可播放") : track.artist)
                    .font(.system(size: 10.5)).foregroundStyle(palette.secondary).lineLimit(1).padding(.top, 3)
            }
            .frame(width: NowLayout.tileWidth, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(track.unavailable).opacity(track.unavailable ? 0.55 : 1)
        .onHover { hovered = $0 }
        .animation(motion.control, value: hovered)
        .contextMenu { TrackActions(track: track, model: model) }
        .accessibilityLabel(L10n.string("播放 \(track.title)，\(track.artist)"))
    }
}

/// Offered in place of recent songs while the library is empty.
private struct NowImportTile: View {
    @Environment(\.appPalette) private var palette
    let model: AppModel
    var body: some View {
        Button { model.beginImport(folder: false) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "plus").font(.system(size: 22, weight: .light)).foregroundStyle(palette.accent)
                    .frame(width: NowLayout.tileWidth, height: NowLayout.tileWidth)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                Text(L10n.string("导入音乐")).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text).lineLimit(1).padding(.top, 8)
                Text(L10n.string("音乐库为空")).font(.system(size: 10.5)).foregroundStyle(palette.secondary).lineLimit(1).padding(.top, 3)
            }
            .frame(width: NowLayout.tileWidth, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(model.library.busy)
        .accessibilityIdentifier("now-import-tile")
    }
}
