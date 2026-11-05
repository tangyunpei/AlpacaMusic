import SwiftUI
import Foundation

/// Item-level import progress shared by every platform. `total` stays nil
/// until the platform reports one, which keeps the indicator indeterminate.
struct ImportProgress: Equatable, Sendable {
    var completed: Int
    var total: Int?

    init(completed: Int = 0, total: Int? = nil) {
        self.completed = max(0, completed)
        self.total = total.map { max(0, $0) }
    }

    /// A determinate fraction only when a non-zero total is known.
    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    /// Overall fraction of a sequential batch: finished items plus the
    /// reported share of the item in progress (zero while it is unknown).
    static func batchFraction(finished: Int, count: Int, current: Double?) -> Double? {
        guard count > 0 else { return nil }
        let value = (Double(max(0, finished)) + min(1, max(0, current ?? 0))) / Double(count)
        return min(1, max(0, value))
    }
}

/// Per-row state for playlists and library sections across all platforms.
enum ImportRowState: Equatable, Sendable {
    case idle
    case queued
    case working(Double?)
    case done
    case partial
    case failed

    var isActive: Bool {
        switch self { case .queued, .working: true; default: false }
    }
    var isFinished: Bool {
        switch self { case .done, .partial, .failed: true; default: false }
    }
    var accessibilityLabel: String {
        switch self {
        case .idle: ""
        case .queued: L10n.string("等待导入")
        case .working: L10n.string("正在导入")
        case .done: L10n.string("已导入")
        case .partial: L10n.string("部分导入")
        case .failed: L10n.string("导入失败")
        }
    }
}

private struct AppReducedMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The app's own reduce-motion preference, propagated into sheets by
    /// `PanelEntrance`. Views combine it with the system setting.
    var appReducedMotion: Bool {
        get { self[AppReducedMotionKey.self] }
        set { self[AppReducedMotionKey.self] = newValue }
    }
}

/// A thin capsule bar. Determinate when a fraction is known; otherwise a soft
/// highlight sweeps across it. Reduced motion shows a static partial fill.
struct ImportProgressBar: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    var fraction: Double?
    var height: CGFloat = 3
    var tint: Color? = nil

    var body: some View {
        let color = tint ?? palette.accent
        let reduced = systemReduced || appReduced
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.12))
                if let fraction {
                    Capsule().fill(color)
                        .frame(width: fraction > 0 ? max(height, width * fraction) : 0)
                        .animation(reduced ? nil : Animation.smooth(duration: 0.35), value: fraction)
                } else if reduced {
                    Capsule().fill(color.opacity(0.45)).frame(width: width * 0.35)
                } else {
                    TimelineView(.animation) { context in
                        let period = 1.3
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                        let segment = width * 0.32
                        Capsule()
                            .fill(LinearGradient(colors: [color.opacity(0), color, color.opacity(0)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: segment)
                            .offset(x: -segment + (width + segment) * phase)
                    }
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel(L10n.string("导入进度"))
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? L10n.string("正在读取"))
    }
}

/// A small round status glyph: dashed ring when queued, a ring that fills or
/// spins while working, and a check that springs in when done.
struct ImportStatusGlyph: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    var state: ImportRowState
    var size: CGFloat = 16

    var body: some View {
        let reduced = systemReduced || appReduced
        ZStack {
            switch state {
            case .idle:
                EmptyView()
            case .queued:
                Circle().strokeBorder(palette.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2.5]))
            case .working(let fraction):
                Circle().stroke(palette.accent.opacity(0.15), lineWidth: 2)
                if let fraction {
                    Circle().trim(from: 0, to: max(0.04, min(1, fraction)))
                        .stroke(palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduced ? nil : Animation.smooth(duration: 0.3), value: fraction)
                } else {
                    ImportSpinningArc(color: palette.accent, reduced: reduced)
                }
            case .done:
                Image(systemName: "checkmark.circle.fill").resizable().scaledToFit()
                    .foregroundStyle(palette.accent)
                    .transition(reduced ? AnyTransition.opacity : AnyTransition.scale(scale: 0.4).combined(with: .opacity))
            case .partial:
                Image(systemName: "exclamationmark.circle").resizable().scaledToFit().foregroundStyle(.orange)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").resizable().scaledToFit().foregroundStyle(.orange)
            }
        }
        .frame(width: size, height: size)
        .animation(reduced ? nil : Animation.spring(response: 0.32, dampingFraction: 0.62), value: state)
        .accessibilityElement()
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityHidden(state == .idle)
    }
}

private struct ImportSpinningArc: View {
    var color: Color
    var reduced: Bool
    var body: some View {
        if reduced {
            Circle().trim(from: 0, to: 0.3).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        } else {
            TimelineView(.animation) { context in
                let period = 0.9
                let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period * 360
                Circle().trim(from: 0, to: 0.28)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(angle))
            }
        }
    }
}

/// Icon-only row action. Idle rows show an import arrow; active rows show the
/// status glyph; finished rows keep their glyph and reveal a retry arrow on hover.
struct ImportRowAction: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    @State private var hovered = false
    var state: ImportRowState
    /// Help and accessibility text, for example "导入「name」".
    var label: String
    var disabled = false
    var action: () -> Void

    var body: some View {
        Group {
            if state.isActive {
                ImportStatusGlyph(state: state, size: 17).frame(width: 30, height: 30)
            } else {
                Button(action: action) {
                    ZStack {
                        if state == .idle || (hovered && !disabled) {
                            Image(systemName: state == .idle ? "arrow.down.circle" : "arrow.clockwise.circle")
                                .font(.system(size: 17, weight: .regular)).foregroundStyle(palette.accent)
                                .transition(.opacity)
                        } else {
                            ImportStatusGlyph(state: state, size: 17)
                        }
                    }.frame(width: 30, height: 30).contentShape(.rect)
                }
                .buttonStyle(.plain).disabled(disabled)
                .onHover { hovered = $0 }
                .help(label).accessibilityLabel(label)
                .accessibilityValue(state.accessibilityLabel)
            }
        }
        .animation(systemReduced || appReduced ? nil : ExperienceMotion.control, value: hovered)
    }
}

/// Live "12 / 40" counter whose digits roll as they change.
struct ImportCounter: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    var progress: ImportProgress
    var body: some View {
        HStack(spacing: 0) {
            Text(progress.completed, format: .number)
                .contentTransition(.numericText(value: Double(progress.completed)))
                .foregroundStyle(palette.text)
            if let total = progress.total {
                Text(verbatim: " / ").foregroundStyle(palette.faint)
                Text(total, format: .number).foregroundStyle(palette.secondary)
            }
        }
        .font(.system(size: 10, design: .monospaced)).monospacedDigit()
        .animation(systemReduced || appReduced ? nil : ExperienceMotion.control, value: progress.completed)
    }
}

/// A compact, cancellable progress card: an animated glyph, one short title,
/// a live counter and a bar. Pass `fraction` to override the bar for batches.
struct ImportProgressPanel: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    var title: String
    var progress: ImportProgress? = nil
    var fraction: Double? = nil
    var symbol = "waveform"
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.accent)
                    .symbolEffect(.variableColor.iterative, isActive: !(systemReduced || appReduced))
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let progress { ImportCounter(progress: progress) }
                if let onCancel {
                    Button(action: onCancel) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            .frame(width: 20, height: 20).contentShape(.rect)
                    }.buttonStyle(.plain).foregroundStyle(palette.secondary)
                        .help(L10n.string("取消")).accessibilityLabel(L10n.string("取消导入"))
                }
            }
            ImportProgressBar(fraction: fraction ?? progress?.fraction)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(palette.accent.opacity(0.05), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

/// Breathing placeholder rows shown while a playlist list loads.
struct ImportSkeletonRows: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    var count = 4
    private static let widths: [CGFloat] = [150, 110, 180, 130]

    var body: some View {
        let reduced = systemReduced || appReduced
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduced)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: 10) {
                ForEach(0..<count, id: \.self) { index in
                    let phase = reduced ? 0.5 : (sin(time * 2.4 - Double(index) * 0.55) + 1) / 2
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 6).frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 7) {
                            Capsule().frame(width: Self.widths[index % Self.widths.count], height: 8)
                            Capsule().frame(width: 56, height: 6).opacity(0.7)
                        }
                        Spacer()
                    }
                    .foregroundStyle(palette.accent.opacity(0.05 + 0.07 * phase))
                    .padding(14).background(palette.accent.opacity(0.025), in: .rect(cornerRadius: 8))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.string("正在读取歌单"))
    }
}

/// Replaces explanatory paragraphs: a quiet info icon with a tooltip and a
/// click-to-open popover, so the guidance stays available without clutter.
struct InfoHint: View {
    @Environment(\.appPalette) private var palette
    var text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(palette.secondary)
                .frame(width: 22, height: 22).contentShape(.rect)
        }
        .buttonStyle(.plain).help(text).accessibilityLabel(L10n.string("说明")).accessibilityHint(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text).font(.system(size: 11)).foregroundStyle(palette.text).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading).padding(14)
                .presentationBackground(palette.panel)
        }
    }
}
