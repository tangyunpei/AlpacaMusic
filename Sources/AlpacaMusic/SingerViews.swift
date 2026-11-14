import SwiftUI

// MARK: Album tiles

/// One service's copy of an album: its cover with the service's mark, its
/// name and date. A click opens its page.
struct AlbumTile: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var album: SingerAlbum
    var size: CGFloat
    /// A short window shows the year alone under a small cover.
    var compact = false
    @State private var hovered = false

    var body: some View {
        Button { model.openAlbum(album) } label: {
            VStack(alignment: compact ? .center : .leading, spacing: compact ? 3 : 6) {
                ArtworkView(track: Track(id: "album:\(album.id)", title: album.name, artist: album.artist, album: album.name, duration: 0,
                                         source: album.source, artworkURL: album.artworkURL), radius: compact ? 6 : 7)
                    .frame(width: size, height: size)
                    .overlay { RoundedRectangle(cornerRadius: compact ? 6 : 7).strokeBorder(hovered ? palette.accent.opacity(0.45) : palette.line) }
                    .overlay(alignment: .bottomTrailing) {
                        PlatformMark(source: album.source, size: compact ? 12 : 14)
                            .frame(width: compact ? 19 : 22, height: compact ? 19 : 22)
                            .background(palette.background, in: .rect(cornerRadius: compact ? 5 : 6))
                            .overlay(RoundedRectangle(cornerRadius: compact ? 5 : 6).strokeBorder(palette.line))
                            .padding(compact ? 3 : 5)
                    }
                if compact {
                    Text(verbatim: album.date.map { String($0.year) } ?? "—").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(palette.secondary)
                } else {
                    Text(verbatim: album.name).font(.system(size: size > 110 ? 13 : 11, weight: .medium)).foregroundStyle(palette.text)
                        .lineLimit(2).multilineTextAlignment(.leading).frame(width: size, alignment: .leading)
                    Text(verbatim: album.date?.shortText ?? L10n.string("无日期")).font(.system(size: size > 110 ? 10 : 9).monospacedDigit())
                        .foregroundStyle(palette.secondary).lineLimit(1)
                }
            }
            .frame(width: size, alignment: compact ? .center : .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(L10n.string("打开专辑 \(album.name)"))
        .accessibilityLabel(L10n.string("打开专辑 \(album.name)"))
        .accessibilityValue([album.source.title, album.date?.shortText ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

struct AlbumSkeletons: View {
    @Environment(\.appPalette) private var palette
    var size: CGFloat
    var count: Int
    var body: some View {
        HStack(spacing: 16) {
            ForEach(0..<count, id: \.self) { _ in RoundedRectangle(cornerRadius: 7).fill(palette.panel.opacity(0.6)).frame(width: size, height: size) }
        }
        .accessibilityHidden(true)
    }
}

/// Spacing before each tile: copies of one album stand closer together.
private func tileGaps(_ albums: [SingerAlbum], same: CGFloat, other: CGFloat) -> [CGFloat] {
    albums.enumerated().map { index, album in
        index == 0 ? 0 : SearchList.fold(albums[index - 1].name) == SearchList.fold(album.name) ? same : other
    }
}

/// The counts beside "Newest albums": each service's mark and how many it listed.
private struct AlbumCounts: View {
    @Environment(\.appPalette) private var palette
    var singer: SingerStore
    var body: some View {
        HStack(spacing: 3) {
            ForEach(singer.profiles, id: \.source) { profile in
                PlatformMark(source: profile.source, size: 14)
                switch singer.albumLoads[profile.source] {
                case .failed?: Text(L10n.string("失败")).foregroundStyle(Color.orange).padding(.trailing, 6)
                case .loading?: ImportStatusGlyph(state: .working(nil), size: 8).padding(.trailing, 6)
                default:
                    let more = singer.albumLoads[profile.source]?.more == true
                    Text(verbatim: "\(singer.albumCount(profile.source))" + (more ? "+" : "")).padding(.trailing, 6)
                }
            }
        }
        .font(.system(size: 10).monospacedDigit()).foregroundStyle(palette.faint).lineLimit(1)
    }
}

/// The singer's newest albums in a row beside the card, or under a compact one.
struct AlbumStrip: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var singer: SingerStore
    var compact: Bool

    var body: some View {
        let albums = singer.albums
        VStack(alignment: .leading, spacing: compact ? 4 : 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L10n.string("最新专辑")).font(.system(size: compact ? 10 : 12, weight: .medium)).foregroundStyle(palette.text)
                if !compact { AlbumCounts(singer: singer) }
                Spacer(minLength: 0)
                Button(compact ? L10n.string("全部 ›") : L10n.string("全部专辑 ›")) { model.openSinger(singer) }
                    .buttonStyle(.plain).font(.system(size: compact ? 10.5 : 11, weight: .medium)).foregroundStyle(palette.accent)
            }
            .frame(height: compact ? 13 : 16)
            if albums.isEmpty {
                if singer.finding || singer.loadingAlbums { AlbumSkeletons(size: compact ? 50 : 96, count: 8) }
                else {
                    Text(singer.profiles.isEmpty ? L10n.string("已连接的服务没有找到这位歌手。") : L10n.string("已连接的服务没有列出这位歌手的专辑。"))
                        .font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.top, compact ? 4 : 30)
                }
            } else {
                let gaps = tileGaps(albums, same: 6, other: compact ? 14 : 22)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                            AlbumTile(model: model, album: album, size: compact ? 50 : 96, compact: compact).padding(.leading, gaps[index])
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .mask { LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The singer's albums as a grid: beside a wide list, or on the singer page.
struct AlbumGrid: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var singer: SingerStore
    var width: CGFloat
    /// Rows shown before "Show all"; nil shows every album.
    var rows: Int?
    var minimumTile: CGFloat = 150
    /// The "Newest albums" line above the grid; the singer page has its own.
    var showsHeader = true

    var body: some View {
        let albums = singer.shownAlbums
        let columns = max(3, Int((width + 16) / (minimumTile + 16)))
        let tile = max(60, ((width - 16 * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down))
        let limit = rows.map { $0 * columns } ?? albums.count
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(L10n.string("最新专辑")).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text)
                    AlbumCounts(singer: singer)
                    Spacer(minLength: 0)
                    Button(L10n.string("全部专辑 ›")) { model.openSinger(singer) }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.accent)
                }
            }
            if albums.isEmpty, singer.finding || singer.loadingAlbums {
                AlbumSkeletons(size: tile, count: min(columns, 4))
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: 16, alignment: .top), count: columns), alignment: .leading, spacing: 20) {
                    ForEach(albums.prefix(limit)) { album in AlbumTile(model: model, album: album, size: tile) }
                }
            }
        }
    }
}

// MARK: The singer page

/// One long page for a singer, in the owner's order: the latest release, the
/// albums newest first, then the songs.
struct SingerPageView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var singer: SingerStore
    @State private var width: CGFloat = 900
    @State private var allAlbums = false

    var body: some View {
        let metrics = SearchLayout.metrics(width: width + 2 * SearchLayout.sidePadding,
                                           blend: SearchLayout.choice(for: SearchLayoutInput(width: width + 2 * SearchLayout.sidePadding, height: 900, songsOnly: true)).blend)
        let rows = singer.shownSongs
        let queue = rows.map(\.track)
        VStack(alignment: .leading, spacing: 26) {
            header(queue: queue)
            pills
            if let latest = singer.latest { latestRelease(latest) }
            albumsSection
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(L10n.string("歌曲")).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text)
                    Text(songsCaption).font(.system(size: 10)).foregroundStyle(palette.faint)
                }
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        SearchSongRow(model: model, row: row, index: index, queue: queue, metrics: metrics)
                    }
                }
                if singer.loadingSongs { HStack(spacing: 8) { ImportStatusGlyph(state: .working(nil), size: 9); Text(L10n.string("正在加载更多歌曲…")) }
                    .font(.system(size: 10)).foregroundStyle(palette.faint).padding(.vertical, 18) }
                Color.clear.frame(height: 1)
                    .onScrollVisibilityChange(threshold: 0.1) { visible in if visible { singer.loadMoreSongs() } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task { singer.start() }
        .accessibilityIdentifier("singer-page")
    }

    private var songsCaption: String {
        singer.profiles.map { profile in
            profile.source == .appleMusic ? L10n.string("\(profile.source.title)：热门歌曲") : L10n.string("\(profile.source.title)：最常播放在前")
        }.joined(separator: " · ")
    }

    private func header(queue: [Track]) -> some View {
        HStack(alignment: .center, spacing: 20) {
            SingerAvatar(name: singer.names.first ?? "", size: 72, pictureURL: singer.pictureURL)
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: L10n.string("歌手"))
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: singer.names.first ?? "").font(.system(size: 29)).foregroundStyle(palette.text)
                    if singer.names.count > 1 { Text(verbatim: singer.names.dropFirst().joined(separator: " · ")).font(.system(size: 15)).foregroundStyle(palette.secondary) }
                }
                .lineLimit(1)
                HStack(spacing: 14) {
                    Button { if let first = queue.first(where: { !$0.unavailable }) { model.play(first, context: queue) } } label: {
                        Label(L10n.string("播放"), systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle()).disabled(queue.isEmpty)
                    ForEach(singer.profiles, id: \.source) { profile in
                        HStack(spacing: 5) { PlatformMark(source: profile.source, size: 14); Text(verbatim: profile.name) }
                            .font(.system(size: 10)).foregroundStyle(palette.secondary)
                    }
                    if singer.finding { ImportStatusGlyph(state: .working(nil), size: 9) }
                }
            }
        }
    }

    private var pills: some View {
        HStack(spacing: 6) {
            pill(L10n.string("全部"), count: "", source: nil)
            ForEach(singer.profiles, id: \.source) { profile in
                let count = singer.albumCount(profile.source)
                // "30+" while the service has more albums than the page read so far.
                let shown = "\(count)" + (singer.albumLoads[profile.source]?.more == true ? "+" : "")
                pill(profile.source.title, count: count > 0 ? L10n.string("\(shown) 张专辑") : L10n.string("仅歌曲"), source: profile.source)
            }
        }
    }

    private func pill(_ title: String, count: String, source: MusicSource?) -> some View {
        let selected = singer.filter == source
        return Button { singer.filter = source } label: {
            HStack(spacing: 6) {
                if let source { PlatformMark(source: source) }
                Text(title).foregroundStyle(selected ? palette.accent : palette.secondary)
                if !count.isEmpty { Text(count).font(.system(size: 10)).foregroundStyle(palette.faint) }
            }
            .font(.system(size: 11)).padding(.horizontal, 10).frame(height: 28)
            .background(selected ? palette.accent.opacity(0.08) : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func latestRelease(_ album: SingerAlbum) -> some View {
        let others = singer.profiles.filter { $0.source != album.source }.compactMap { profile in
            singer.albums.first { $0.source == profile.source }
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L10n.string("最新发行")).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text)
                Text(L10n.string("各服务中日期最新的一张")).font(.system(size: 10)).foregroundStyle(palette.faint)
            }
            HStack(alignment: .center, spacing: 18) {
                Button { model.openAlbum(album) } label: {
                    ArtworkView(track: Track(id: "album:\(album.id)", title: album.name, artist: album.artist, album: album.name, duration: 0,
                                             source: album.source, artworkURL: album.artworkURL), radius: 7)
                        .frame(width: 90, height: 90)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: album.name).font(.system(size: 15, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
                    HStack(spacing: 5) {
                        PlatformMark(source: album.source, size: 14)
                        Text(verbatim: [album.source.title, album.date?.shortText, album.trackCount.map { L10n.string("\($0) 首") }]
                            .compactMap { $0 }.joined(separator: " · "))
                    }
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
                    Button(L10n.string("打开专辑 ›")) { model.openAlbum(album) }.buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.accent)
                }
                Spacer(minLength: 12)
                if !others.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: L10n.string("其他服务的最新"))
                        ForEach(others) { other in
                            Button { model.openAlbum(other) } label: {
                                HStack(spacing: 5) {
                                    PlatformMark(source: other.source, size: 14)
                                    Text(verbatim: other.name).foregroundStyle(palette.text)
                                    Text(verbatim: other.date?.shortText ?? "").foregroundStyle(palette.faint)
                                }
                                .font(.system(size: 10)).lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
            .background(palette.panel.opacity(0.7), in: .rect(cornerRadius: 12))
        }
    }

    private var albumsSection: some View {
        let albums = singer.shownAlbums
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L10n.string("歌手的专辑")).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text)
                Text(L10n.string("新的在前 · 每个服务一张 · 只有年份的排在同年有日期的之后")).font(.system(size: 10)).foregroundStyle(palette.faint)
                Spacer(minLength: 0)
                if !allAlbums, albums.count > 12 {
                    Button(L10n.string("显示全部 \(albums.count) 张 ›")) { allAlbums = true; singer.loadMoreAlbums() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.accent)
                }
            }
            if albums.isEmpty, !singer.finding, !singer.loadingAlbums {
                Text(singer.profiles.isEmpty ? L10n.string("已连接的服务没有找到这位歌手。") : L10n.string("已连接的服务没有列出这位歌手的专辑。"))
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
            } else {
                AlbumGrid(model: model, singer: singer, width: width, rows: allAlbums ? nil : 2, minimumTile: 130, showsHeader: false)
            }
            if allAlbums, singer.albumLoads.values.contains(where: \.more) {
                Color.clear.frame(height: 1).onScrollVisibilityChange(threshold: 0.1) { visible in if visible { singer.loadMoreAlbums() } }
            }
        }
    }
}

// MARK: An album not in the library

struct RemoteAlbumView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var store: AlbumStore
    @State private var width: CGFloat = 900

    var body: some View {
        let album = store.album
        let rows = store.tracks.enumerated().map { SearchRow(copies: [SearchCopy(track: $1, origin: .service(album.source), rank: $0)], savedAtArrival: false) }
        let queue = store.tracks
        let metrics = SearchLayout.metrics(width: width + 2 * SearchLayout.sidePadding,
                                           blend: SearchLayout.choice(for: SearchLayoutInput(width: width + 2 * SearchLayout.sidePadding, height: 900, songsOnly: true)).blend)
        let saved = !store.tracks.isEmpty && store.tracks.allSatisfy { model.isLibraryTrack($0) }
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .bottom, spacing: 24) {
                ArtworkView(track: Track(id: "album:\(album.id)", title: album.name, artist: album.artist, album: album.name, duration: 0,
                                         source: album.source, artworkURL: album.artworkURL), radius: 9, highResolution: true)
                    .frame(width: 152, height: 152)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        PlatformMark(source: album.source, size: 14)
                        Text(verbatim: album.source.title + " · " + (saved ? L10n.string("已在音乐库") : L10n.string("不在你的音乐库")))
                    }
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
                    Text(verbatim: album.name).font(.system(size: 29)).foregroundStyle(palette.text).lineLimit(2)
                    if !album.artist.isEmpty {
                        Button(album.artist) { model.openSinger(model.singerStore(named: SingerRule.credits(album.artist).first ?? album.artist)) }
                            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(palette.accent)
                    }
                    Text(verbatim: details).font(.system(size: 10)).foregroundStyle(palette.secondary)
                    HStack(spacing: 10) {
                        Button { if let first = queue.first(where: { !$0.unavailable }) { model.play(first, context: queue) } } label: {
                            Label(L10n.string("播放专辑"), systemImage: "play.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle()).disabled(queue.isEmpty)
                        Button(saved ? L10n.string("已在音乐库") : L10n.string("存入音乐库")) { Task { await model.saveAlbum(store) } }
                            .buttonStyle(QuietButtonStyle()).disabled(queue.isEmpty || saved || store.saving)
                        Button(L10n.string("全部添加到歌单…")) { model.choosePlaylist(for: queue) }
                            .buttonStyle(QuietButtonStyle()).disabled(queue.isEmpty)
                    }
                }
            }
            switch store.load {
            case .loading:
                HStack(spacing: 8) { ImportStatusGlyph(state: .working(nil), size: 9); Text(L10n.string("正在读取专辑曲目…")) }
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
            case .failed(let message):
                HStack(spacing: 10) {
                    Text(L10n.string("\(album.source.title) 没有返回这张专辑的歌曲。")).help(message)
                    Button(L10n.string("重试")) { store.reload() }.buttonStyle(.plain).fontWeight(.semibold)
                }
                .font(.system(size: 11)).foregroundStyle(Color.orange)
            default:
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        SearchSongRow(model: model, row: row, index: index, queue: queue, metrics: metrics)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task { store.start() }
        .accessibilityIdentifier("remote-album-page")
    }

    private var details: String {
        let album = store.album
        let count = store.tracks.isEmpty ? album.trackCount : store.tracks.count
        let minutes = store.duration > 0 ? Int((store.duration / 60).rounded()) : nil
        return [count.map { L10n.string("\($0) 首歌曲") }, minutes.map { L10n.string("\($0) 分钟") }, album.date?.shortText]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
