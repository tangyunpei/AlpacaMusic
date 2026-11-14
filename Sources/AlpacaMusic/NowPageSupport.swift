import AppKit
import SwiftUI

// Pieces the Now page's sections share: the motion rules, a line that opens
// and closes with the layout, section headings that move between the gutter
// and the line above a row, and the strip that drags the window.

extension ExperienceMotion {
    /// The Now page's parts taking their new places after a change of layout.
    static let reflow = Animation.spring(response: 0.5, dampingFraction: 0.78)
}

/// Whether both the system and the app allow motion, for the Now page's leaves.
struct NowMotion {
    let reduced: Bool
    /// The page's spring, or nothing with reduced motion.
    var reflow: Animation? { reduced ? nil : ExperienceMotion.reflow }
    var control: Animation? { reduced ? nil : ExperienceMotion.control }
    var panel: Animation? { reduced ? nil : ExperienceMotion.panel }
}

private struct NowMotionKey: EnvironmentKey {
    static let defaultValue = NowMotion(reduced: false)
}

extension EnvironmentValues {
    var nowMotion: NowMotion {
        get { self[NowMotionKey.self] }
        set { self[NowMotionKey.self] = newValue }
    }
}

// MARK: Reveal

/// Gives its content a share of the content's own height or width, so a line
/// opens and closes as part of the layout instead of popping in.
struct NowReveal: Layout {
    var amount: CGFloat
    var axis: Axis = .vertical
    /// On, the content's size across the axis folds away with it. A column no
    /// wider than its widest line then gives a hidden line no room.
    var foldsAcross = false
    /// The corner the content keeps to while the room for it opens.
    var anchor = UnitPoint.topLeading

    /// The content's own size for the last proposal, so sizing and placing ask it once.
    struct Measure {
        var proposal: ProposedViewSize?
        var size = CGSize.zero
    }
    func makeCache(subviews: Subviews) -> Measure { Measure() }
    func updateCache(_ cache: inout Measure, subviews: Subviews) { cache = Measure() }

    private func natural(_ subviews: Subviews, in proposal: ProposedViewSize, cache: inout Measure) -> CGSize {
        if cache.proposal == proposal { return cache.size }
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(axis == .vertical ? ProposedViewSize(width: proposal.width, height: nil)
                                                        : ProposedViewSize(width: nil, height: proposal.height))
        cache = Measure(proposal: proposal, size: size)
        return size
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Measure) -> CGSize {
        let size = natural(subviews, in: proposal, cache: &cache), share = NowLayout.unit(amount)
        let across = foldsAcross ? share : 1
        return axis == .vertical ? CGSize(width: size.width * across, height: size.height * share)
                                 : CGSize(width: size.width * share, height: size.height * across)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Measure) {
        guard let child = subviews.first else { return }
        // The same question as in sizeThatFits, so the content keeps the size it reported.
        let size = natural(subviews, in: proposal, cache: &cache)
        let corner = CGPoint(x: bounds.minX + bounds.width * anchor.x, y: bounds.minY + bounds.height * anchor.y)
        child.place(at: corner, anchor: anchor, proposal: ProposedViewSize(size))
    }
}

extension View {
    /// Shows `amount` of this view along `axis`, fading with it. At nothing it
    /// takes no room, no clicks and no place in the accessibility tree.
    func nowReveal(_ amount: CGFloat, axis: Axis = .vertical, foldsAcross: Bool = false, anchor: UnitPoint = .topLeading) -> some View {
        NowReveal(amount: amount, axis: axis, foldsAcross: foldsAcross, anchor: anchor) { self }
            .clipped()
            .opacity(Double(NowLayout.unit(amount)))
            .allowsHitTesting(amount > 0.5)
            .accessibilityHidden(amount < 0.5)
    }
}

// MARK: Section frame

/// A heading that glides between two places: beside its eyebrow on the line
/// above a row, and stacked over it in the gutter.
private struct NowHeadingLayout: Layout {
    var amount: CGFloat
    var titleSize: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let title = subviews[0], eyebrow = subviews[1]
        let titleSizeNow = title.dimensions(in: .unspecified), eyebrowSize = eyebrow.dimensions(in: .unspecified)
        // The design sets the title in a line 1.3 times its size above a row and 1.1 times in the gutter.
        let line = titleSize * (1.3 - 0.2 * amount)
        let titleY = (line - titleSizeNow.height) / 2
        title.place(at: CGPoint(x: bounds.minX, y: bounds.minY + titleY), anchor: .topLeading, proposal: .unspecified)
        let beside = CGPoint(x: titleSizeNow.width + 10,
                             y: titleY + titleSizeNow[.firstTextBaseline] - eyebrowSize[.firstTextBaseline])
        let below = CGPoint(x: 0, y: line + 7)
        eyebrow.place(at: CGPoint(x: bounds.minX + beside.x + (below.x - beside.x) * amount,
                                  y: bounds.minY + beside.y + (below.y - beside.y) * amount),
                      anchor: .topLeading, proposal: .unspecified)
    }
}

/// One section of the page below the stage: its name and eyebrow, a row of
/// content, and extras that live in the gutter when there is one and at the
/// end of the heading line when there is not.
struct NowSectionFrame<GutterExtras: View, HeadExtras: View, Row: View>: View {
    @Environment(\.appPalette) private var palette
    let title: String
    let eyebrow: String
    let metrics: NowRowMetrics
    let padding: (top: CGFloat, bottom: CGFloat)
    let rowHeight: CGFloat
    @ViewBuilder var gutterExtras: () -> GutterExtras
    @ViewBuilder var headExtras: () -> HeadExtras
    @ViewBuilder var row: () -> Row

    /// Where the gutter's extras begin, under the name and its eyebrow.
    static var gutterHeadingHeight: CGFloat { 26 * 1.1 + 7 + 12 }

    var body: some View {
        let amount = metrics.gutter
        let titleSize = 20 + 6 * amount
        ZStack(alignment: .topLeading) {
            row()
                .frame(width: metrics.rowWidth, height: rowHeight, alignment: .topLeading)
                .offset(x: metrics.rowInset, y: metrics.headHeight)
            NowHeadingLayout(amount: amount, titleSize: titleSize) {
                Text(title).font(.system(size: titleSize, weight: .light)).tracking(-0.3 - 0.1 * amount)
                    .foregroundStyle(palette.text).lineLimit(1).fixedSize()
                    .accessibilityAddTraits(.isHeader)
                Text(eyebrow).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2)
                    .foregroundStyle(palette.secondary).lineLimit(1).fixedSize()
            }
            .frame(width: metrics.contentWidth, height: NowLayout.headHeight, alignment: .topLeading)
            if amount > 0.001 {
                gutterExtras()
                    // A long source name may reach into the gap before the row, as on the canvas.
                    .frame(width: NowLayout.gutterWidth + 12, height: max(0, rowHeight - Self.gutterHeadingHeight), alignment: .topLeading)
                    .offset(x: (amount - 1) * 18, y: Self.gutterHeadingHeight)
                    .opacity(Double(amount)).allowsHitTesting(amount > 0.5).accessibilityHidden(amount < 0.5)
            }
            if amount < 0.999 {
                headExtras()
                    .frame(width: metrics.contentWidth, height: 28, alignment: .trailing)
                    .opacity(Double(1 - amount)).allowsHitTesting(amount < 0.5).accessibilityHidden(amount > 0.5)
            }
        }
        .frame(width: metrics.contentWidth, height: metrics.headHeight + rowHeight, alignment: .topLeading)
        .padding(.horizontal, NowLayout.sidePadding).padding(.top, padding.top).padding(.bottom, padding.bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A slot whose width glides between its small label plus a gap and the
/// gutter, holding both labels at its leading edge.
struct NowLabelSlot: Layout {
    var amount: CGFloat
    var gap: CGFloat = 20

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let small = subviews[0].sizeThatFits(.unspecified), large = subviews[1].sizeThatFits(.unspecified)
        let width = small.width + gap + (NowLayout.gutterSpan - small.width - gap) * amount
        return CGSize(width: max(0, width), height: max(small.height, large.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        }
    }
}

/// A thin rule between sections, inset like their content.
struct NowDivider: View {
    @Environment(\.appPalette) private var palette
    var body: some View {
        Rectangle().fill(palette.line).frame(height: 1).padding(.horizontal, NowLayout.sidePadding)
            .accessibilityHidden(true)
    }
}

/// A text link in the page's accent, such as "All 10 charts".
struct NowLink: View {
    @Environment(\.appPalette) private var palette
    let title: String
    var size: CGFloat = 11.5
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: size, weight: .medium)).foregroundStyle(palette.accent.opacity(hovered ? 0.75 : 1))
                .lineLimit(1).contentShape(.rect)
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
    }
}

// MARK: Card size

/// Gives a card the row's height and three quarters of it as its width. The
/// row sets only its own height; cards take their size from it in layout, so
/// a resize lays them out again without building them again.
struct NowCardSized: ViewModifier {
    func body(content: Content) -> some View {
        content.aspectRatio(0.75, contentMode: .fit)
    }
}

// MARK: Loading

/// One clock for a row of placeholders: a soft wave travels across them
/// while a list loads, and holds still with reduced motion.
struct NowPulse<Content: View>: View {
    @Environment(\.nowMotion) private var motion
    @ViewBuilder let content: (NowPulsePhase) -> Content
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: motion.reduced)) { context in
            content(NowPulsePhase(time: context.date.timeIntervalSinceReferenceDate, reduced: motion.reduced))
        }
    }
}

/// Brightness of placeholder `index` at one moment, between 0 and 1.
struct NowPulsePhase {
    let time: Double
    let reduced: Bool
    func callAsFunction(_ index: Int) -> Double {
        reduced ? 0.5 : (sin(time * 2.4 - Double(index) * 0.55) + 1) / 2
    }
}

// MARK: Window strip

/// Where the page's scroll view stands, read only by the views that need it.
@MainActor @Observable final class NowScrollState {
    var offset: CGFloat = 0
    /// Counts requests to show the top of the page, for the search shortcut.
    var topRequests = 0
}

/// The top of the page drags the window, as a title bar does. Placed over
/// the page's content and under Search and Import, it keeps whatever scrolls
/// beneath from taking clicks there. It answers a press the way the empty
/// strip above any other page does: by letting AppKit move the window.
struct NowStripGuard: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

// MARK: Stage colours

/// The stage's inks: the listening room's, or paper for a visual printed on it.
struct NowStageStyle {
    let light: Bool
    var palette: AppPalette { light ? .bauhaus : .listeningRoom }
    var pillFill: Color { light ? palette.text.opacity(0.03) : palette.background.opacity(0.55) }
    var pillLine: Color { palette.text.opacity(0.14) }
    var chipFill: Color { palette.background.opacity(light ? 0.86 : 0.72) }
    var chipLine: Color { palette.text.opacity(0.16) }
    var roomLine: Color { palette.accent.opacity(0.42) }
    var track: Color { palette.text.opacity(0.1) }
    /// The part of a lyric line not yet sung, as a share of the ink.
    var unsung: Double { light ? 0.68 : 0.55 }
}

// MARK: Dates

@MainActor enum NowCalendar {
    private static var formatters: [String: DateFormatter] = [:]
    /// Formatters are costly to make and the page asks on every layout.
    private static func formatter(_ format: String, locale: Locale) -> DateFormatter {
        let key = "\(locale.identifier)|\(format)"
        if let formatter = formatters[key] { return formatter }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = format
        formatters[key] = formatter
        return formatter
    }
    /// "FRI 13 NOV", or its Chinese counterpart.
    static func eyebrow(_ date: Date, locale: Locale) -> String {
        formatter(L10n.string("M月d日 EEE"), locale: locale).string(from: date)
    }
    static func weekday(_ date: Date, locale: Locale) -> String {
        formatter("EEEE", locale: locale).string(from: date)
    }
    static func day(_ date: Date) -> Int { Calendar.current.component(.day, from: date) }
    /// The ISO week of the year, as charts are dated.
    static func week(_ date: Date) -> Int { Calendar(identifier: .iso8601).component(.weekOfYear, from: date) }
}
