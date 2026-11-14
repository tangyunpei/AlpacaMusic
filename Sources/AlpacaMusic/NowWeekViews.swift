import SwiftUI

/// This week: the source's charts as compact cards, two rows of them unless
/// the listener opens out the whole list. When the grid changes its column
/// count every card travels to its new cell.
struct NowWeekSection: View {
    @Environment(\.appPalette) private var palette
    let model: AppModel
    let metrics: NowRowMetrics
    /// How much of each grid shows, and how far the list is opened out.
    let columns: NowChartColumns
    let opened: CGFloat
    @Binding var expanded: Bool

    var body: some View {
        let store = model.browse
        if let source = store.current {
            let availability = store.availability(of: source)
            let shelf = NowBrowse.entry(store, source, availability)?.charts
            let charts = shelf?.value
            let failed = charts == nil && shelf?.error != nil && shelf?.loading != true
            // Placeholders fill the two rows the charts will.
            let count = charts?.count ?? (failed ? 0 : 10)
            let rowHeight = count > 0 ? NowLayout.chartGridHeight(count: count, columns: columns, expanded: opened) : 40
            let folds = count > NowLayout.chartRows * columnsNow
            NowSectionFrame(title: L10n.string("本周"), eyebrow: L10n.string("第 \(NowCalendar.week(.now)) 周").uppercased(),
                            metrics: metrics, padding: NowLayout.weekPadding, rowHeight: rowHeight) {
                VStack(alignment: .leading, spacing: 10) {
                    if let charts, !charts.isEmpty {
                        Text(L10n.string("\(charts.count) 个榜单，来自\(source.title)"))
                            .font(.system(size: 11.5)).lineSpacing(3).foregroundStyle(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if folds { foldLink(count: charts.count, size: 11.5) }
                    }
                }
                .padding(.top, 20)
            } headExtras: {
                if let charts, folds { foldLink(count: charts.count, size: 11) }
            } row: {
                if let charts {
                    if charts.isEmpty {
                        NowQuietLine(text: L10n.string("暂无榜单"))
                    } else {
                        grid(charts)
                    }
                } else if let error = shelf?.error, failed {
                    PlatformImportErrorLine(message: L10n.string("读取失败：\(error)"), retryLabel: L10n.string("重试")) { store.retry(source) }
                        .foregroundStyle(.orange)
                } else {
                    skeletons(count)
                }
            }
            .id(source)
            .accessibilityIdentifier("now-week")
        }
    }

    /// The grid that mostly shows, while the page is between two.
    private var columnsNow: Int {
        zip(NowLayout.chartColumnOptions, columns.weights).max { $0.1 < $1.1 }?.0 ?? 3
    }

    private func foldLink(count: Int, size: CGFloat) -> some View {
        NowLink(title: expanded ? L10n.string("收起") : L10n.string("全部 \(count) 个榜单"), size: size) { expanded.toggle() }
            .accessibilityIdentifier("now-week-all")
    }

    private func grid(_ charts: [BrowseCollection]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(charts.enumerated()), id: \.element.id) { index, chart in
                let opacity = NowLayout.chartOpacity(index: index, columns: columns, expanded: opened)
                if opacity > 0.001 {
                    let frame = NowLayout.chartFrame(index: index, columns: columns, rowWidth: metrics.rowWidth)
                    NowChartCard(model: model, chart: chart)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .opacity(Double(opacity)).allowsHitTesting(opacity > 0.5)
                }
            }
        }
        .frame(width: metrics.rowWidth, alignment: .topLeading)
    }

    private func skeletons(_ count: Int) -> some View {
        NowPulse { phase in
            ZStack(alignment: .topLeading) {
                ForEach(0..<count, id: \.self) { index in
                    let opacity = NowLayout.chartOpacity(index: index, columns: columns, expanded: opened)
                    if opacity > 0.001 {
                        let frame = NowLayout.chartFrame(index: index, columns: columns, rowWidth: metrics.rowWidth)
                        let tint = palette.accent.opacity(0.05 + 0.07 * phase(index))
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 10).fill(tint).frame(width: 120, height: 120)
                            VStack(alignment: .leading, spacing: 10) {
                                Capsule().fill(tint).frame(width: 90, height: 11)
                                Capsule().fill(tint.opacity(0.8)).frame(width: 140, height: 7)
                                Capsule().fill(tint.opacity(0.8)).frame(width: 110, height: 7)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(width: frame.width, height: frame.height, alignment: .leading)
                        .background(palette.panel.opacity(0.6), in: .rect(cornerRadius: 14, style: .continuous))
                        .clipped()
                        .offset(x: frame.minX, y: frame.minY).opacity(Double(opacity))
                    }
                }
            }
            .frame(width: metrics.rowWidth, alignment: .topLeading)
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.string("正在读取榜单"))
    }
}

/// A chart as a compact card: its cover, its top three songs or its own
/// description, how many songs it has, and a button that plays it.
private struct NowChartCard: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.nowMotion) private var motion
    let model: AppModel
    let chart: BrowseCollection
    @State private var hovered = false

    var body: some View {
        let store = model.browse
        let isOpen = store.opened?.id == chart.id && store.openedShelf == .charts
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button { store.open(chart, from: .charts) } label: {
            HStack(alignment: .top, spacing: 14) {
                ArtworkView(track: chart.coverTrack, radius: 10, highResolution: true).frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(chart.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.text).lineLimit(1)
                        Spacer(minLength: 0)
                        if !chart.caption.isEmpty {
                            Text(chart.caption).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                                .layoutPriority(-1)
                        }
                    }
                    if !chart.preview.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(chart.preview.prefix(3).enumerated()), id: \.offset) { rank, line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(verbatim: String(rank + 1)).font(.system(size: 11.5, weight: .bold)).foregroundStyle(palette.accent)
                                        .frame(width: 10, alignment: .leading)
                                    Text("\(Text(verbatim: line.title).foregroundStyle(palette.text))\(Text(verbatim: line.artist.isEmpty ? "" : " · \(line.artist)").foregroundStyle(palette.secondary))")
                                        .font(.system(size: 11.5)).lineLimit(1)
                                }
                            }
                        }
                        .padding(.top, 12)
                        .accessibilityElement(children: .combine)
                    } else if !chart.detail.isEmpty {
                        Text(chart.detail).font(.system(size: 11.5)).lineSpacing(3).foregroundStyle(palette.secondary)
                            .lineLimit(3).padding(.top, 12)
                    }
                    Spacer(minLength: 0)
                    Text(chart.trackCount.map { L10n.string("\($0) 首歌") } ?? " ")
                        .font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                        .frame(height: 26, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(hovered ? palette.raised.opacity(0.55) : palette.panel, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? L10n.string("收起 \(chart.title)") : L10n.string("打开 \(chart.title)"))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .accessibilityAction(named: L10n.string("播放")) { model.play(chart) }
        .overlay(alignment: .bottomTrailing) {
            NowPlayBadge(model: model, collection: chart, size: 26, fill: palette.primary, ink: palette.onPrimary)
                .padding(14)
        }
        .overlay { shape.strokeBorder(palette.accent.opacity(isOpen ? 0.9 : 0), lineWidth: 2).allowsHitTesting(false) }
        .onHover { hovered = $0 }
        .animation(motion.control, value: hovered)
        .animation(motion.control, value: isOpen)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-browse-chart-\(chart.remoteID)")
    }
}
