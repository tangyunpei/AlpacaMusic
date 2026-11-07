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
                    BrowseCardSkeletons(kind: .chart, queueOpen: model.queueOpen, label: L10n.string("正在读取榜单"))
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
                    BrowseCardRow(model: model, collections: charts, style: .chart)
                    openPanel(in: charts, shelf: .charts)
                }
                if let error = shelf?.error { failure(error) }
            } else if let error = shelf?.error, shelf?.loading != true {
                failure(error)
            } else {
                BrowseCardSkeletons(kind: .chart, queueOpen: model.queueOpen, label: L10n.string("正在读取榜单"))
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
                    BrowseCardRow(model: model, collections: picks.collections, style: .pick)
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
                BrowseCardSkeletons(kind: .pick, queueOpen: model.queueOpen, label: L10n.string("正在读取推荐"))
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

enum BrowseCardStyle {
    case chart, pick
    func width(queueOpen: Bool) -> CGFloat {
        switch self { case .chart: queueOpen ? 146 : 176; case .pick: queueOpen ? 116 : 136 }
    }
    func coverHeight(queueOpen: Bool) -> CGFloat {
        switch self { case .chart: queueOpen ? 118 : 142; case .pick: width(queueOpen: queueOpen) }
    }
    /// Fixed text heights, shared with the placeholders so a shelf keeps its
    /// height when its list arrives. Room for CJK line heights.
    var textHeight: CGFloat { switch self { case .chart: 34; case .pick: 52 } }
    static let previewRowHeight: CGFloat = 14
    static let previewSpacing: CGFloat = 4
    static var previewHeight: CGFloat { previewRowHeight * 3 + previewSpacing * 2 }
}

private struct BrowseCardRow: View {
    @Bindable var model: AppModel
    let collections: [BrowseCollection]
    let style: BrowseCardStyle
    /// Cards that appear soon after the row cascade in; cards scrolled into
    /// view later appear at once.
    @State private var shownAt = Date()
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: style == .chart ? 16 : 14) {
                ForEach(Array(collections.enumerated()), id: \.element.id) { index, collection in
                    BrowseCard(model: model, collection: collection, index: index, style: style, rowShownAt: shownAt)
                }
            }
            .padding(.vertical, 2).padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
    }
}

private struct BrowseCard: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    @Bindable var model: AppModel
    let collection: BrowseCollection
    let index: Int
    let style: BrowseCardStyle
    let rowShownAt: Date
    @State private var hovered = false
    @State private var appeared = false

    var body: some View {
        let store = model.browse
        let reduced = systemReduced || appReduced
        let width = style.width(queueOpen: model.queueOpen)
        let isOpen = store.opened?.id == collection.id && store.openedShelf == shelf
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                Button { open() } label: {
                    ArtworkView(track: collection.coverTrack, radius: 0, highResolution: true)
                        .frame(width: width, height: style.coverHeight(queueOpen: model.queueOpen)).clipped()
                        .overlay(alignment: .topLeading) {
                            if style == .chart, !collection.caption.isEmpty {
                                Text(collection.caption).font(.system(size: 9, weight: .medium)).lineLimit(1)
                                    .foregroundStyle(.white.opacity(0.92)).padding(.horizontal, 7).padding(.vertical, 4)
                                    .background(.black.opacity(0.34), in: .capsule).padding(9)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOpen ? L10n.string("收起 \(collection.title)") : L10n.string("打开 \(collection.title)"))
                .accessibilityAddTraits(isOpen ? .isSelected : [])
                // The badge shows only under the pointer; this keeps playing
                // reachable from the keyboard and VoiceOver.
                .accessibilityAction(named: L10n.string("播放")) { model.play(collection) }
                BrowsePlayBadge(model: model, collection: collection, size: style == .chart ? 33 : 28)
                    .padding(style == .chart ? 10 : 8)
                    .opacity(hovered || store.pendingPlay == collection.id || isOpen ? 1 : 0)
            }
            .clipShape(.rect(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isOpen ? palette.accent.opacity(0.6) : hovered ? palette.accent.opacity(0.35) : palette.line))
            Group {
                VStack(alignment: .leading, spacing: 3) {
                    Text(collection.title).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text)
                        .lineLimit(style == .chart ? 1 : 2)
                    if let subtitle { Text(subtitle).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1) }
                }
                .frame(width: width, height: style.textHeight, alignment: .topLeading)
                if style == .chart { previewLines }
            }
            // The whole card opens its list, not only the cover.
            .contentShape(.rect)
            .onTapGesture { open() }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(.rect)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-browse-\(style == .chart ? "chart" : "pick")-\(collection.remoteID)")
    }
    private var subtitle: String? {
        if style == .chart {
            return collection.trackCount.map { L10n.string("\($0) 首") }
        }
        return collection.caption.isEmpty ? collection.trackCount.map { L10n.string("\($0) 首") } : collection.caption
    }
    /// Three fixed rows so a chart with a shorter preview keeps the shelf aligned.
    private var previewLines: some View {
        VStack(alignment: .leading, spacing: BrowseCardStyle.previewSpacing) {
            ForEach(0..<3, id: \.self) { row in
                Group {
                    if row < collection.preview.count {
                        let line = collection.preview[row]
                        HStack(spacing: 6) {
                            Text(String(row + 1)).font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(row == 0 ? palette.primary : palette.faint).frame(width: 9, alignment: .leading)
                            Text(verbatim: line.artist.isEmpty ? line.title : "\(line.title) · \(line.artist)")
                                .font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                        }
                    } else {
                        Color.clear
                    }
                }
                .frame(height: BrowseCardStyle.previewRowHeight, alignment: .leading)
            }
        }
        .frame(height: BrowseCardStyle.previewHeight, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
    private func open() {
        let reduced = systemReduced || appReduced
        withAnimation(reduced ? nil : ExperienceMotion.panel) { model.browse.open(collection, from: shelf) }
    }
    private var shelf: BrowseStore.ShelfKind { style == .chart ? .charts : .picks }
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
        let parts = [collection.caption, count.map { L10n.string("\($0) 首") } ?? ""].filter { !$0.isEmpty }
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
    @Environment(\.appPalette) private var palette
    let kind: BrowseCardStyle
    let queueOpen: Bool
    let label: String
    var body: some View {
        let width = kind.width(queueOpen: queueOpen), height = kind.coverHeight(queueOpen: queueOpen)
        // The same scroll container as the real row, so a row wider than the
        // page is cut off at its edge instead of widening the whole section.
        ScrollView(.horizontal) {
        BrowsePulse { phase in
            HStack(alignment: .top, spacing: kind == .chart ? 16 : 14) {
                ForEach(0..<7, id: \.self) { index in
                    let tint = palette.accent.opacity(0.05 + 0.07 * phase(index))
                    VStack(alignment: .leading, spacing: 9) {
                        RoundedRectangle(cornerRadius: 9).fill(tint).frame(width: width, height: height)
                        VStack(alignment: .leading, spacing: 7) {
                            Capsule().fill(tint).frame(width: width * 0.7, height: 9)
                            Capsule().fill(tint.opacity(0.7)).frame(width: width * 0.4, height: 7)
                        }
                        .padding(.top, 3)
                        .frame(width: width, height: kind.textHeight, alignment: .topLeading)
                        if kind == .chart {
                            VStack(alignment: .leading, spacing: BrowseCardStyle.previewSpacing) {
                                ForEach(0..<3, id: \.self) { row in
                                    Capsule().fill(tint.opacity(0.6)).frame(width: width * [0.85, 0.7, 0.78][row], height: 6)
                                        .frame(height: BrowseCardStyle.previewRowHeight)
                                }
                            }
                            .frame(height: BrowseCardStyle.previewHeight, alignment: .topLeading)
                        }
                    }
                    .frame(width: width, alignment: .leading)
                }
            }
            .padding(.vertical, 2).padding(.horizontal, 1)
        }
        }
        .scrollDisabled(true).scrollIndicators(.hidden)
        .accessibilityElement()
        .accessibilityLabel(label)
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
