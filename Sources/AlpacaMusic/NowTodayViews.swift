import SwiftUI

/// Today: one source's daily songs as a day card, then what it recommends as
/// posters. The row keeps its height while it loads, and a prompt takes its
/// place when no source is connected.
struct NowTodaySection: View {
    let model: AppModel
    let metrics: NowRowMetrics
    let cardSize: CGSize
    let rowHeight: CGFloat
    /// How much of the connect prompt shows in place of the cards.
    let connect: CGFloat

    var body: some View {
        let store = model.browse
        let source = store.current
        let availability = source.map { store.availability(of: $0) } ?? .hidden
        let listsSources = NowBrowse.anySourceConnected(store)
        NowSectionFrame(title: L10n.string("今日"), eyebrow: NowCalendar.eyebrow(.now, locale: model.language.locale).uppercased(),
                        metrics: metrics, padding: NowLayout.todayPadding, rowHeight: rowHeight) {
            if listsSources, let source { NowSourceColumn(model: model, source: source, availability: availability) }
        } headExtras: {
            if listsSources, let source { NowSourceChips(model: model, source: source, availability: availability) }
        } row: {
            ZStack(alignment: .topLeading) {
                if connect < 0.999, let source {
                    NowPicksRow(model: model, source: source, availability: availability)
                        .frame(width: metrics.rowWidth, height: cardSize.height, alignment: .topLeading)
                        .opacity(Double(1 - connect)).allowsHitTesting(connect < 0.5)
                }
                if connect > 0.001 {
                    NowConnectCard(model: model, source: listsSources ? source : nil)
                        .frame(width: metrics.rowWidth, height: NowLayout.connectHeight)
                        .opacity(Double(connect)).allowsHitTesting(connect > 0.5)
                }
            }
        }
        // Runs on each visit and when a login settles; the store asks a
        // platform only when its copy is missing or stale.
        .task(id: NowLoadKey(source: source, availability: availability)) {
            if let source { store.ensureLoaded(source) }
        }
        .accessibilityIdentifier("now-today")
    }
}

private struct NowLoadKey: Equatable {
    var source: MusicSource?
    var availability: BrowseAvailability
}

/// What the Now page asks of the browse store beyond single lists.
@MainActor enum NowBrowse {
    static func isConnected(_ availability: BrowseAvailability) -> Bool {
        switch availability { case .ready, .connecting: true; case .signedOut, .hidden: false }
    }
    static func anySourceConnected(_ store: BrowseStore) -> Bool {
        store.sources.contains { isConnected(store.availability(of: $0)) }
    }
    /// True when the page has no lists to show for its source and offers to connect one.
    static func needsConnection(_ store: BrowseStore) -> Bool {
        guard let source = store.current else { return true }
        return !isConnected(store.availability(of: source))
    }
    /// The lists last read: the signed-in copy, or the one kept while a source checks its sign-in again.
    static func entry(_ store: BrowseStore, _ source: MusicSource, _ availability: BrowseAvailability) -> BrowseStore.Entry? {
        availability == .connecting ? store.entryWhileConnecting(source) : store.entry(for: source)
    }
    static func songsTitle(_ source: MusicSource) -> String {
        switch source {
        case .netease: L10n.string("每日推荐")
        case .qq: L10n.string("猜你喜欢")
        default: L10n.string("推荐歌曲")
        }
    }
}

// MARK: Sources

/// The sources in the gutter, one to a line, with when the lists were read.
private struct NowSourceColumn: View {
    @Environment(\.appPalette) private var palette
    let model: AppModel
    let source: MusicSource
    let availability: BrowseAvailability

    var body: some View {
        let store = model.browse
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.sources, id: \.self) { item in
                    NowSourceButton(model: model, source: item, selected: item == source, chip: false)
                }
            }
            .padding(.top, 20)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                NowUpdatedLabel(model: model, source: source)
                NowRefreshButton(model: model, source: source, availability: availability)
            }
            .frame(height: 26)
        }
    }
}

/// The sources as chips at the end of the heading line.
private struct NowSourceChips: View {
    let model: AppModel
    let source: MusicSource
    let availability: BrowseAvailability

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.browse.sources, id: \.self) { item in
                NowSourceButton(model: model, source: item, selected: item == source, chip: true)
            }
            NowRefreshButton(model: model, source: source, availability: availability)
        }
    }
}

private struct NowSourceButton: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.nowMotion) private var motion
    let model: AppModel
    let source: MusicSource
    let selected: Bool
    let chip: Bool

    var body: some View {
        let store = model.browse
        Button { store.select(source) } label: {
            if chip {
                HStack(spacing: 6) {
                    Text(source.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    status(store)
                }
                .padding(.horizontal, 11).frame(height: 28)
                .foregroundStyle(selected ? palette.accent : palette.secondary)
                .background(selected ? palette.accent.opacity(0.08) : Color.clear, in: .rect(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? palette.accent.opacity(0.28) : palette.line))
                .contentShape(.rect)
            } else {
                HStack(spacing: 8) {
                    Circle().fill(selected ? palette.accent : Color.clear).frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(selected ? palette.accent : palette.faint.opacity(0.85), lineWidth: 1.5))
                    Text(source.title).font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? palette.text : palette.secondary).lineLimit(1)
                    status(store)
                }
                .frame(height: 26).contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("now-browse-source-\(source.rawValue)")
        .animation(motion.control, value: selected)
    }

    @ViewBuilder private func status(_ store: BrowseStore) -> some View {
        let entry = store.entry(for: source)
        switch store.availability(of: source) {
        case .connecting:
            ImportStatusGlyph(state: .working(nil), size: 9)
        case .signedOut:
            Text(L10n.string("未连接")).font(.system(size: 9)).foregroundStyle(palette.faint).lineLimit(1).fixedSize()
        case .ready:
            if entry?.charts.loading == true || entry?.picks.loading == true {
                ImportStatusGlyph(state: .working(nil), size: 9)
            } else if let error = entry?.charts.error ?? entry?.picks.error {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                    .help(L10n.string("读取失败：\(error)")).accessibilityLabel(L10n.string("读取失败"))
            }
        case .hidden:
            EmptyView()
        }
    }
}

private struct NowUpdatedLabel: View {
    @Environment(\.appPalette) private var palette
    let model: AppModel
    let source: MusicSource
    var body: some View {
        if let text = Self.text(model, source) {
            Text(text)
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.secondary)
                .contentTransition(.numericText()).lineLimit(1).fixedSize()
        }
    }
    /// "Updated 4:04 AM", once either list has been read.
    @MainActor static func text(_ model: AppModel, _ source: MusicSource) -> String? {
        let entry = model.browse.entry(for: source)
        guard let updated = [entry?.charts.fetchedAt, entry?.picks.fetchedAt].compactMap({ $0 }).max() else { return nil }
        let time = updated.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: model.language.locale))
        return L10n.string("更新于 \(time)")
    }
}

/// Reads both lists again; after a failure it retries at once, otherwise it
/// rests for the store's cooldown.
private struct NowRefreshButton: View {
    @Environment(\.appPalette) private var palette
    let model: AppModel
    let source: MusicSource
    let availability: BrowseAvailability
    /// Changes when the refresh cooldown ends, so the button redraws then.
    @State private var cooldownEnded = 0

    var body: some View {
        let store = model.browse
        let entry = store.entry(for: source)
        Group {
            if case .ready = availability {
                if entry?.charts.loading == true || entry?.picks.loading == true {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 26, height: 26)
                        .accessibilityLabel(L10n.string("正在读取榜单与推荐"))
                } else {
                    let _ = cooldownEnded
                    let failed = entry?.charts.error != nil || entry?.picks.error != nil
                    let enabled = failed || store.canRefresh(source)
                    let action = failed ? L10n.string("重试") : enabled ? L10n.string("刷新榜单与推荐") : L10n.string("刚刚更新，稍后可再刷新")
                    // The heading line has no room for the time the gutter shows; the tooltip carries it.
                    let label = [NowUpdatedLabel.text(model, source), action].compactMap { $0 }.joined(separator: " · ")
                    Button { if failed { store.retry(source) } else { store.refresh(source) } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                            .frame(width: 26, height: 26).contentShape(.rect)
                    }
                    .buttonStyle(.plain).foregroundStyle(failed ? Color.orange : palette.secondary)
                    .disabled(!enabled).opacity(enabled ? 1 : 0.45)
                    .help(label).accessibilityLabel(label)
                    .accessibilityIdentifier("now-browse-refresh")
                }
            }
        }
        // One sleep until the cooldown ends, then a single redraw.
        .task(id: store.refreshAvailableAt(source)) {
            guard let end = store.refreshAvailableAt(source) else { return }
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            if !Task.isCancelled { cooldownEnded &+= 1 }
        }
    }
}

// MARK: Row

/// The row itself. It takes no sizes: the cards read theirs from the
/// environment, so only a change of what it lists builds it again.
private struct NowPicksRow: View {
    @Environment(\.appPalette) private var palette
    let model: AppModel
    let source: MusicSource
    let availability: BrowseAvailability

    var body: some View {
        let store = model.browse
        let shelf = NowBrowse.entry(store, source, availability)?.picks
        Group {
            if let picks = shelf?.value {
                if picks.collections.isEmpty && picks.songs.isEmpty {
                    NowQuietLine(text: L10n.string("暂无推荐"))
                } else {
                    cards(picks)
                }
            } else if let error = shelf?.error, shelf?.loading != true {
                failure(error)
            } else {
                NowPosterSkeletons(label: L10n.string("正在读取推荐"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A list that arrived with part missing says so in the room under the row.
        .overlay(alignment: .bottomLeading) {
            if shelf?.value != nil, let error = shelf?.error {
                failure(error).frame(maxWidth: 520).frame(height: 18).offset(y: 19)
            }
        }
        .id(source)
    }

    private func cards(_ picks: BrowseRecommendations) -> some View {
        let collections = Array(picks.collections.enumerated())
        let far = collections.dropFirst(NowLayout.cardsLaidOutTogether)
        return ScrollView(.horizontal) {
            // The cards a window can show stand in a plain row. A lazy row works
            // out its cards' places afresh whenever they change size, and while
            // a row glides to another card count that is every frame: measured,
            // such a frame took more than twice as long. Cards further along
            // are made when the row is scrolled to them.
            HStack(alignment: .top, spacing: NowLayout.cardGap) {
                if let songs = picks.songList(for: source, title: NowBrowse.songsTitle(source)) {
                    NowDayCard(model: model, list: songs)
                }
                ForEach(collections.prefix(NowLayout.cardsLaidOutTogether), id: \.element.id) { index, collection in
                    NowPosterCard(model: model, collection: collection, index: index)
                }
                if !far.isEmpty {
                    LazyHStack(alignment: .top, spacing: NowLayout.cardGap) {
                        ForEach(Array(far), id: \.element.id) { index, collection in
                            NowPosterCard(model: model, collection: collection, index: index)
                        }
                    }
                }
            }
            // Room for an open card's ring inside the scroll view.
            .padding(2)
        }
        .scrollIndicators(.hidden)
        .padding(-2)
    }

    private func failure(_ message: String) -> some View {
        PlatformImportErrorLine(message: L10n.string("读取失败：\(message)"), retryLabel: L10n.string("重试")) {
            model.browse.retry(source)
        }
        .foregroundStyle(.orange)
    }
}

struct NowQuietLine: View {
    @Environment(\.appPalette) private var palette
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(palette.secondary).padding(.vertical, 6)
    }
}

// MARK: Day card

/// The source's daily songs as today's date on a card. Everything on it is
/// placed in proportion to the card, so it reshapes with the row without
/// being built again.
private struct NowDayCard: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.nowMotion) private var motion
    let model: AppModel
    let list: BrowseCollection
    @State private var hovered = false

    var body: some View {
        let store = model.browse
        let isOpen = store.opened?.id == list.id
        let shape = RoundedRectangle(cornerRadius: NowPoster.radius, style: .continuous)
        let today = Date.now
        Button { store.open(list, from: .picks) } label: {
            ZStack(alignment: .topLeading) {
                palette.primary
                NowDayDot().fill(palette.highlight)
                VStack(alignment: .leading, spacing: 0) {
                    Text(list.title).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).textCase(.uppercase).lineLimit(1)
                    Spacer(minLength: 0)
                    NowDayNumber(day: NowCalendar.day(today))
                    Text(verbatim: NowCalendar.weekday(today, locale: model.language.locale))
                        .font(.system(size: 15, weight: .semibold)).lineLimit(1).padding(.top, 8)
                    Text(verbatim: detail).font(.system(size: 11)).lineLimit(1).padding(.top, 4)
                }
                .padding(16)
            }
            .foregroundStyle(palette.onPrimary)
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? L10n.string("收起 \(list.title)") : L10n.string("打开 \(list.title)"))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .overlay(alignment: .bottomTrailing) {
            NowPlayBadge(model: model, collection: list, size: 40, fill: palette.onPrimary, ink: palette.primary)
                .padding(14)
        }
        .overlay { shape.strokeBorder(palette.accent.opacity(isOpen ? 0.9 : 0), lineWidth: 2).padding(-2).allowsHitTesting(false) }
        .scaleEffect(hovered && !motion.reduced ? 1.012 : 1)
        .onHover { hovered = $0 }
        .animation(motion.control, value: hovered)
        .animation(motion.control, value: isOpen)
        .modifier(NowCardSized())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-day-card")
    }

    private var detail: String {
        let count = list.trackCount ?? list.tracks?.count ?? 0
        // NetEase turns its daily songs over at six in the morning.
        return list.source == .netease ? L10n.string("\(count) 首 · 每天 \(BrowseSchedule.dailyResetHour):00 更新") : L10n.string("\(count) 首歌")
    }
}

/// The sun in the day card's corner: 56% of the card across, a sixth of
/// it past the top and right edges.
private struct NowDayDot: Shape {
    func path(in rect: CGRect) -> Path {
        let side = rect.width * 0.56
        return Path(ellipseIn: CGRect(x: rect.maxX - side + rect.width * 0.16, y: rect.minY - rect.width * 0.16, width: side, height: side))
    }
}

/// The day of the month, half the card's width tall. It is set once at its
/// largest and scaled down to the card, so a resize draws no new glyphs.
private struct NowDayNumber: View {
    let day: Int
    /// Half the widest card.
    private static let setSize: CGFloat = 140
    var body: some View {
        // The card's text column is the card less its padding; this keeps the figure near 45% of the card's width.
        Color.clear.aspectRatio(1 / 0.52, contentMode: .fit)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    let scale = proxy.size.height / 0.9 / Self.setSize
                    Text(verbatim: String(day))
                        .font(.system(size: Self.setSize, weight: .thin)).tracking(-3 / max(0.1, scale)).monospacedDigit()
                        .fixedSize()
                        .scaleEffect(scale, anchor: .leading)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                }
            }
    }
}

// MARK: Posters

/// Poster geometry shared with the placeholders, so a row keeps its shape
/// when its list arrives.
enum NowPoster {
    static let radius: CGFloat = 16
    static let badge: CGFloat = 34
    /// How far the colour fade reaches up into the artwork, as a share of the card's width.
    static let fade: CGFloat = 0.36
}

/// A list as a poster, after Apple Music's: the square artwork at full
/// width, the card continuing below it in the artwork's colour, and the text
/// set on a fade from the artwork into that colour. Apple Music supplies the
/// colours; for other platforms they are sampled from the cover's lower edge.
/// It is laid out in proportion to whatever size the row gives it.
struct NowPosterCard: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.nowMotion) private var motion
    let model: AppModel
    let collection: BrowseCollection
    let index: Int
    @State private var hovered = false
    @State private var appeared = false
    @State private var sampled: BrowseArtworkColors?

    var body: some View {
        let store = model.browse
        let isOpen = store.opened?.id == collection.id && store.openedShelf == .picks
        let colors = collection.colors ?? sampled
        let ink = PosterInk(colors)
        let shape = RoundedRectangle(cornerRadius: NowPoster.radius, style: .continuous)
        Button { store.open(collection, from: .picks) } label: {
            ZStack(alignment: .bottomLeading) {
                ink.background
                VStack(spacing: 0) {
                    ArtworkView(track: collection.coverTrack, radius: 0, highResolution: true)
                        .aspectRatio(1, contentMode: .fit)
                        // Clear over the artwork, the card's colour where the artwork ends,
                        // and a point past its edge so no line of it shows under the fade.
                        .overlay(alignment: .bottom) {
                            LinearGradient(stops: [.init(color: ink.background.opacity(0), location: 0),
                                                   .init(color: ink.background.opacity(0.8), location: 0.62),
                                                   .init(color: ink.background, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                                .aspectRatio(1 / NowPoster.fade, contentMode: .fit)
                                .padding(.bottom, -1)
                        }
                    Spacer(minLength: 0)
                }
                text(ink).padding(.horizontal, 14).padding(.bottom, 14)
            }
            .clipShape(shape)
            .contentShape(shape)
            .animation(motion.reduced ? nil : .easeOut(duration: 0.3), value: colors)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? L10n.string("收起 \(collection.title)") : L10n.string("打开 \(collection.title)"))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .accessibilityAction(named: L10n.string("播放")) { model.play(collection) }
        .overlay(alignment: .topTrailing) {
            NowPlayBadge(model: model, collection: collection, size: NowPoster.badge, fill: palette.primary, ink: palette.onPrimary)
                .padding(12)
                .opacity(hovered || store.pendingPlay == collection.id ? 1 : 0)
        }
        .overlay {
            shape.strokeBorder(Color.black.opacity(0.07), lineWidth: 1).allowsHitTesting(false)
            shape.strokeBorder(palette.accent.opacity(isOpen ? 0.9 : 0), lineWidth: 2).padding(-2).allowsHitTesting(false)
        }
        .scaleEffect(hovered && !motion.reduced ? 1.012 : 1)
        .onHover { hovered = $0 }
        .animation(motion.control, value: hovered)
        .animation(motion.control, value: isOpen)
        // The first cards of a row arrive one after another.
        .opacity(appeared ? 1 : 0).offset(y: appeared || motion.reduced ? 0 : 8)
        .animation(motion.reduced ? nil : .smooth(duration: 0.36).delay(Double(min(index, 8)) * 0.045), value: appeared)
        .onAppear { appeared = true }
        .modifier(NowCardSized())
        .task(id: collection.artworkURL) {
            guard collection.colors == nil else { return }
            sampled = await PosterColors.sample(collection.coverTrack)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-browse-pick-\(collection.remoteID)")
    }

    /// A label, the title, then the list's own line.
    private func text(_ ink: PosterInk) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !collection.caption.isEmpty {
                Text(collection.caption).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(ink.secondary).lineLimit(1)
            }
            Text(collection.title).font(.system(size: 15, weight: .bold)).foregroundStyle(ink.primary).lineLimit(2)
            if let line = detailLine {
                Text(line).font(.system(size: 11)).foregroundStyle(ink.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    /// The editorial line or artist, else the song count.
    private var detailLine: String? {
        if !collection.detail.isEmpty { return collection.detail }
        return collection.trackCount.map { L10n.string("\($0) 首歌") }
    }
}

/// A poster's colours: the platform's own for its artwork, else a dark card
/// until the cover's colour is sampled.
struct PosterInk {
    let background: Color
    let primary: Color
    let secondary: Color
    init(_ colors: BrowseArtworkColors?) {
        guard let colors else {
            background = Color(.sRGB, red: 0.16, green: 0.16, blue: 0.18); primary = .white; secondary = .white.opacity(0.84)
            return
        }
        let light = colors.background.luminance > 0.6
        background = Color(colors.background)
        primary = colors.primary.map { Color($0) } ?? (light ? Color(.sRGB, red: 0.08, green: 0.08, blue: 0.09) : .white)
        secondary = colors.secondary.map { Color($0) } ?? (light ? Color(.sRGB, red: 0.08, green: 0.08, blue: 0.09).opacity(0.68) : .white.opacity(0.84))
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

/// Plays a list from its first playable song. Pressing it while the songs
/// load plays them once they arrive.
struct NowPlayBadge: View {
    let model: AppModel
    let collection: BrowseCollection
    let size: CGFloat
    let fill: Color
    let ink: Color
    var body: some View {
        let waiting = model.browse.pendingPlay == collection.id
        Button { model.play(collection) } label: {
            ZStack {
                Circle().fill(fill)
                if waiting {
                    ProgressView().controlSize(.small).tint(ink).scaleEffect(0.7)
                } else {
                    Image(systemName: playing ? "waveform" : "play.fill").font(.system(size: size * 0.38))
                        .foregroundStyle(ink)
                }
            }
            .frame(width: size, height: size).contentShape(.circle)
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

// MARK: Connect

/// Shown in place of Today's cards while no source is connected.
private struct NowConnectCard: View {
    @Environment(\.appPalette) private var palette
    let model: AppModel
    /// The chosen source when others are connected; nil when none is.
    let source: MusicSource?

    var body: some View {
        HStack(spacing: 28) {
            // Decoration: the heading beside it says what the card is about.
            Group {
                if let art = NowConnectArt.image {
                    Image(nsImage: art).resizable().interpolation(.high)
                        .frame(width: NowConnectArt.side, height: NowConnectArt.side)
                } else {
                    HStack(spacing: -16) {
                        Circle().fill(palette.primary).frame(width: 56, height: 56)
                        Circle().fill(palette.accent).frame(width: 56, height: 56)
                        Circle().fill(palette.highlight).frame(width: 56, height: 56)
                    }
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 18, weight: .medium)).foregroundStyle(palette.text).lineLimit(2)
                Text(message).font(.system(size: 12)).lineSpacing(3).foregroundStyle(palette.secondary)
                    .lineLimit(3).frame(maxWidth: 560, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.string("前往音源")) { model.navigate(.sources) }
                .buttonStyle(PrimaryButtonStyle()).fixedSize()
                .accessibilityIdentifier("now-browse-connect")
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.panel, in: .rect(cornerRadius: 16, style: .continuous))
    }

    private var title: String {
        source.map { L10n.string("连接\($0.title)") } ?? L10n.string("连接一个音源，填满这一页")
    }
    private var message: String {
        let names = (source.map { [$0] } ?? model.browse.sources).map(\.title)
            .formatted(.list(type: .or).locale(model.language.locale))
        return L10n.string("登录\(names)后，今日会显示每日歌曲与推荐，本周会显示榜单。")
    }
}

/// The drawing on the connect card: the alpaca with its cables unplugged,
/// which the build copies into the app bundle
/// (Resources/Brand/alpaca-disconnected.svg). A bare SwiftPM build has no
/// bundle resources and shows three discs instead.
enum NowConnectArt {
    static let side: CGFloat = 152

    @MainActor static let image: NSImage? = image(at: Bundle.main.url(forResource: "AlpacaDisconnected", withExtension: "svg"))

    /// The drawing, or nil when the file is missing or unreadable.
    static func image(at url: URL?) -> NSImage? {
        guard let url, let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }
}

// MARK: Placeholders

/// Posters' shapes while a list loads, in the row the real ones will fill.
struct NowPosterSkeletons: View {
    @Environment(\.appPalette) private var palette
    let label: String
    var body: some View {
        NowPulse { phase in
            HStack(alignment: .top, spacing: NowLayout.cardGap) {
                ForEach(0..<10, id: \.self) { index in
                    let tint = palette.accent.opacity(0.05 + 0.07 * phase(index))
                    ZStack(alignment: .bottomLeading) {
                        tint.opacity(0.6)
                        VStack(spacing: 0) { tint.aspectRatio(1, contentMode: .fit); Spacer(minLength: 0) }
                        VStack(alignment: .leading, spacing: 9) {
                            Capsule().fill(tint).frame(width: 68, height: 7)
                            Capsule().fill(tint).frame(width: 140, height: 11)
                            Capsule().fill(tint.opacity(0.8)).frame(width: 110, height: 7)
                        }
                        .padding(14).padding(.bottom, 22)
                    }
                    .clipShape(.rect(cornerRadius: NowPoster.radius, style: .continuous))
                    .modifier(NowCardSized())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement()
        .accessibilityLabel(label)
    }
}

extension BrowseCollection {
    /// A stand-in track so lists use the shared artwork loader and cache.
    var coverTrack: Track {
        Track(id: "browse:\(id)", title: title, artist: "", album: "", duration: 0, source: source, artworkURL: artworkURL)
    }
}
