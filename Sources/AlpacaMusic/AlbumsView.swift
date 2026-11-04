import SwiftUI

struct AlbumsView: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: AppModel

    var body: some View {
        let albums = model.visibleAlbums
        VStack(alignment: .leading, spacing: 25) {
            HStack {
                VStack(alignment: .leading, spacing: 11) {
                    Text(L10n.string("专辑库")).font(.system(size: 29, weight: .regular)).tracking(1)
                        .foregroundStyle(palette.text)
                    Text(L10n.string("\(albums.count) 张专辑")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 12)
                Button { model.navigate(.sources) } label: {
                    Label(L10n.string("管理音源"), systemImage: "antenna.radiowaves.left.and.right")
                }.buttonStyle(QuietButtonStyle())
            }
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    sourceFilter(L10n.string("全部"), source: nil)
                    ForEach(MusicSource.allCases.filter(MusicSourceAvailability.isVisible), id: \.self) { source in
                        sourceFilter(source.title, source: source)
                    }
                }
            }.scrollIndicators(.hidden)

            if albums.isEmpty {
                EmptyState(symbol: "square.stack", title: emptyTitle, actionTitle: L10n.string("管理音源")) {
                    model.navigate(.sources)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 164, maximum: 230), spacing: 22, alignment: .top)],
                          alignment: .leading, spacing: 28) {
                    ForEach(albums) { album in
                        AlbumCard(album: album, track: coverTrack(for: album)) { model.navigate(.album(album.id)) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("albums-content")
        .animation(reduceMotion || model.visual.reduceMotion ? nil : ExperienceMotion.control, value: model.sourceFilter)
    }

    private var emptyTitle: String {
        if !model.searchTerm.isEmpty { return L10n.string("没有找到专辑") }
        if model.sourceFilter != nil { return L10n.string("没有符合筛选条件的专辑") }
        return L10n.string("还没有专辑")
    }

    private func coverTrack(for album: MusicAlbum) -> Track? {
        let ids = album.artworkURL == nil ? album.trackIDs : Array(album.trackIDs.prefix(1))
        return AlbumCover.representativeTrack(for: album, in: model.library.tracks(withIDs: ids))
    }

    private func sourceFilter(_ title: String, source: MusicSource?) -> some View {
        Button { model.sourceFilter = source } label: {
            Text(title).font(.system(size: 10))
                .foregroundStyle(model.sourceFilter == source ? palette.accent : palette.secondary)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(model.sourceFilter == source ? palette.accent.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
        }.buttonStyle(.plain)
            .accessibilityAddTraits(model.sourceFilter == source ? .isSelected : [])
    }
}

private struct AlbumCard: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let album: MusicAlbum
    let track: Track?
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 11) {
                AlbumCover(album: album, track: track)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(hovered ? palette.accent.opacity(0.45) : palette.line) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(album.name).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.text)
                        .lineLimit(2).frame(height: 34, alignment: .topLeading)
                    Text(album.artist).font(.system(size: 11)).foregroundStyle(palette.secondary)
                        .lineLimit(1).frame(minHeight: 14).accessibilityHidden(album.artist.isEmpty)
                    HStack(spacing: 6) {
                        SourceBadge(source: album.source)
                        Spacer(minLength: 0)
                        Text(L10n.string("\(album.trackIDs.count) 首歌曲")).font(.system(size: 10)).foregroundStyle(palette.faint)
                            .lineLimit(1)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : ExperienceMotion.control, value: hovered)
        .accessibilityLabel(L10n.string("打开专辑 \(album.name)"))
        .accessibilityValue([album.artist, album.source.title, L10n.string("\(album.trackIDs.count) 首歌曲")].filter { !$0.isEmpty }.joined(separator: " · "))
        .accessibilityIdentifier("album-card-\(album.id)")
    }
}

struct AlbumDetailView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Button { model.navigate(.albums) } label: {
                Label(L10n.string("返回专辑"), systemImage: "chevron.left")
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
                    .padding(.vertical, 5).contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("album-back")
            if let album = model.selectedAlbum {
                let tracks = model.albumTracks
                let coverTrack = AlbumCover.representativeTrack(for: album, in: tracks)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 26) {
                        AlbumCover(album: album, track: coverTrack).frame(width: 208, height: 208)
                        albumInformation(album, tracks: tracks).frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        AlbumCover(album: album, track: coverTrack).frame(width: 180, height: 180)
                        albumInformation(album, tracks: tracks)
                    }
                }
                if tracks.isEmpty {
                    EmptyState(symbol: "music.note", title: L10n.string("专辑暂无歌曲"), actionTitle: L10n.string("管理音源")) {
                        model.navigate(.sources)
                    }
                } else {
                    TrackList(model: model, tracks: tracks)
                }
            } else {
                EmptyState(symbol: "square.stack", title: L10n.string("专辑不存在"), actionTitle: L10n.string("返回专辑")) {
                    model.navigate(.albums)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("album-detail-content")
    }

    private func albumInformation(_ album: MusicAlbum, tracks: [Track]) -> some View {
        let duration = tracks.reduce(0.0) { $0 + ($1.duration.isFinite && $1.duration > 0 ? $1.duration : 0) }
        let canPlay = tracks.contains { !$0.unavailable }
        return VStack(alignment: .leading, spacing: 15) {
            SourceBadge(source: album.source)
            Text(album.name).font(.system(size: 29, weight: .regular)).foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !album.artist.isEmpty {
                Text(album.artist).font(.system(size: 14)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 15) {
                Text(L10n.string("\(tracks.count) 首歌曲"))
                if duration > 0, duration.isFinite, duration < Double(Int.max) {
                    Label(formattedTime(duration), systemImage: "clock")
                        .accessibilityLabel(L10n.string("总时长 \(formattedTime(duration))"))
                }
            }.font(.system(size: 11)).foregroundStyle(palette.secondary)
            Button { Task { await model.playAlbum() } } label: {
                Label(L10n.string("播放专辑"), systemImage: "play.fill")
            }.buttonStyle(PrimaryButtonStyle()).disabled(!canPlay).opacity(canPlay ? 1 : 0.45)
                .accessibilityLabel(L10n.string("播放专辑 \(album.name)"))
                .accessibilityIdentifier("album-play")
                .padding(.top, 4)
        }
    }
}

private struct AlbumCover: View {
    @Environment(\.appPalette) private var palette
    let album: MusicAlbum
    let track: Track?

    static func representativeTrack(for album: MusicAlbum, in tracks: [Track]) -> Track? {
        if album.artworkURL != nil { return tracks.first }
        return tracks.first { $0.artworkData?.isEmpty == false || $0.artworkURL != nil } ?? tracks.first
    }

    private var artworkTrack: Track? {
        guard var track else { return nil }
        track.title = album.name
        if !album.artist.isEmpty { track.artist = album.artist }
        if let url = album.artworkURL {
            track.artworkURL = url
            track.artworkData = nil
        }
        return track
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let artworkTrack {
                    ArtworkView(track: artworkTrack, radius: 9, highResolution: true)
                } else {
                    AsyncImage(url: album.artworkURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        ZStack {
                            LinearGradient(colors: [palette.raised, palette.panel], startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: "opticaldisc").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(palette.accent.opacity(0.4))
                        }
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .clipped().clipShape(.rect(cornerRadius: 9))
        }.accessibilityHidden(true)
    }
}
