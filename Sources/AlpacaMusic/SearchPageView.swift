import SwiftUI

/// The search results page: one row of pills, then what the search found
/// above or beside its songs, then the songs. Sizes come from `SearchLayout`
/// and the page's own area, so they follow a window resize frame by frame;
/// when a choice flips (the band folds, the singer moves beside the list) the
/// choice travels as amounts on one spring and the parts glide.
struct SearchPageView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Bindable var model: AppModel
    @State private var blend: SearchLayoutBlend?
    private var reduced: Bool { systemReduced || model.visual.reduceMotion }

    var body: some View {
        let store = model.searchResults
        GeometryReader { proxy in
            let choice = SearchLayout.choice(for: SearchLayoutInput(width: proxy.size.width, height: proxy.size.height,
                                                                    songsOnly: store.songsOnly, layer: layer(store)))
            SearchPageBody(model: model, width: proxy.size.width, height: proxy.size.height, blend: blend ?? choice.blend)
                .onChange(of: choice, initial: true) { _, new in settle(on: new.blend) }
        }
        .environment(\.appReducedMotion, reduced)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-page")
    }

    /// While the first paint waits, a short window keeps the band's place so
    /// the songs do not jump down when a singer is found.
    private func layer(_ store: SearchStore) -> SearchLayer {
        if store.held { return .singer }
        switch store.shape {
        case .singer: return .singer
        case .singers: return .singers
        case .songs: return .none
        }
    }

    private func settle(on target: SearchLayoutBlend) {
        guard blend != nil, !reduced else { blend = target; return }
        withAnimation(ExperienceMotion.reflow) { blend = target }
    }
}

/// The page drawn for one set of amounts; SwiftUI draws it again at every
/// step while the amounts travel.
private struct SearchPageBody: View, Animatable {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var width: CGFloat
    var height: CGFloat
    var blend: SearchLayoutBlend
    @State private var position = ScrollPosition()

    nonisolated var animatableData: SearchLayoutBlend {
        get { blend }
        set { blend = newValue }
    }

    var body: some View {
        let store = model.searchResults
        let metrics = SearchLayout.metrics(width: width, blend: blend)
        VStack(alignment: .leading, spacing: 0) {
            SearchSourceBar(model: model)
                .padding(.top, SearchLayout.topPadding)
            SearchFailureLines(model: model)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: SearchLayout.asideGap * blend.columns) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let link = store.link {
                            SearchLinkRow(model: model, url: link).padding(.top, 18)
                        }
                        SearchLayers(model: model, blend: blend)
                        SearchSongList(model: model, metrics: metrics)
                    }
                    .frame(width: metrics.listWidth, alignment: .topLeading)
                    if metrics.asideWidth > 1 {
                        SearchAside(model: model, width: metrics.asideWidth)
                            .frame(width: metrics.asideWidth, alignment: .topLeading)
                            .padding(.top, 18)
                            .opacity(Double(blend.columns))
                            .allowsHitTesting(blend.columns > 0.5)
                            .accessibilityHidden(blend.columns < 0.5)
                    }
                }
                .padding(.bottom, 24)
                .frame(width: metrics.contentWidth, alignment: .topLeading)
            }
            .scrollPosition($position)
            .onChange(of: store.filter) { _, _ in position.scrollTo(edge: .top) }
        }
        .padding(.horizontal, SearchLayout.sidePadding)
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .transaction { $0.animation = nil }
    }
}

// MARK: Marks

/// A service's drawn letter mark: Apple Music a circle, NetEase a square,
/// QQ Music a diamond. No other source has one.
struct PlatformMark: View {
    var source: MusicSource
    var size: CGFloat = 16

    static func has(_ source: MusicSource) -> Bool { [.appleMusic, .netease, .qq, .spotify].contains(source) }

    var body: some View {
        switch source {
        case .appleMusic: letter("A", ink: hex(0xF1EBDD)).background(hex(0x202020), in: .circle)
        case .netease: letter("N", ink: hex(0xFFF8E9)).background(hex(0xB83228), in: .rect(cornerRadius: size / 4))
        case .qq:
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(hex(0xE4BC35)).frame(width: size * 0.8, height: size * 0.8).rotationEffect(.degrees(45))
                Text(verbatim: "Q").font(.system(size: size * 0.56, weight: .bold)).foregroundStyle(hex(0x202020))
            }
            .frame(width: size + 2, height: size + 2)
        case .spotify: letter("S", ink: hex(0xFFF8E9)).background(hex(0x2F6B47), in: .circle)
        default: Color.clear.frame(width: 0, height: size)
        }
    }

    private func letter(_ value: String, ink: Color) -> some View {
        Text(verbatim: value).font(.system(size: size * 0.56, weight: .bold)).foregroundStyle(ink)
            .frame(width: size, height: size)
    }
    private func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// The orange the canvas uses for a failed source.
private let failureInk = Color(red: 0xC4 / 255, green: 0x6A / 255, blue: 0x0A / 255)

// MARK: Pills

/// One row for sources: All, Library, Not saved, then each linked service,
/// and the "Songs only" switch.
private struct SearchSourceBar: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel

    var body: some View {
        // In a narrow page the pills scroll sideways and the switch stays in view.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) { pills; songsOnly }
            HStack(spacing: 0) {
                ScrollView(.horizontal) { pills }.scrollIndicators(.hidden)
                songsOnly
            }
        }
        .frame(height: 34)
    }

    private var pills: some View {
        let store = model.searchResults
        let waiting = store.held
        return HStack(spacing: 6) {
            pill(L10n.string("全部"), count: waiting ? "" : allCount(store), filter: .all)
            pill(L10n.string("音乐库"), count: waiting || store.libraryCount == 0 ? "" : "\(store.libraryCount)", filter: .library, spinning: waiting)
            pill(L10n.string("未保存"), count: "", filter: .notSaved)
            ForEach(store.sources) { state in
                pill(state.source.title, count: count(state), filter: .source(state.source), mark: state.source,
                     spinning: state.status == .searching, failed: state.failed)
            }
        }
        .frame(height: 34)
    }

    private var songsOnly: some View {
        let store = model.searchResults
        return HStack(spacing: 0) {
            Rectangle().fill(palette.line.opacity(1.2)).frame(width: 1, height: 18).padding(.horizontal, 8)
            SongsOnlySwitch(on: Binding(get: { store.songsOnly }, set: { store.songsOnly = $0 }))
        }
        .fixedSize()
    }

    /// No count for nothing found, as drawn.
    private func allCount(_ store: SearchStore) -> String {
        guard !store.rows.isEmpty else { return "" }
        let more = store.sources.contains { $0.paging != .end && !$0.failed }
        return "\(store.rows.count)" + (more ? "+" : "")
    }
    private func count(_ state: SearchSourceState) -> String {
        switch state.status {
        case .searching: ""
        case .failed: L10n.string("失败")
        case .done: state.count == 0 ? "" : "\(state.count)" + (state.paging == .more ? "+" : "")
        }
    }

    private func pill(_ title: String, count: String, filter: SearchFilter, mark: MusicSource? = nil,
                      spinning: Bool = false, failed: Bool = false) -> some View {
        let store = model.searchResults
        let selected = store.filter == filter
        let ink = failed ? failureInk : selected ? palette.accent : palette.secondary
        return Button { store.filter = filter } label: {
            HStack(spacing: 6) {
                if let mark { PlatformMark(source: mark) }
                Text(title).foregroundStyle(ink)
                if spinning { ImportStatusGlyph(state: .working(nil), size: 9) }
                else if !count.isEmpty {
                    Text(verbatim: count).font(.system(size: 10).monospacedDigit()).foregroundStyle(failed ? failureInk : palette.faint)
                }
            }
            .font(.system(size: 11)).lineLimit(1).fixedSize()
            .padding(.horizontal, 10).frame(height: 28)
            .background(failed ? failureInk.opacity(0.10) : selected ? palette.accent.opacity(0.08) : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(count)
    }
}

private struct SongsOnlySwitch: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.appReducedMotion) private var reduced
    @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: 8) {
                Capsule().fill(on ? palette.accent : palette.text.opacity(0.22)).frame(width: 24, height: 14)
                    .overlay(alignment: on ? .trailing : .leading) { Circle().fill(palette.onPrimary).frame(width: 10, height: 10).padding(2) }
                Text(L10n.string("仅歌曲"))
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.accent).fixedSize()
            .padding(.horizontal, 11).frame(height: 28)
            .background(palette.accent.opacity(on ? 0.10 : 0.035), in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.accent.opacity(on ? 0.4 : 0.16)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(reduced ? nil : ExperienceMotion.control, value: on)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? L10n.string("开") : L10n.string("关"))
        .accessibilityIdentifier("search-songs-only")
    }
}

/// A line for each source that failed, with its retry.
private struct SearchFailureLines: View {
    @Bindable var model: AppModel
    var body: some View {
        let failed = model.searchResults.sources.compactMap { state -> (MusicSource, String)? in
            if case .failed(let message) = state.status { return (state.source, message) }
            return nil
        }
        if !failed.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(failed, id: \.0) { source, message in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 10))
                        Text(L10n.string("\(source.title) 没有回应，列表里缺少它的歌曲。")).help(message)
                        Button(L10n.string("重试 \(source.title)")) { model.searchResults.retry(source) }
                            .buttonStyle(.plain).fontWeight(.semibold)
                    }
                    .font(.system(size: 10)).foregroundStyle(failureInk).lineLimit(1)
                }
            }
            .padding(.top, 8)
        }
    }
}

// MARK: What the search found

/// The band above the songs, the compact row of a short window, and the
/// singers line of a song-title search. Their heights travel with the amounts.
private struct SearchLayers: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var blend: SearchLayoutBlend

    var body: some View {
        let store = model.searchResults
        let card: SingerCard? = if case .singer(let card) = store.shape { card } else { nil }
        let bandHeight = (SearchLayout.bandHeight + 18) * blend.band
        let compactHeight = (SearchLayout.compactHeight + 14) * blend.compact
        let singer = card.map { model.singerStore(for: store.split ? $0.split[0] : $0) }
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if blend.band > 0.01 {
                    Group {
                        if store.held { SkeletonBand() }
                        else if let card, let singer {
                            HStack(alignment: .top, spacing: 18) {
                                SingerBandCards(model: model, card: card, singer: singer)
                                AlbumStrip(model: model, singer: singer, compact: false)
                            }
                        }
                    }
                    .frame(height: SearchLayout.bandHeight, alignment: .topLeading)
                    .padding(.top, 18)
                    .opacity(Double(blend.band))
                }
                if blend.compact > 0.01, !store.held, let card, let singer {
                    HStack(alignment: .center, spacing: 16) {
                        SingerCompactCards(model: model, card: card, singer: singer)
                        AlbumStrip(model: model, singer: singer, compact: true)
                    }
                    .frame(height: SearchLayout.compactHeight, alignment: .topLeading)
                    .padding(.top, 14)
                    .opacity(Double(blend.compact))
                }
            }
            .frame(height: bandHeight + compactHeight, alignment: .topLeading)
            .clipped()
            if blend.singersLine > 0.01, case .singers(let names, let more) = store.shape {
                SingersLine(model: model, names: names, more: more)
                    .padding(.top, 14)
                    .frame(height: (SearchLayout.singersLineHeight + 14) * blend.singersLine, alignment: .bottom)
                    .clipped()
                    .opacity(Double(blend.singersLine))
            }
        }
        // The singer is looked up once the card is known; its page reuses it.
        .task(id: singer?.id) { singer?.start() }
    }
}

private struct SkeletonBand: View {
    @Environment(\.appPalette) private var palette
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            RoundedRectangle(cornerRadius: 12).fill(palette.panel.opacity(0.6)).frame(width: SearchLayout.cardWidth)
            AlbumSkeletons(size: 96, count: 7).padding(.top, 28)
        }
        .accessibilityHidden(true)
    }
}

/// The singer's picture when a service gave one, else the initial.
struct SingerAvatar: View {
    @Environment(\.appPalette) private var palette
    var name: String
    var size: CGFloat
    var pictureURL: URL? = nil
    var body: some View {
        ZStack {
            Text(verbatim: String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.4, weight: .light)).foregroundStyle(palette.secondary)
                .frame(width: size, height: size)
                .background(LinearGradient(colors: [palette.raised, palette.panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: .circle)
            if let pictureURL {
                ArtworkView(track: Track(id: "singer:\(pictureURL.absoluteString)", title: name, artist: name, album: "", duration: 0,
                                         source: .netease, artworkURL: pictureURL), radius: size / 2)
                    .frame(width: size, height: size).clipShape(.circle)
            }
        }
        .accessibilityHidden(true)
    }
}

struct SingerName: View {
    @Environment(\.appPalette) private var palette
    var card: SingerCard
    var size: CGFloat
    var body: some View {
        let names = card.names
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: names.first ?? "").font(.system(size: size)).foregroundStyle(palette.text)
            if names.count > 1 {
                Text(verbatim: names.dropFirst().joined(separator: " · ")).font(.system(size: size * 0.62)).foregroundStyle(palette.secondary)
            }
        }
        .lineLimit(1)
    }
}

/// Undo or redo the guess that different spellings are one singer.
private struct SplitLink: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var card: SingerCard
    var body: some View {
        let store = model.searchResults
        if card.joinsNames || store.split {
            Button(store.split ? L10n.string("是同一位歌手") : L10n.string("不是同一位歌手？")) { store.split.toggle() }
                .buttonStyle(.plain).font(.system(size: 10)).underline().foregroundStyle(palette.faint)
                .help(L10n.string("没有服务说明这些名字是同一个人；这里是根据歌曲的猜测。"))
        }
    }
}

private struct OpenSingerLink: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var singer: SingerStore
    var body: some View {
        Button(L10n.string("打开歌手页 ›")) { model.openSinger(singer) }
            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.accent)
            .accessibilityIdentifier("open-singer-page")
    }
}

struct EvidenceLine: View {
    @Environment(\.appPalette) private var palette
    var evidence: SingerEvidence
    var body: some View {
        HStack(spacing: 5) {
            PlatformMark(source: evidence.source)
            Text(verbatim: evidence.name).foregroundStyle(palette.text)
            Text(L10n.string("演唱 \(evidence.count) / \(evidence.total) 首"))
        }
        .font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
    }
}

/// The singer card of the band: 300 wide. Split, it becomes a card per spelling.
private struct SingerBandCards: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var card: SingerCard
    var singer: SingerStore
    var body: some View {
        if model.searchResults.split {
            let parts = card.split
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    let store = model.singerStore(for: part)
                    Button { model.openSinger(store) } label: {
                        HStack(spacing: 12) {
                            SingerAvatar(name: part.names.first ?? "", size: 40, pictureURL: store.pictureURL)
                            VStack(alignment: .leading, spacing: 5) {
                                SingerName(card: part, size: 15)
                                HStack(spacing: 6) { ForEach(part.evidence, id: \.source) { PlatformMark(source: $0.source) } }
                            }
                            Spacer(minLength: 4)
                        }
                        .padding(.horizontal, 14)
                        .frame(width: SearchLayout.cardWidth, height: (SearchLayout.bandHeight - 8 * CGFloat(parts.count - 1)) / CGFloat(parts.count), alignment: .leading)
                        .background(palette.panel, in: .rect(cornerRadius: 12)).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottomTrailing) { if index == parts.count - 1 { SplitLink(model: model, card: card).padding(10) } }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    SingerAvatar(name: card.names.first ?? "", size: 52, pictureURL: singer.pictureURL)
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: L10n.string("歌手"))
                        SingerName(card: card, size: 21)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(card.evidence.prefix(3), id: \.source) { EvidenceLine(evidence: $0) }
                }
                Spacer(minLength: 6)
                HStack { OpenSingerLink(model: model, singer: singer); Spacer(); SplitLink(model: model, card: card) }.frame(height: 14)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(width: SearchLayout.cardWidth, height: SearchLayout.bandHeight, alignment: .topLeading)
            .background(palette.panel, in: .rect(cornerRadius: 12))
            .contentShape(.rect)
            .onTapGesture { model.openSinger(singer) }
            .accessibilityElement(children: .contain)
        }
    }
}

/// The singer as one compact row, for a short window.
private struct SingerCompactCards: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var card: SingerCard
    var singer: SingerStore
    var body: some View {
        let parts = model.searchResults.split ? card.split : [card]
        HStack(spacing: 12) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                let store = parts.count == 1 ? singer : model.singerStore(for: part)
                Button { model.openSinger(store) } label: {
                    HStack(spacing: 12) {
                        SingerAvatar(name: part.names.first ?? "", size: 44, pictureURL: store.pictureURL)
                        VStack(alignment: .leading, spacing: 5) {
                            SingerName(card: part, size: 15)
                            HStack(spacing: 2) { ForEach(part.evidence, id: \.source) { PlatformMark(source: $0.source) } }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(width: SearchLayout.compactCardWidth, height: SearchLayout.compactHeight, alignment: .leading)
                    .background(palette.panel, in: .rect(cornerRadius: 12)).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(L10n.string("打开歌手页"))
            }
            if card.joinsNames || model.searchResults.split { SplitLink(model: model, card: card) }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The singer beside the list in a wide window, with their albums in a grid.
private struct SearchAside: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var width: CGFloat
    var body: some View {
        if case .singer(let card) = model.searchResults.shape {
            let parts = model.searchResults.split ? card.split : [card]
            let singer = model.singerStore(for: parts[0])
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    let store = model.singerStore(for: part)
                    HStack(spacing: 14) {
                        SingerAvatar(name: part.names.first ?? "", size: 48, pictureURL: store.pictureURL)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                SingerName(card: part, size: 21)
                                Eyebrow(text: L10n.string("歌手"))
                            }
                            HStack(spacing: 10) {
                                ForEach(part.evidence, id: \.source) { EvidenceLine(evidence: $0) }
                                if index == parts.count - 1 { SplitLink(model: model, card: card) }
                            }
                        }
                        Spacer(minLength: 8)
                        Button(L10n.string("打开歌手页")) { model.openSinger(store) }.buttonStyle(QuietButtonStyle())
                    }
                    .frame(height: 64, alignment: .leading)
                }
                AlbumGrid(model: model, singer: singer, width: width, rows: 3)
            }
        }
    }
}

/// The singers credited in a song-title search's songs.
private struct SingersLine: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var names: [SingerCount]
    var more: Int
    var body: some View {
        HStack(spacing: 12) {
            Eyebrow(text: L10n.string("这些歌曲的歌手"))
            ForEach(names, id: \.name) { item in
                Button { model.openSinger(model.singerStore(named: item.name)) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(verbatim: item.name).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.accent)
                        Text(verbatim: "\(item.count)").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(palette.faint)
                    }
                }
                .buttonStyle(.plain).help(L10n.string("打开歌手页"))
            }
            if more > 0 { Text(L10n.string("其余 \(more) 位")).font(.system(size: 11)).foregroundStyle(palette.secondary) }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 14).frame(height: SearchLayout.singersLineHeight)
        .background(palette.accent.opacity(0.035), in: .rect(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }
}

// MARK: The songs

private struct SearchSongList: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var metrics: SearchMetrics

    var body: some View {
        let store = model.searchResults
        let rows = store.shownRows
        let tracks = rows.map(\.track)
        VStack(alignment: .leading, spacing: 0) {
            if store.held || (store.rows.isEmpty && store.searching) {
                header.padding(.top, 14)
                ForEach(0..<7, id: \.self) { SkeletonRow(index: $0) }
            } else if store.rows.isEmpty {
                // A pasted link stands alone; anything else found nothing.
                if store.link == nil { SearchNothingFound(model: model) }
            } else {
                if store.noLinkedService { NoLinkedServiceLine(model: model).padding(.top, 14) }
                header.padding(.top, 14)
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        SearchSongRow(model: model, row: row, index: index, queue: tracks, metrics: metrics)
                    }
                }
                if rows.isEmpty, !store.rows.isEmpty {
                    Text(store.filter == .notSaved ? L10n.string("这里的歌曲都已在你的音乐库中。") : L10n.string("这个筛选下没有歌曲。"))
                        .font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.vertical, 24)
                }
                if !store.rows.isEmpty { SearchListFooter(model: model) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(verbatim: "#").frame(width: 24)
            Text(L10n.string("歌曲 / 歌手")).frame(width: metrics.songColumn + 55, alignment: .leading)
            if metrics.albumColumn > 1 { Text(L10n.string("专辑")).frame(width: metrics.albumColumn, alignment: .leading) }
            Spacer(minLength: 0)
            Text(L10n.string("音源")).frame(width: 64, alignment: .leading)
            Text(L10n.string("时长")).frame(width: 40)
            Color.clear.frame(width: 88, height: 1)
        }
        .font(.system(size: 9)).foregroundStyle(palette.faint).lineLimit(1)
        .padding(.horizontal, 8).frame(height: 24)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }
}

private struct SkeletonRow: View {
    @Environment(\.appPalette) private var palette
    var index: Int
    private static let widths: [(CGFloat, CGFloat)] = [(150, 80), (210, 60), (120, 90), (180, 70), (140, 100), (200, 64), (160, 84)]
    var body: some View {
        let width = Self.widths[index % Self.widths.count]
        HStack(spacing: 12) {
            Color.clear.frame(width: 24)
            RoundedRectangle(cornerRadius: 6).fill(palette.panel).frame(width: 43, height: 43)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(palette.panel).frame(width: width.0, height: 9)
                RoundedRectangle(cornerRadius: 3).fill(palette.panel.opacity(0.7)).frame(width: width.1, height: 7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).frame(height: SearchLayout.rowHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line.opacity(0.5)).frame(height: 1) }
        .accessibilityHidden(true)
    }
}

/// One song: play, the singer, the album, every service's mark, like, add to
/// a playlist and more, all on the row. The row never moves after an action.
struct SearchSongRow: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var row: SearchRow
    var index: Int
    var queue: [Track]
    var metrics: SearchMetrics
    @State private var hovered = false

    var body: some View {
        let track = row.track
        let target = model.actionTrack(for: row)
        let current = model.player.current.map { current in row.copies.contains { $0.track.id == current.id } } ?? false
        let liked = model.library.favorites.contains(target.id)
        let saved = model.isInLibrary(row)
        HStack(spacing: 12) {
            Button { model.play(track, context: queue) } label: {
                Group {
                    if current && model.player.status == .playing { Image(systemName: "waveform") }
                    else if hovered { Image(systemName: "play.fill") }
                    else { Text(String(format: "%02d", index + 1)) }
                }
                .font(.system(size: 10, design: .monospaced)).frame(width: 24, height: 35)
                .foregroundStyle(current ? palette.accent : palette.faint)
            }
            .buttonStyle(.plain).disabled(track.unavailable).help(L10n.string("播放 \(track.title)"))
            HStack(spacing: 12) {
                Button { model.play(track, context: queue) } label: {
                    ArtworkView(track: track, radius: 6).frame(width: 43, height: 43)
                }
                .buttonStyle(.plain).disabled(track.unavailable)
                VStack(alignment: .leading, spacing: 6) {
                    Button { model.play(track, context: queue) } label: {
                        HStack(spacing: 5) {
                            Text(verbatim: track.title).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(current ? palette.accent : palette.text)
                            if saved {
                                Image(systemName: "checkmark.circle").font(.system(size: 10, weight: .medium)).foregroundStyle(palette.accent)
                                    .help(L10n.string("已在音乐库")).accessibilityLabel(L10n.string("已在音乐库"))
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain).disabled(track.unavailable)
                    .accessibilityLabel(L10n.string("播放 \(track.title)，\(track.artist)"))
                    // Each credited singer opens that singer's page.
                    HStack(spacing: 0) {
                        ForEach(Array(SingerRule.credits(track.artist).enumerated()), id: \.offset) { index, name in
                            if index > 0 { Text(verbatim: " / ") }
                            Button(name) { model.openSinger(model.singerStore(named: name)) }
                                .buttonStyle(.plain).help(L10n.string("打开歌手页"))
                        }
                        if track.unavailable { Text(L10n.string(" · 当前不可播放")) }
                    }
                    .font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
                .lineLimit(1)
                .frame(width: metrics.songColumn, alignment: .leading)
            }
            if metrics.albumColumn > 1 { album(target).frame(width: metrics.albumColumn, alignment: .leading) }
            Spacer(minLength: 0)
            HStack(spacing: 4) { ForEach(row.sources.filter(PlatformMark.has), id: \.self) { PlatformMark(source: $0) } }
                .frame(width: 64, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.sources.map(\.title).joined(separator: ", "))
            Text(track.duration > 0 ? formattedTime(track.duration) : "—")
                .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(palette.faint).frame(width: 40)
            HStack(spacing: 0) {
                ToolButton(symbol: liked ? "heart.fill" : "heart", label: liked ? L10n.string("取消喜欢") : L10n.string("喜欢 \(track.title)"),
                           active: liked) { model.favorite(target) }
                ToolButton(symbol: "text.append", label: L10n.string("添加到歌单…")) { model.selectedTrack = target; model.sheet = .addToPlaylist }
                Menu { TrackActions(track: target, model: model) } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28).foregroundStyle(palette.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.string("\(track.title) 更多操作"))
            }
            .frame(width: 88, alignment: .trailing)
        }
        .padding(.horizontal, 8).frame(height: SearchLayout.rowHeight)
        .background(current ? palette.accent.opacity(0.055) : hovered ? palette.hover : .clear, in: .rect(cornerRadius: 7))
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line.opacity(0.5)).frame(height: 1) }
        .onHover { hovered = $0 }
        .contextMenu { TrackActions(track: target, model: model) }
        .id(row.id)
    }

    /// The album's name; it opens the album when the library has it.
    @ViewBuilder private func album(_ target: Track) -> some View {
        let name = row.track.album.isEmpty ? "—" : row.track.album
        if let id = model.libraryAlbumID(containing: target.id) {
            Button { model.open(.album(id)) } label: { Text(verbatim: name).underline(hovered) }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                .help(L10n.string("打开专辑 \(name)"))
        } else {
            Text(verbatim: name).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
        }
    }
}

/// "More songs", and what each service can still give.
private struct SearchListFooter: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var body: some View {
        let store = model.searchResults
        HStack(spacing: 14) {
            if store.canLoadMore || store.loadingMore {
                Button { store.loadMore() } label: {
                    HStack(spacing: 6) {
                        if store.loadingMore { ImportStatusGlyph(state: .working(nil), size: 9) }
                        Text(L10n.string("更多歌曲"))
                    }
                }
                .buttonStyle(QuietButtonStyle()).disabled(store.loadingMore)
                .accessibilityIdentifier("search-more-songs")
            }
            Text(verbatim: note(store)).font(.system(size: 10)).foregroundStyle(palette.faint).lineLimit(2)
        }
        .frame(minHeight: 64)
        // The next pages load by themselves as the end of the list scrolls into
        // view (the owner's call, 14 November); a failure waits for the button.
        .onScrollVisibilityChange(threshold: 0.2) { visible in
            guard visible, store.canLoadMore, !store.sources.contains(where: { $0.moreError != nil }) else { return }
            store.loadMore()
        }
    }

    private func note(_ store: SearchStore) -> String {
        var parts: [String] = []
        if store.loadingMore { parts.append(L10n.string("正在加载更多歌曲…")) }
        else if store.canLoadMore { parts.append(L10n.string("向每个已连接的服务请求下一页，新歌曲加在下面。")) }
        else { parts.append(L10n.string("已是全部结果。")) }
        for state in store.sources {
            if let error = state.moreError { parts.append(L10n.string("\(state.source.title)：加载更多失败（\(error)）")) }
            else if state.failed { continue }
            else if state.paging == .end { parts.append(L10n.string("\(state.source.title)：没有更多")) }
            else if state.paging == .unsupported { parts.append(L10n.string("\(state.source.title)：暂时无法加载更多")) }
        }
        return parts.joined(separator: " · ")
    }
}

private struct SearchNothingFound: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var body: some View {
        let store = model.searchResults
        let names = store.sources.map(\.source.title).formatted(.list(type: .and).locale(L10n.language.locale))
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 26, weight: .light)).foregroundStyle(palette.secondary)
                .frame(width: 52, height: 52).background(palette.panel, in: .circle)
            Text(L10n.string("没有找到「\(store.term)」相关的歌曲")).font(.system(size: 19)).foregroundStyle(palette.text)
            Text(store.sources.isEmpty ? L10n.string("没有已连接的音乐服务，只搜索了你的音乐库。")
                 : L10n.string("\(names) 都没有找到匹配的歌曲，你的音乐库里也没有。"))
                .font(.system(size: 11)).foregroundStyle(palette.secondary).multilineTextAlignment(.center)
            Button(L10n.string("管理音源")) { model.navigate(.sources) }.buttonStyle(QuietButtonStyle())
        }
        .frame(maxWidth: .infinity).padding(.vertical, 75)
    }
}

private struct NoLinkedServiceLine: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            Text(L10n.string("没有已连接的音乐服务，只搜索了你的音乐库。")).font(.system(size: 11)).foregroundStyle(palette.secondary)
            Button(L10n.string("管理音源")) { model.navigate(.sources) }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.accent)
        }
    }
}

/// A pasted HTTP(S) address: offered as one row to add, never searched.
private struct SearchLinkRow: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var url: URL
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.accent)
                .frame(width: 30, height: 30).background(palette.accent.opacity(0.06), in: .rect(cornerRadius: 7))
                .accessibilityLabel(L10n.string("音频链接"))
            Text(url.host() ?? url.absoluteString).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(url.absoluteString)
            Spacer(minLength: 8)
            Button {
                do { try model.addLink(title: "", address: model.searchResults.term) } catch { model.notify(error.localizedDescription) }
            } label: { Label(L10n.string("添加到音乐库"), systemImage: "plus") }
                .buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(palette.accent.opacity(0.035), in: .rect(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }
}
