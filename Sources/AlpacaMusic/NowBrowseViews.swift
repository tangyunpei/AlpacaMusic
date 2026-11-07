import SwiftUI

/// Charts and recommendations on the Now page, one source at a time. Each
/// shelf keeps its size while it loads: placeholders pulse in place and the
/// cards fade in as that list arrives, so the page never jumps.
struct NowBrowseSection: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Bindable var model: AppModel
    private var store: BrowseStore { model.browse }
    private var reduced: Bool { systemReduced || model.visual.reduceMotion }

    var body: some View {
        if let source = store.current {
            let availability = store.availability(of: source)
            VStack(alignment: .leading, spacing: 16) {
                BrowseHeader(model: model, source: source, availability: availability)
                BrowseSourceContent(model: model, source: source, availability: availability)
                    .id(source)
                    .transition(.opacity)
            }
            .environment(\.appReducedMotion, reduced)
            .animation(reduced ? nil : ExperienceMotion.panel, value: source)
            // Runs on each visit and when a login settles; the store asks a
            // platform only when its copy is missing or stale.
            .task(id: BrowseLoadKey(source: source, availability: availability)) { store.ensureLoaded(source) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("now-browse")
        }
    }
}

private struct BrowseLoadKey: Equatable {
    var source: MusicSource
    var availability: BrowseAvailability
}

// MARK: Header

private struct BrowseHeader: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    let source: MusicSource
    let availability: BrowseAvailability
    /// Changes when the refresh cooldown ends, so the button redraws then.
    @State private var cooldownEnded = 0
    private var store: BrowseStore { model.browse }

    var body: some View {
        let entry = store.entry(for: source)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Text(L10n.string("榜单与推荐")).font(.system(size: 16, weight: .medium)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 10)
                if let updated = [entry?.charts.fetchedAt, entry?.picks.fetchedAt].compactMap({ $0 }).max() {
                    let time = updated.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: model.language.locale))
                    Text(L10n.string("更新于 \(time)"))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.faint)
                        .contentTransition(.numericText()).lineLimit(1)
                }
                if case .ready = availability { refreshControl(entry: entry) }
            }
            .frame(minHeight: 30)
            // One sleep until the cooldown ends, then a single redraw.
            .task(id: store.refreshAvailableAt(source)) {
                guard let end = store.refreshAvailableAt(source) else { return }
                try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
                if !Task.isCancelled { cooldownEnded &+= 1 }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(store.sources, id: \.self) { item in
                        BrowseSourceChip(model: model, source: item, selected: item == source)
                    }
                }
                .padding(1)
            }
            .scrollIndicators(.hidden)
        }
    }
    @ViewBuilder private func refreshControl(entry: BrowseStore.Entry?) -> some View {
        if entry?.charts.loading == true || entry?.picks.loading == true {
            ProgressView().controlSize(.small).frame(width: 30, height: 30)
                .accessibilityLabel(L10n.string("正在读取榜单与推荐"))
        } else {
            let _ = cooldownEnded
            let enabled = store.canRefresh(source)
            ToolButton(symbol: "arrow.clockwise", label: enabled ? L10n.string("刷新榜单与推荐") : L10n.string("刚刚更新，稍后可再刷新")) {
                store.refresh(source)
            }
            .disabled(!enabled).opacity(enabled ? 1 : 0.45)
            .accessibilityIdentifier("now-browse-refresh")
        }
    }
}

private struct BrowseSourceChip: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    let source: MusicSource
    let selected: Bool
    var body: some View {
        let store = model.browse
        let availability = store.availability(of: source)
        Button { store.select(source) } label: {
            HStack(spacing: 6) {
                Image(systemName: source.symbol).font(.system(size: 10))
                Text(source.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                status(availability, entry: store.entry(for: source))
            }
            .padding(.horizontal, 11).frame(height: 28)
            .foregroundStyle(selected ? palette.accent : palette.secondary)
            .background(selected ? palette.accent.opacity(0.08) : Color.clear, in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? palette.accent.opacity(0.28) : palette.line))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("now-browse-source-\(source.rawValue)")
        .animation(ExperienceMotion.control, value: selected)
    }
    @ViewBuilder private func status(_ availability: BrowseAvailability, entry: BrowseStore.Entry?) -> some View {
        switch availability {
        case .connecting:
            ImportStatusGlyph(state: .working(nil), size: 9)
        case .signedOut:
            Text(L10n.string("未连接")).font(.system(size: 9)).foregroundStyle(palette.faint).lineLimit(1).fixedSize()
        case .ready:
            if entry?.charts.loading == true || entry?.picks.loading == true {
                ImportStatusGlyph(state: .working(nil), size: 9)
            } else if entry?.charts.error != nil || entry?.picks.error != nil {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                    .accessibilityLabel(L10n.string("读取失败"))
            }
        case .hidden:
            EmptyView()
        }
    }
}

// MARK: Shelves

private struct BrowseSourceContent: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    let source: MusicSource
    let availability: BrowseAvailability
    private var store: BrowseStore { model.browse }

    var body: some View {
        switch availability {
        case .signedOut, .hidden:
            BrowseConnectPrompt(model: model, source: source)
        case .connecting:
            if let entry = store.entryWhileConnecting(source) {
                VStack(alignment: .leading, spacing: 22) {
                    chartShelf(entry.charts)
                    pickShelf(entry.picks)
                }
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    BrowseShelfTitle(title: L10n.string("榜单"), detail: L10n.string("正在连接\(source.title)…"))
                    BrowseCardSkeletons(queueOpen: model.queueOpen, label: L10n.string("正在读取榜单"))
                }
            }
        case .ready:
            let entry = store.entry(for: source)
            VStack(alignment: .leading, spacing: 22) {
                chartShelf(entry?.charts)
                pickShelf(entry?.picks)
            }
        }
    }

    @ViewBuilder private func chartShelf(_ shelf: BrowseStore.Shelf<[BrowseCollection]>?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BrowseShelfTitle(title: L10n.string("榜单"), detail: shelf?.value.map { L10n.string("\($0.count) 个榜单") })
            if let charts = shelf?.value {
                if charts.isEmpty {
                    BrowseQuietLine(text: L10n.string("暂无榜单"))
                } else {
                    BrowseCardRow(model: model, collections: charts, shelf: .charts)
                    openPanel(in: charts, shelf: .charts)
                }
                if let error = shelf?.error { failure(error) }
            } else if let error = shelf?.error, shelf?.loading != true {
                failure(error)
            } else {
                BrowseCardSkeletons(queueOpen: model.queueOpen, label: L10n.string("正在读取榜单"))
            }
        }
    }

    @ViewBuilder private func pickShelf(_ shelf: BrowseStore.Shelf<BrowseRecommendations>?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BrowseShelfTitle(title: L10n.string("为你推荐"), detail: nil)
            if let picks = shelf?.value {
                if picks.collections.isEmpty && picks.songs.isEmpty {
                    BrowseQuietLine(text: L10n.string("暂无推荐"))
                }
                if !picks.collections.isEmpty {
                    BrowseCardRow(model: model, collections: picks.collections, shelf: .picks)
                    openPanel(in: picks.collections, shelf: .picks)
                }
                if !picks.songs.isEmpty {
                    BrowseSongList(model: model, title: songsTitle, songs: picks.songs)
                        .padding(.top, picks.collections.isEmpty ? 0 : 8)
                }
                if let error = shelf?.error { failure(error) }
            } else if let error = shelf?.error, shelf?.loading != true {
                failure(error)
            } else {
                BrowseCardSkeletons(queueOpen: model.queueOpen, label: L10n.string("正在读取推荐"))
                // NetEase always sends its daily songs; QQ's radio may send none.
                if source == .netease { BrowseSongListSkeleton() }
            }
        }
    }

    private var songsTitle: String {
        switch source {
        case .netease: L10n.string("每日推荐")
        case .qq: L10n.string("猜你喜欢")
        default: L10n.string("推荐歌曲")
        }
    }

    @ViewBuilder private func openPanel(in collections: [BrowseCollection], shelf: BrowseStore.ShelfKind) -> some View {
        if let opened = store.opened, store.openedShelf == shelf, collections.contains(where: { $0.id == opened.id }) {
            BrowseCollectionPanel(model: model, collection: opened)
                .id(opened.id)
                .transition(.opacity.combined(with: .offset(y: -6)))
        }
    }

    private func failure(_ message: String) -> some View {
        PlatformImportErrorLine(message: L10n.string("读取失败：\(message)"), retryLabel: L10n.string("重试")) {
            store.retry(source)
        }
    }
}

private struct BrowseShelfTitle: View {
    @Environment(\.appPalette) private var palette
    let title: String
    let detail: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Eyebrow(text: title).accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.faint)
                    .contentTransition(.numericText()).lineLimit(1)
            }
        }
    }
}

private struct BrowseQuietLine: View {
    @Environment(\.appPalette) private var palette
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.vertical, 6)
    }
}

private struct BrowseConnectPrompt: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    let source: MusicSource
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: source.symbol).font(.system(size: 15)).foregroundStyle(palette.accent)
                .frame(width: 38, height: 38).background(palette.accent.opacity(0.07), in: .circle)
                .accessibilityHidden(true)
            Text(source == .appleMusic ? L10n.string("在音源页连接 Apple Music 后，这里会显示榜单和为你推荐。")
                 : L10n.string("登录\(source.title)后，这里会显示它的榜单和为你推荐。"))
                .font(.system(size: 12)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 10)
            Button(L10n.string("前往音源")) { model.navigate(.sources) }.buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("now-browse-connect")
        }
        .padding(16)
        .background(palette.accent.opacity(0.03), in: .rect(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(palette.line))
    }
}

// MARK: Cards

/// Poster geometry, shared with the placeholders so a shelf keeps its size
/// when its list arrives.
enum BrowsePoster {
    static func width(queueOpen: Bool) -> CGFloat { queueOpen ? 196 : 240 }
    static func height(queueOpen: Bool) -> CGFloat { (width(queueOpen: queueOpen) * 4 / 3).rounded() }
    /// How far the colour fade reaches up into the artwork.
    static func fade(queueOpen: Bool) -> CGFloat { (width(queueOpen: queueOpen) * 0.36).rounded() }
    static let radius: CGFloat = 16
    static let spacing: CGFloat = 18
    static let badge: CGFloat = 34
}

private struct BrowseCardRow: View {
    @Bindable var model: AppModel
    let collections: [BrowseCollection]
    let shelf: BrowseStore.ShelfKind
    /// Cards that appear soon after the row cascade in; cards scrolled into
    /// view later appear at once.
    @State private var shownAt = Date()
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: BrowsePoster.spacing) {
                ForEach(Array(collections.enumerated()), id: \.element.id) { index, collection in
                    BrowsePosterCard(model: model, collection: collection, index: index, shelf: shelf, rowShownAt: shownAt)
                }
            }
            // Room for the posters' shadow inside the scroll view.
            .padding(.vertical, 8).padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, -6)
    }
}

/// A list as a poster, after Apple Music's: the square artwork at full
/// width, the card continuing below it in the artwork's colour, and the text
/// set on a fade from the artwork into that colour. Apple Music supplies the
/// colours; for other platforms they are sampled from the cover's lower edge.
private struct BrowsePosterCard: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    @Bindable var model: AppModel
    let collection: BrowseCollection
    let index: Int
    let shelf: BrowseStore.ShelfKind
    let rowShownAt: Date
    @State private var hovered = false
    @State private var appeared = false
    @State private var sampled: BrowseArtworkColors?

    var body: some View {
        let store = model.browse
        let reduced = systemReduced || appReduced
        let width = BrowsePoster.width(queueOpen: model.queueOpen), height = BrowsePoster.height(queueOpen: model.queueOpen)
        let isOpen = store.opened?.id == collection.id && store.openedShelf == shelf
        let colors = collection.colors ?? sampled
        let ink = PosterInk(colors)
        let shape = RoundedRectangle(cornerRadius: BrowsePoster.radius, style: .continuous)
        Button { open() } label: {
            ZStack(alignment: .bottomLeading) {
                ink.background
                VStack(spacing: 0) {
                    ArtworkView(track: collection.coverTrack, radius: 0, highResolution: true)
                        .frame(width: width, height: width).clipped()
                    Spacer(minLength: 0)
                }
                // Clear over the artwork, the card's colour where the artwork ends.
                LinearGradient(stops: [.init(color: ink.background.opacity(0), location: 0),
                                       .init(color: ink.background.opacity(0.8), location: 0.62),
                                       .init(color: ink.background, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: width, height: BrowsePoster.fade(queueOpen: model.queueOpen))
                    .offset(y: -(height - width))
                text(ink).padding(.horizontal, 14).padding(.bottom, 14)
            }
            .frame(width: width, height: height)
            .clipShape(shape)
            .contentShape(shape)
            .animation(reduced ? nil : .easeOut(duration: 0.3), value: colors)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? L10n.string("收起 \(collection.title)") : L10n.string("打开 \(collection.title)"))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .accessibilityAction(named: L10n.string("播放")) { model.play(collection) }
        .overlay(alignment: .topTrailing) {
            BrowsePlayBadge(model: model, collection: collection, size: BrowsePoster.badge)
                .padding(12)
                .opacity(hovered || store.pendingPlay == collection.id || isOpen ? 1 : 0)
        }
        .overlay {
            shape.strokeBorder(isOpen ? palette.accent.opacity(0.85) : Color.black.opacity(0.07), lineWidth: isOpen ? 2 : 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(hovered ? 0.24 : 0.12), radius: hovered ? 14 : 7, y: hovered ? 7 : 3)
        .scaleEffect(hovered && !reduced ? 1.012 : 1)
        .onHover { hovered = $0 }
        .animation(reduced ? nil : ExperienceMotion.control, value: hovered)
        .animation(reduced ? nil : ExperienceMotion.control, value: isOpen)
        .opacity(appeared ? 1 : 0).offset(y: appeared || reduced ? 0 : 8)
        .onAppear {
            guard !appeared else { return }
            if reduced { appeared = true; return }
            let firstBatch = Date().timeIntervalSince(rowShownAt) < 0.6
            withAnimation(.smooth(duration: 0.36).delay(firstBatch ? Double(min(index, 8)) * 0.045 : 0)) { appeared = true }
        }
        .task(id: collection.artworkURL) {
            guard collection.colors == nil else { return }
            sampled = await PosterColors.sample(collection.coverTrack)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-browse-\(shelf == .charts ? "chart" : "pick")-\(collection.remoteID)")
    }

    /// A label, the title, then a chart's top three or the list's own line.
    private func text(_ ink: PosterInk) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !collection.caption.isEmpty {
                Text(collection.caption).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(ink.secondary).lineLimit(1)
            }
            Text(collection.title).font(.system(size: 15, weight: .bold)).foregroundStyle(ink.primary)
                .lineLimit(collection.preview.isEmpty ? 2 : 1)
            if collection.preview.isEmpty {
                if let line = detailLine {
                    Text(line).font(.system(size: 11)).foregroundStyle(ink.secondary).lineLimit(2)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(collection.preview.prefix(3).enumerated()), id: \.offset) { rank, line in
                        HStack(spacing: 6) {
                            Text(String(rank + 1)).font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(ink.primary).frame(width: 9, alignment: .leading)
                            Text(verbatim: line.artist.isEmpty ? line.title : "\(line.title) · \(line.artist)")
                                .font(.system(size: 11)).foregroundStyle(ink.secondary).lineLimit(1)
                        }
                    }
                }
                .padding(.top, 2)
                .accessibilityElement(children: .combine)
            }
        }
        .shadow(color: ink.background.opacity(0.45), radius: 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    /// The editorial line or artist, else the song count.
    private var detailLine: String? {
        if !collection.detail.isEmpty { return collection.detail }
        return collection.trackCount.map { L10n.string("\($0) 首") }
    }
    private func open() {
        let reduced = systemReduced || appReduced
        withAnimation(reduced ? nil : ExperienceMotion.panel) { model.browse.open(collection, from: shelf) }
    }
}

/// A poster's colours: the platform's own for its artwork, else a dark card
/// until the cover's colour is sampled.
private struct PosterInk {
    let background: Color
    let primary: Color
    let secondary: Color
    init(_ colors: BrowseArtworkColors?) {
        guard let colors else {
            background = Color(.sRGB, red: 0.16, green: 0.16, blue: 0.18); primary = .white; secondary = .white.opacity(0.74)
            return
        }
        let light = colors.background.luminance > 0.6
        background = Color(colors.background)
        primary = colors.primary.map { Color($0) } ?? (light ? Color(.sRGB, red: 0.08, green: 0.08, blue: 0.09) : .white)
        secondary = colors.secondary.map { Color($0) } ?? (light ? Color(.sRGB, red: 0.08, green: 0.08, blue: 0.09).opacity(0.68) : .white.opacity(0.76))
    }
}

/// Card colours for covers that come without them (NetEase, QQ): the average
/// of the cover's bottom edge, read from the pixels the artwork view decodes.
@MainActor enum PosterColors {
    private static var cache: [String: BrowseArtworkColors] = [:]
    private static var order: [String] = []

    static func sample(_ track: Track) async -> BrowseArtworkColors? {
        let key = Artwork.key(for: track)
        if let hit = cache[key] { return hit }
        let result = await Artwork.raster(for: track)
        guard !Task.isCancelled, let colors = edge(result.pixels) else { return nil }
        cache[key] = colors; order.append(key)
        while order.count > 160 { cache.removeValue(forKey: order.removeFirst()) }
        return colors
    }

    /// The bottom rows' average colour. Rows run top to bottom.
    nonisolated static func edge(_ pixels: ArtworkPixels) -> BrowseArtworkColors? {
        let rows = max(1, pixels.height / 16), bytesPerRow = pixels.width * 4
        guard pixels.width > 0, pixels.rgba.count >= pixels.height * bytesPerRow else { return nil }
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for row in (pixels.height - rows)..<pixels.height {
            for column in 0..<pixels.width {
                let index = row * bytesPerRow + column * 4
                let alpha = Double(pixels.rgba[index + 3]) / 255
                guard alpha > 0.05 else { continue }
                // Premultiplied: dividing by alpha restores the colour.
                red += Double(pixels.rgba[index]) / 255; green += Double(pixels.rgba[index + 1]) / 255
                blue += Double(pixels.rgba[index + 2]) / 255; weight += alpha
            }
        }
        guard weight > 0 else { return nil }
        let clamp = { (value: Double) in min(1, max(0, value / weight)) }
        return BrowseArtworkColors(background: BrowseColor(red: clamp(red), green: clamp(green), blue: clamp(blue)), primary: nil, secondary: nil)
    }
}

private extension Color {
    init(_ color: BrowseColor) { self.init(.sRGB, red: color.red, green: color.green, blue: color.blue) }
}

extension BrowseColor {
    var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}

private struct BrowsePlayBadge: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    let collection: BrowseCollection
    let size: CGFloat
    var body: some View {
        let waiting = model.browse.pendingPlay == collection.id
        Button { model.play(collection) } label: {
            ZStack {
                Circle().fill(palette.primary)
                if waiting {
                    ProgressView().controlSize(.small).tint(palette.onPrimary).scaleEffect(0.7)
                } else {
                    Image(systemName: playing ? "waveform" : "play.fill").font(.system(size: size * 0.42))
                        .foregroundStyle(palette.onPrimary)
                }
            }
            .frame(width: size, height: size).contentShape(.circle)
            .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        }
        .buttonStyle(.plain).disabled(waiting)
        .help(L10n.string("播放 \(collection.title)")).accessibilityLabel(L10n.string("播放 \(collection.title)"))
    }
    private var playing: Bool {
        guard model.player.status == .playing, let current = model.player.current,
              case .loaded(let tracks) = model.browse.tracksState(for: collection) else { return false }
        return tracks.contains { $0.id == current.id }
    }
}

// MARK: Opened list

private struct BrowseCollectionPanel: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    @Bindable var model: AppModel
    let collection: BrowseCollection
    @State private var showsAll = false
    private static let shownRows = 10

    var body: some View {
        let state = model.browse.tracksState(for: collection)
        let reduced = systemReduced || appReduced
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ArtworkView(track: collection.coverTrack, radius: 8, highResolution: true).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 5) {
                    Eyebrow(text: kindTitle)
                    Text(collection.title).font(.system(size: 15, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
                    Text(detail(state)).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 10)
                // Pressing it while the songs load plays them once they arrive.
                Button { model.play(collection) } label: {
                    if model.browse.pendingPlay == collection.id {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small).tint(palette.onPrimary).scaleEffect(0.6).frame(width: 12, height: 12)
                            Text(L10n.string("播放全部"))
                        }
                    } else {
                        Label(L10n.string("播放全部"), systemImage: "play.fill")
                    }
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(!playable(state)).opacity(playable(state) ? 1 : 0.5)
                .accessibilityIdentifier("now-browse-play-all")
                ToolButton(symbol: "xmark", label: L10n.string("收起列表")) {
                    withAnimation(reduced ? nil : ExperienceMotion.panel) { model.browse.close() }
                }
            }
            Group {
                switch state {
                case .loaded(let tracks):
                    if tracks.isEmpty {
                        Text(L10n.string("这个列表暂时没有可显示的歌曲。")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            TrackList(model: model, tracks: showsAll ? tracks : Array(tracks.prefix(Self.shownRows)),
                                      compact: true, online: true, queue: tracks, lazy: true)
                            if tracks.count > Self.shownRows {
                                Button(showsAll ? L10n.string("只显示前 \(Self.shownRows) 首") : L10n.string("显示全部 \(tracks.count) 首")) {
                                    withAnimation(reduced ? nil : ExperienceMotion.panel) { showsAll.toggle() }
                                }
                                .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(palette.accent)
                                .padding(.leading, 8)
                            }
                        }
                        .transition(.opacity)
                    }
                case .failed(let message):
                    PlatformImportErrorLine(message: L10n.string("读取歌曲失败：\(message)"), retryLabel: L10n.string("重试")) {
                        model.browse.reloadTracks(collection)
                    }
                case .loading, nil:
                    // As tall as the rows that replace it: the first ten, and
                    // the show-all line when there will be more.
                    let rows = min(collection.trackCount ?? Self.shownRows, Self.shownRows)
                    VStack(alignment: .leading, spacing: 8) {
                        BrowseRowSkeletons(count: max(rows, 1))
                        if (collection.trackCount ?? Self.shownRows + 1) > Self.shownRows { Color.clear.frame(height: 13) }
                    }
                    .transition(.opacity)
                }
            }
            .animation(reduced ? nil : ExperienceMotion.panel, value: state)
        }
        .padding(18)
        .background(palette.panel.opacity(0.55), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.line))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-browse-collection")
    }
    private var kindTitle: String {
        switch collection.kind {
        case .chart: L10n.string("榜单")
        case .playlist: L10n.string("歌单")
        case .album: L10n.string("专辑")
        }
    }
    private func detail(_ state: BrowseStore.TracksState?) -> String {
        let count: Int? = if case .loaded(let tracks) = state { tracks.count } else { collection.trackCount }
        let parts = [collection.detail.isEmpty ? collection.caption : collection.detail, count.map { L10n.string("\($0) 首") } ?? ""].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }
    /// Off only once the songs are known and none can play.
    private func playable(_ state: BrowseStore.TracksState?) -> Bool {
        if case .loaded(let tracks) = state { return tracks.contains { !$0.unavailable } }
        return true
    }
}

private struct BrowseSongList: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    let title: String
    let songs: [Track]
    @State private var showsAll = false
    private static let shownRows = 5
    var body: some View {
        let reduced = systemReduced || appReduced
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BrowseShelfTitle(title: title, detail: L10n.string("\(songs.count) 首"))
                Spacer()
                if let first = songs.first(where: { !$0.unavailable }) {
                    Button { model.play(first, context: songs) } label: {
                        Label(L10n.string("播放全部"), systemImage: "play.fill").font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(palette.accent)
                }
            }
            TrackList(model: model, tracks: showsAll ? songs : Array(songs.prefix(Self.shownRows)), compact: true, online: true, queue: songs, lazy: true)
            if songs.count > Self.shownRows {
                Button(showsAll ? L10n.string("只显示前 \(Self.shownRows) 首") : L10n.string("显示全部 \(songs.count) 首")) {
                    withAnimation(reduced ? nil : ExperienceMotion.panel) { showsAll.toggle() }
                }
                .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(palette.accent).padding(.leading, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-browse-songs")
    }
}

// MARK: Placeholders

/// One clock for a whole shelf of placeholders: a soft wave travels across
/// them while the list loads, and holds still with reduced motion.
private struct BrowsePulse<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    @ViewBuilder let content: (BrowsePulsePhase) -> Content
    var body: some View {
        let reduced = systemReduced || appReduced
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduced)) { context in
            content(BrowsePulsePhase(time: context.date.timeIntervalSinceReferenceDate, reduced: reduced))
        }
    }
}

/// Brightness of placeholder `index` at one moment, between 0 and 1.
private struct BrowsePulsePhase {
    let time: Double
    let reduced: Bool
    func callAsFunction(_ index: Int) -> Double {
        reduced ? 0.5 : (sin(time * 2.4 - Double(index) * 0.55) + 1) / 2
    }
}

private struct BrowseCardSkeletons: View {
    let queueOpen: Bool
    let label: String
    var body: some View {
        // The same scroll container as the real row, so a row wider than the
        // page is cut off at its edge instead of widening the whole section.
        ScrollView(.horizontal) {
            BrowsePulse { phase in
                HStack(alignment: .top, spacing: BrowsePoster.spacing) {
                    ForEach(0..<7, id: \.self) { index in
                        BrowsePosterSkeleton(queueOpen: queueOpen, phase: phase(index))
                    }
                }
                .padding(.vertical, 8).padding(.horizontal, 1)
            }
        }
        .scrollDisabled(true).scrollIndicators(.hidden)
        .padding(.vertical, -6)
        .accessibilityElement()
        .accessibilityLabel(label)
    }
}

/// A poster's shape while its list loads: the artwork square, the card below
/// it, and the text lines where the real ones will sit.
private struct BrowsePosterSkeleton: View {
    @Environment(\.appPalette) private var palette
    let queueOpen: Bool
    let phase: Double
    var body: some View {
        let width = BrowsePoster.width(queueOpen: queueOpen), height = BrowsePoster.height(queueOpen: queueOpen)
        let tint = palette.accent.opacity(0.05 + 0.07 * phase)
        ZStack(alignment: .bottomLeading) {
            tint.opacity(0.6)
            VStack(spacing: 0) { tint.frame(width: width, height: width); Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 9) {
                Capsule().fill(tint).frame(width: width * 0.32, height: 7)
                Capsule().fill(tint).frame(width: width * 0.7, height: 11)
                Capsule().fill(tint.opacity(0.8)).frame(width: width * 0.55, height: 7)
            }
            .padding(14).padding(.bottom, 22)
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: BrowsePoster.radius, style: .continuous))
    }
}

/// The daily or personal song list while the picks load.
private struct BrowseSongListSkeleton: View {
    @Environment(\.appPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule().fill(palette.accent.opacity(0.07)).frame(width: 96, height: 7).frame(height: 14)
            BrowseRowSkeletons(count: 5)
            Color.clear.frame(height: 13)
        }
        .padding(.top, 8)
    }
}

/// The opened list's rows, shaped like the compact track rows that replace them.
private struct BrowseRowSkeletons: View {
    @Environment(\.appPalette) private var palette
    let count: Int
    private static let widths: [CGFloat] = [0.42, 0.3, 0.5, 0.36, 0.46]
    var body: some View {
        BrowsePulse { phase in
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        let tint = palette.accent.opacity(0.05 + 0.07 * phase(index))
                        HStack(spacing: 12) {
                            Capsule().fill(tint).frame(width: 14, height: 6).frame(width: 24)
                            RoundedRectangle(cornerRadius: 6).fill(tint).frame(width: 43, height: 43)
                            VStack(alignment: .leading, spacing: 8) {
                                Capsule().fill(tint).frame(width: max(60, geometry.size.width * Self.widths[index % Self.widths.count]), height: 9)
                                Capsule().fill(tint.opacity(0.7)).frame(width: max(40, geometry.size.width * 0.18), height: 7)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Rectangle().fill(palette.line.opacity(0.5)).frame(height: 1) }
                    }
                }
            }
            .frame(height: CGFloat(count) * 63)
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.string("正在读取歌曲"))
    }
}

extension BrowseCollection {
    /// A stand-in track so lists use the shared artwork loader and cache.
    var coverTrack: Track {
        Track(id: "browse:\(id)", title: title, artist: "", album: "", duration: 0, source: source, artworkURL: artworkURL)
    }
}
