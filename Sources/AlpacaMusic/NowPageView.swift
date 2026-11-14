import SwiftUI

/// The Now page. It reads top to bottom: a stage for what is playing, what
/// plays next, today's songs and picks, this week's charts, and the
/// listener's own library lately. An opened list or the queue takes a panel
/// at the right.
///
/// Sizes come from `NowLayout` and the page's own area, so they follow a
/// window resize frame by frame. When the layout makes a different choice
/// (the gutter appears, a card joins a row, a panel opens) the choice travels
/// as amounts on one spring, and the page is redrawn from those amounts at
/// every step: parts glide to their new places and keep following the window
/// on the way. With reduced motion the amounts change at once.
struct NowPageView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    let model: AppModel
    /// The amounts on screen; nil until the first layout.
    @State private var blend: NowLayoutBlend?
    @State private var chartsExpanded = false
    /// What the panel last showed, kept while it slides away.
    @State private var panel: NowPanelContent?
    @State private var scroll = NowScrollState()

    private var reduced: Bool { systemReduced || model.visual.reduceMotion }

    var body: some View {
        let content = NowPanelContent.current(model)
        GeometryReader { proxy in
            let choice = NowLayout.choice(for: input(proxy.size, panelOpen: content != nil))
            NowPageBody(model: model, width: proxy.size.width, height: proxy.size.height, blend: blend ?? choice.blend,
                        panel: content ?? panel, scroll: scroll, chartsExpanded: $chartsExpanded)
                .onChange(of: choice, initial: true) { _, new in settle(on: new.blend) }
        }
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.appReducedMotion, reduced)
        .environment(\.nowMotion, NowMotion(reduced: reduced))
        .onChange(of: content, initial: true) { _, new in if let new { panel = new } }
        // One panel at a time: opening a list puts the queue away.
        .onChange(of: model.browse.opened?.id) { _, opened in if opened != nil { model.queueOpen = false } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-page")
    }

    private func input(_ size: CGSize, panelOpen: Bool) -> NowLayoutInput {
        let player = model.player
        let track = player.current
        let idle = track == nil
        let waiting = player.status == .paused || player.status == .failed || player.status == .idle
        return NowLayoutInput(width: size.width, height: size.height, idle: idle, panelOpen: panelOpen,
                              connect: NowBrowse.needsConnection(model.browse), action: idle || waiting,
                              lyrics: Self.hasTimedLyrics(model.lyrics.document),
                              cover: NowCover.shows(model),
                              chartsExpanded: chartsExpanded)
    }

    /// Lines the stage can follow; plain text and instrumentals have none.
    private static func hasTimedLyrics(_ document: LyricDocument?) -> Bool {
        guard let document else { return false }
        return document.timing != .plain && !document.isInstrumental && !document.lines.isEmpty
    }

    private func settle(on target: NowLayoutBlend) {
        guard blend != nil, !reduced else { blend = target; return }
        withAnimation(ExperienceMotion.reflow) { blend = target }
    }
}

/// The page drawn for one set of amounts. SwiftUI interpolates the amounts
/// while they travel and draws this again for each step.
private struct NowPageBody: View, Animatable {
    @Environment(\.appPalette) private var palette
    let model: AppModel
    var width: CGFloat
    var height: CGFloat
    var blend: NowLayoutBlend
    let panel: NowPanelContent?
    let scroll: NowScrollState
    @Binding var chartsExpanded: Bool

    nonisolated var animatableData: NowLayoutBlend {
        get { blend }
        set { blend = newValue }
    }

    var body: some View {
        let metrics = NowLayout.metrics(width: width, height: height, blend: blend)
        ZStack(alignment: .topLeading) {
            palette.background
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        // Lazy, so the sections below the first screen cost nothing
                        // to a resize until the listener scrolls to them.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // Each part takes the slice of the sizes it shows and no more.
                            NowStageView(model: model, metrics: metrics.stage)
                                .id(NowPageAnchor.top)
                            NowNextStrip(model: model, pageWidth: metrics.pageWidth,
                                         room: NowLayout.nextItemCount(rowWidth: metrics.rowWidth), gutter: metrics.gutter)
                                .frame(height: metrics.nextStripHeight, alignment: .top).clipped()
                                .opacity(Double(metrics.nextStrip)).allowsHitTesting(metrics.nextStrip > 0.5)
                                .accessibilityHidden(metrics.nextStrip < 0.5)
                            NowTodaySection(model: model, metrics: metrics.row, cardSize: metrics.cardSize,
                                            rowHeight: metrics.todayRowHeight, connect: metrics.connect)
                            VStack(alignment: .leading, spacing: 0) {
                                NowDivider()
                                NowWeekSection(model: model, metrics: metrics.row, columns: metrics.columns, opened: metrics.expanded,
                                               expanded: $chartsExpanded)
                            }
                            .nowReveal(1 - metrics.connect)
                            NowDivider()
                            NowLatelySection(model: model, metrics: metrics.row)
                        }
                        // Over the content and under Search and Import: the strip that drags the window.
                        NowStripGuardRow(scroll: scroll)
                            .frame(width: metrics.pageWidth, height: NowLayout.stripHeight)
                        NowStageChrome(model: model, scroll: scroll, covered: NowLayout.panelWidth * metrics.panel * (1 - metrics.dock))
                            .frame(width: metrics.pageWidth, height: NowLayout.stripHeight, alignment: .topTrailing)
                    }
                    .frame(width: metrics.pageWidth, alignment: .topLeading)
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                    scroll.offset = max(0, offset)
                }
                .onChange(of: scroll.topRequests) { _, _ in reader.scrollTo(NowPageAnchor.top, anchor: .top) }
            }
            .frame(width: metrics.pageWidth, height: height, alignment: .topLeading)
            if metrics.panel > 0.001 {
                NowSidePanel(model: model, content: panel, shown: metrics.panel, floating: 1 - metrics.dock)
                    .frame(width: NowLayout.panelWidth, height: height)
                    .offset(x: width - NowLayout.panelWidth * metrics.panel)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        // Layout animation lands on this view's amounts alone. Whatever else a
        // transaction carries (the shell animating a panel, a caller's
        // withAnimation) stops here, so nothing trails a resize; leaves add
        // their own for hovers and fades.
        .transaction { $0.animation = nil }
    }
}

private enum NowPageAnchor { case top }

/// Follows the scroll position so the guard stays at the window's top while
/// the content moves under it. Only this view reads the position.
private struct NowStripGuardRow: View {
    let scroll: NowScrollState
    var body: some View {
        NowStripGuard().offset(y: scroll.offset)
    }
}
