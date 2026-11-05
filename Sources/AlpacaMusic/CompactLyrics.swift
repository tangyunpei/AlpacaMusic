import SwiftUI

/// The lyric lines a compact surface shows at one moment of playback.
/// `currentIndex` stays set on a reached blank line (an interlude), while
/// `current` only ever holds a line with readable text.
struct MiniLyricCue: Equatable, Sendable {
    var currentIndex: Int?
    var current: LyricLine?
    var next: LyricLine?
}

/// Picks the current and upcoming line from timed lyrics only. Plain text,
/// instrumental tracks and unusable positions have no cue, so a compact
/// surface never invents a lyric clock.
enum MiniLyricSelection {
    static func cue(in document: LyricDocument?, at position: Double) -> MiniLyricCue? {
        guard let document, document.timing != .plain, !document.isInstrumental,
              !document.lines.isEmpty, position.isFinite else { return nil }
        let lines: [LyricLine] = document.lines
        let currentIndex: Int? = document.activeIndex(at: max(0, position))
        let current: LyricLine?
        if let currentIndex, hasText(lines[currentIndex]) { current = lines[currentIndex] } else { current = nil }
        let next: LyricLine? = upcoming(in: lines, after: currentIndex, position: position)
        return MiniLyricCue(currentIndex: currentIndex, current: current, next: next)
    }

    /// The first readable line after the reached one; before the first line
    /// and in explicit gaps, the first readable line that is still to start.
    private static func upcoming(in lines: [LyricLine], after currentIndex: Int?, position: Double) -> LyricLine? {
        guard let currentIndex else {
            return lines.first(where: { (line: LyricLine) -> Bool in
                guard let start = line.start, start > position else { return false }
                return hasText(line)
            })
        }
        var index = currentIndex + 1
        while index < lines.count {
            if hasText(lines[index]) { return lines[index] }
            index += 1
        }
        return nil
    }

    private static func hasText(_ line: LyricLine) -> Bool {
        !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A smooth playback time for karaoke ink between the player's position
/// updates, with the same anchors as `LyricRowView`: a short projection bounded
/// by the cue end while animating, the projected moment held after a pause,
/// and the plain position otherwise. It reads no scene phase, so it also runs
/// in AppKit-hosted panels.
struct ProjectedLyricTime<Content: View>: View {
    private let position: Double
    private let isPlaying: Bool
    private let cueEnd: Double?
    private let animates: Bool
    private let lowPower: Bool
    private let content: (Double) -> Content
    @State private var anchorDate = Date()
    @State private var anchorPosition: Double? = nil
    @State private var frozenPosition: Double? = nil

    init(position: Double, isPlaying: Bool, cueEnd: Double?, animates: Bool, lowPower: Bool,
         @ViewBuilder content: @escaping (Double) -> Content) {
        self.position = position
        self.isPlaying = isPlaying
        self.cueEnd = cueEnd
        self.animates = animates
        self.lowPower = lowPower
        self.content = content
    }

    private var frameInterval: Double { lowPower ? 1.0 / 30 : 1.0 / 60 }

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: !animates)) { tick in
            content(visualPosition(tick.date))
        }
        .onAppear { resetProjection() }
        .onChange(of: position) { _, _ in resetProjection() }
        .onChange(of: isPlaying) { wasPlaying, playing in freeze(paused: wasPlaying && !playing) }
    }

    private func visualPosition(_ date: Date) -> Double {
        if !isPlaying { return frozenPosition ?? position }
        guard animates, anchorPosition == position else { return position }
        return LyricPlaybackProjection.position(position, anchoredAt: anchorDate, now: date, cueEnd: cueEnd)
    }

    private func resetProjection() {
        anchorDate = Date(); anchorPosition = position
        frozenPosition = isPlaying ? nil : position
    }

    /// Holds the projected moment at a pause, so the ink does not step back.
    private func freeze(paused: Bool) {
        let now = Date()
        if paused && anchorPosition == position {
            frozenPosition = LyricPlaybackProjection.position(position, anchoredAt: anchorDate, now: now, cueEnd: cueEnd)
        } else {
            frozenPosition = nil
        }
        anchorPosition = position; anchorDate = now
    }
}

/// What a compact surface shows when there are no timed lyrics.
enum CompactLyricFallback: Sendable { case trackInfo, hidden }

enum CompactLyricsMotion {
    /// Battery saver only slows lyric frames while macOS Low Power Mode is on.
    @MainActor static func lowPower(_ settings: VisualSettings,
                                    systemLowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled) -> Bool {
        settings.batterySaver && systemLowPower
    }
}

/// The current lyric with karaoke ink and the next line below it, for the
/// mini player and other compact surfaces. Without timed lyrics it shows the
/// track, or nothing; plain text never gets an invented timing.
struct CompactLyricLines: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    private let model: AppModel
    private let primarySize: CGFloat
    private let secondarySize: CGFloat
    private let showsNextLine: Bool
    private let alignment: HorizontalAlignment
    private let fallback: CompactLyricFallback

    init(model: AppModel, primarySize: CGFloat = 15, secondarySize: CGFloat = 11, showsNextLine: Bool = true,
         alignment: HorizontalAlignment = .leading, fallback: CompactLyricFallback = .trackInfo) {
        self.model = model
        self.primarySize = primarySize
        self.secondarySize = secondarySize
        self.showsNextLine = showsNextLine
        self.alignment = alignment
        self.fallback = fallback
    }

    private var reduced: Bool { systemReduced || model.visual.reduceMotion }
    private var isPlaying: Bool { model.player.status == .playing }
    private var frameAlignment: Alignment { Alignment(horizontal: alignment, vertical: .center) }
    private var rowStyle: CompactLyricStyle {
        CompactLyricStyle(primarySize: primarySize, secondarySize: secondarySize,
                          showsNextLine: showsNextLine, alignment: alignment, reduced: reduced)
    }

    var body: some View {
        let document: LyricDocument? = model.lyrics.document
        let position: Double = model.player.position
        let cue: MiniLyricCue? = MiniLyricSelection.cue(in: document, at: position)
        ZStack(alignment: frameAlignment) {
            if let document, let cue {
                projectedLines(document: document, cue: cue, position: position)
                    .transition(AnyTransition.opacity)
            } else {
                CompactLyricTrackInfo(track: model.player.current, style: rowStyle, fallback: fallback)
                    .transition(AnyTransition.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .animation(reduced ? nil : ExperienceMotion.panel, value: cue == nil)
        .transaction { if reduced { $0.animation = nil; $0.disablesAnimations = true } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compact-lyric-lines")
    }

    /// The cue at the player's authoritative position bounds the projection,
    /// so the smooth time never reaches a line before the player does.
    private func projectedLines(document: LyricDocument, cue: MiniLyricCue, position: Double) -> some View {
        let cueEnd: Double? = cue.current?.end ?? cue.next?.start
        let playing: Bool = isPlaying
        let style: CompactLyricStyle = rowStyle
        let track: Track? = model.player.current
        let fallback: CompactLyricFallback = self.fallback
        return ProjectedLyricTime(position: position, isPlaying: playing, cueEnd: cueEnd,
                                  animates: playing && !style.reduced,
                                  lowPower: CompactLyricsMotion.lowPower(model.visual)) { (time: Double) in
            CompactLyricFrame(document: document, time: time, track: track, style: style, fallback: fallback)
        }
    }
}

/// Sizes and placement shared by the compact lyric rows.
private struct CompactLyricStyle {
    var primarySize: CGFloat
    var secondarySize: CGFloat
    var showsNextLine: Bool
    var alignment: HorizontalAlignment
    var reduced: Bool
    var rowSpacing: CGFloat { max(2, (primarySize * 0.24).rounded()) }
}

/// One projected moment of the compact lines. A cue change cross-fades with
/// a short upward drift; with reduced motion the rows swap without animation.
private struct CompactLyricFrame: View {
    @Environment(\.appPalette) private var palette
    let document: LyricDocument
    let time: Double
    let track: Track?
    let style: CompactLyricStyle
    let fallback: CompactLyricFallback

    private var frameAlignment: Alignment { Alignment(horizontal: style.alignment, vertical: .center) }
    private var drift: AnyTransition {
        AnyTransition.asymmetric(insertion: AnyTransition.opacity.combined(with: AnyTransition.offset(y: 6)),
                                 removal: AnyTransition.opacity.combined(with: AnyTransition.offset(y: -6)))
    }

    var body: some View {
        let cue: MiniLyricCue? = MiniLyricSelection.cue(in: document, at: time)
        let key: Int? = cue?.currentIndex
        ZStack(alignment: frameAlignment) {
            rows(for: cue)
                .id(key)
                .transition(drift)
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .animation(style.reduced ? nil : ExperienceMotion.panel, value: key)
    }

    @ViewBuilder private func rows(for cue: MiniLyricCue?) -> some View {
        if let cue, let index = cue.currentIndex, let line = cue.current {
            currentRows(line, index: index, next: cue.next)
        } else if let upcoming = cue?.next {
            upcomingRows(upcoming)
        } else {
            CompactLyricTrackInfo(track: track, style: style, fallback: fallback)
        }
    }

    private func currentRows(_ line: LyricLine, index: Int, next: LyricLine?) -> some View {
        let context: LyricTimingContext = LyricSingingTiming.context(for: index, in: document.lines)
        let text: String = CompactLyricText.singleLine(line.text)
        let progress: Double = CompactLyricScroll.progress(of: line, text: text, at: time, context: context,
                                                           reduceMotion: style.reduced)
        return VStack(alignment: style.alignment, spacing: style.rowSpacing) {
            CompactScrollingLine(progress: progress, alignment: style.alignment) {
                LyricProgressText(line: line, text: text, position: time,
                                  appearance: .highlight, reduceMotion: style.reduced, timingContext: context)
                    .font(.system(size: style.primarySize, weight: .semibold))
            }
            if style.showsNextLine { nextRow(next) }
        }
    }

    /// An interlude previews the upcoming line, dimmed and without ink.
    private func upcomingRows(_ line: LyricLine) -> some View {
        VStack(alignment: style.alignment, spacing: style.rowSpacing) {
            Text(verbatim: CompactLyricText.singleLine(line.text))
                .font(.system(size: style.primarySize, weight: .semibold))
                .foregroundStyle(palette.text.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.tail)
            if style.showsNextLine { CompactLyricBlankRow(size: style.secondarySize) }
        }
    }

    @ViewBuilder private func nextRow(_ line: LyricLine?) -> some View {
        if let line {
            Text(verbatim: CompactLyricText.singleLine(line.text))
                .font(.system(size: style.secondarySize))
                .foregroundStyle(palette.text.opacity(0.42))
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            CompactLyricBlankRow(size: style.secondarySize)
        }
    }
}

/// Shown without timed lyrics: the current track, or nothing when hidden.
private struct CompactLyricTrackInfo: View {
    @Environment(\.appPalette) private var palette
    let track: Track?
    let style: CompactLyricStyle
    let fallback: CompactLyricFallback

    var body: some View {
        if fallback == .trackInfo {
            VStack(alignment: style.alignment, spacing: style.rowSpacing) {
                Text(verbatim: track?.title ?? L10n.string("未选择歌曲"))
                    .font(.system(size: style.primarySize, weight: .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let track {
                    Text(verbatim: "\(track.artist) · \(track.sourcePlaybackTitle)")
                        .font(.system(size: style.secondarySize))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    CompactLyricBlankRow(size: style.secondarySize)
                }
            }
        }
    }
}

/// Where a line wider than its row sits: it starts at the leading edge,
/// keeps the sung position in the middle of the row, and stops once its end
/// reaches the trailing edge.
enum CompactLyricScroll {
    /// The sung share of `text`, from the same per-character reveal as the
    /// karaoke ink, so it follows word timings. Without character timing the
    /// line advances evenly through its start and end.
    @MainActor static func progress(of line: LyricLine, text: String, at time: Double,
                         context: LyricTimingContext, reduceMotion: Bool) -> Double {
        guard time.isFinite else { return 0 }
        let timeline: LyricRevealTimeline = LyricReveal.timeline(for: line, context: context)
        if timeline.isTimed, let units = timeline.fragments([text]).first, !units.isEmpty, units.count == text.count {
            let sung: Double = units.reduce(0) { (total: Double, unit: LyricRevealUnit) -> Double in
                total + unit.opacity(at: time, reduceMotion: reduceMotion)
            }
            return min(1, max(0, sung / Double(units.count)))
        }
        guard let start = line.start, let end = line.end, start.isFinite, end.isFinite, end > start else { return 0 }
        return min(1, max(0, (time - start) / (end - start)))
    }

    /// How far a line of `textWidth` shifts toward the leading edge in a row
    /// of `rowWidth`; zero when it fits.
    static func offset(progress: Double, textWidth: CGFloat, rowWidth: CGFloat) -> CGFloat {
        guard textWidth.isFinite, rowWidth.isFinite, rowWidth > 0, textWidth > rowWidth else { return 0 }
        let sung: CGFloat = CGFloat(progress.isFinite ? min(1, max(0, progress)) : 0)
        let centered: CGFloat = sung * textWidth - rowWidth / 2
        return min(textWidth - rowWidth, max(0, centered))
    }
}

/// A one-line row that never truncates. A line wider than the row slides so
/// the sung position stays in the middle, with soft edges where text is
/// hidden; a line that fits keeps the row's alignment.
private struct CompactScrollingLine<Content: View>: View {
    let progress: Double
    let alignment: HorizontalAlignment
    let content: Content
    @State private var textWidth: CGFloat = 0
    @State private var rowWidth: CGFloat = 0
    private let fade: CGFloat = 14

    init(progress: Double, alignment: HorizontalAlignment, @ViewBuilder content: () -> Content) {
        self.progress = progress
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        let overflows: Bool = rowWidth > 0 && textWidth > rowWidth + 0.5
        let offset: CGFloat = CompactLyricScroll.offset(progress: progress, textWidth: textWidth, rowWidth: rowWidth)
        let furthest: CGFloat = max(0, textWidth - rowWidth)
        let rowAlignment = Alignment(horizontal: alignment, vertical: .center)
        // The hidden copy gives the row one line of height and the full width.
        content
            .lineLimit(1)
            .hidden()
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, alignment: rowAlignment)
            .onGeometryChange(for: CGFloat.self) { (proxy: GeometryProxy) -> CGFloat in
                proxy.size.width
            } action: { (width: CGFloat) in
                rowWidth = width
            }
            .overlay(alignment: overflows ? .leading : rowAlignment) {
                content
                    .fixedSize(horizontal: true, vertical: false)
                    .onGeometryChange(for: CGFloat.self) { (proxy: GeometryProxy) -> CGFloat in
                        proxy.size.width
                    } action: { (width: CGFloat) in
                        textWidth = width
                    }
                    .offset(x: overflows ? -offset : 0)
            }
            .clipped()
            .mask { edges(overflows: overflows, leading: offset > 0.5, trailing: offset < furthest - 0.5) }
    }

    @ViewBuilder private func edges(overflows: Bool, leading: Bool, trailing: Bool) -> some View {
        if overflows {
            HStack(spacing: 0) {
                LinearGradient(colors: [Color.black.opacity(leading ? 0 : 1), Color.black],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: fade)
                Color.black
                LinearGradient(colors: [Color.black, Color.black.opacity(trailing ? 0 : 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: fade)
            }
        } else {
            Color.black
        }
    }
}

/// Keeps the second row's height when it has no text, so the first row
/// stays in place as cues change.
private struct CompactLyricBlankRow: View {
    let size: CGFloat
    var body: some View {
        Text(verbatim: " ").font(.system(size: size)).hidden()
    }
}

private enum CompactLyricText {
    /// A multi-line cue (SRT, or merged duplicate timestamps) reads as one line.
    static func singleLine(_ text: String) -> String {
        guard text.contains(where: { (character: Character) -> Bool in character.isNewline }) else { return text }
        return String(text.map { (character: Character) -> Character in character.isNewline ? " " : character })
    }
}
