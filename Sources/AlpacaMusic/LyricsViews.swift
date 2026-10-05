import SwiftUI

// Kept outside AppModel so both presentations can run in the isolated QA app.
enum LyricPresentationMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case scroll, kinetic
    var id: String { rawValue }
    var title: String { self == .scroll ? "滚动歌词" : "动态字幕" }
}

struct LyricsPresentationView: View {
    @Environment(\.appPalette) private var palette
    var document: LyricDocument?
    var status: LyricsStatus
    var error: String?
    var mode: LyricPresentationMode
    var position: Double
    var isPlaying: Bool
    var reduceMotion: Bool
    var onSeek: (Double) -> Void
    var onImport: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var signal: (@MainActor () -> AudioLevels)? = nil

    var body: some View {
        Group {
            if status == .loading {
                LyricsStatusView(symbol: "text.line.2", title: "正在获取歌词", isLoading: true)
            } else if let document, document.isInstrumental {
                LyricsStatusView(symbol: "waveform", title: "纯音乐")
            } else if let document, !document.lines.isEmpty {
                if mode == .scroll || document.timing == .plain {
                    ScrollLyricsView(document: document, position: position, isPlaying: isPlaying, reduceMotion: reduceMotion, onSeek: onSeek)
                } else {
                    KineticLyricsView(document: document, position: position, isPlaying: isPlaying, reduceMotion: reduceMotion, onSeek: onSeek, signal: signal)
                }
            } else {
                VStack(spacing: 22) {
                    LyricsStatusView(symbol: status == .failed ? "text.badge.xmark" : "text.quote", title: status == .failed ? "歌词加载失败" : "暂无歌词", detail: error ?? "可导入 LRC、SRT 或纯文本歌词。")
                    HStack(spacing: 12) {
                        if let onImport { Button("导入歌词", action: onImport).buttonStyle(QuietButtonStyle()) }
                        if status == .failed, let onRetry { Button("重新获取", action: onRetry).buttonStyle(QuietButtonStyle()) }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if status == .ready, let document, !document.sourceDescription.isEmpty {
                    let current = document.activeIndex(at: position).map { document.lines[$0] }
                    let estimated = current.map { LyricReveal.timeline(for: $0).isEstimated } == true
                    Text("歌词 · " + document.sourceDescription + (estimated ? " · 字词时间含估算" : ""))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(palette.text.opacity(0.5))
                        .lineLimit(1).padding(.horizontal, 22).padding(.top, 13)
                        .accessibilityLabel("歌词来源：" + document.sourceDescription + (estimated ? "，部分字词时间根据歌词时间与语句长度估算" : "")).allowsHitTesting(false)
                }
            }
    }
}

private struct LyricsStatusView: View {
    @Environment(\.appPalette) private var palette
    var symbol: String
    var title: String
    var detail: String? = nil
    var isLoading = false
    var body: some View {
        VStack(spacing: 17) {
            if isLoading { ProgressView().controlSize(.small).tint(palette.accent) }
            else { Image(systemName: symbol).font(.system(size: 27, weight: .ultraLight)).foregroundStyle(palette.accent.opacity(0.55)) }
            Text(title).font(.system(size: 21, weight: .light)).foregroundStyle(palette.text.opacity(0.85))
            if let detail, !detail.isEmpty {
                Text(detail).font(.system(size: 12)).foregroundStyle(palette.secondary).multilineTextAlignment(.center).lineSpacing(5).frame(maxWidth: 330)
            }
        }.padding(24)
    }
}

enum LyricsScrollAnchor {
    static func id(document: LyricDocument, position: Double) -> Int? {
        if let index = document.activeIndex(at: position) { return document.lines[index].id }
        // SRT interludes retain the last reached row without highlighting it.
        // Before the first timestamp, start at the first row.
        return document.lines.last(where: { ($0.start ?? .infinity) <= position })?.id ?? document.lines.first?.id
    }
}

struct ScrollLyricsView: View {
    @Environment(\.appPalette) private var palette
    var document: LyricDocument
    var position: Double
    var isPlaying: Bool
    var reduceMotion: Bool
    var onSeek: (Double) -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var isFollowing = true
    @State private var resumeTask: Task<Void, Never>?
    @State private var latestAnchorID: Int?
    private var activeID: Int? { document.activeIndex(at: position).map { document.lines[$0].id } }
    private var anchorID: Int? { LyricsScrollAnchor.id(document: document, position: position) }
    private var prefersReducedMotion: Bool { reduceMotion || systemReduceMotion }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 25) {
                        ForEach(document.lines) { line in
                            LyricRowView(line: line, active: line.id == activeID, plain: document.timing == .plain,
                                         width: geometry.size.width, reduceMotion: prefersReducedMotion,
                                         position: position, isPlaying: isPlaying) { start in
                                resumeTask?.cancel(); isFollowing = true; latestAnchorID = line.id
                                onSeek(start); center(proxy, target: line.id)
                            }.id(line.id)
                        }
                    }
                    .padding(.horizontal, max(18, min(42, geometry.size.width * 0.065)))
                    .padding(.vertical, max(32, geometry.size.height * 0.44))
                }
                .scrollIndicators(.hidden)
                .mask { LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.13), .init(color: .black, location: 0.84), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom) }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting || phase == .tracking {
                        resumeTask?.cancel(); isFollowing = false
                    } else if phase == .idle, !isFollowing, isPlaying { scheduleFollow(proxy) }
                }
                .onChange(of: anchorID) { _, target in
                    latestAnchorID = target
                    if isFollowing { center(proxy, target: target) }
                }
                .onChange(of: isPlaying) { _, playing in
                    resumeTask?.cancel()
                    if playing, !isFollowing { scheduleFollow(proxy) }
                }
                .onChange(of: document) { _, _ in
                    resumeTask?.cancel(); isFollowing = true; latestAnchorID = anchorID
                    center(proxy, target: anchorID, animated: false)
                }
                .onAppear { latestAnchorID = anchorID; center(proxy, target: anchorID, animated: false) }
                .onDisappear { resumeTask?.cancel() }
                .overlay(alignment: .bottom) {
                    if !isFollowing, document.timing != .plain {
                        Button {
                            resumeTask?.cancel(); isFollowing = true; center(proxy)
                        } label: {
                            Label("回到当前歌词", systemImage: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: .capsule)
                                .overlay(Capsule().strokeBorder(palette.accent.opacity(0.2)))
                        }.buttonStyle(.plain).foregroundStyle(palette.text).padding(.bottom, 14)
                    } else if document.timing == .plain {
                        Text("纯文本歌词 · 无时间标记").font(.system(size: 10)).foregroundStyle(palette.secondary).padding(.bottom, 12)
                    }
                }
            }
        }.accessibilityLabel("滚动歌词")
    }

    private func scheduleFollow(_ proxy: ScrollViewProxy) {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            // latestAnchorID is @State, so this delayed closure never uses the
            // playback position captured eight seconds earlier.
            isFollowing = true; center(proxy)
        }
    }

    private func center(_ proxy: ScrollViewProxy, target: Int? = nil, animated: Bool = true) {
        guard let target = target ?? latestAnchorID ?? anchorID else { return }
        if prefersReducedMotion || !animated { proxy.scrollTo(target, anchor: .center) }
        else { withAnimation(.smooth(duration: 0.62)) { proxy.scrollTo(target, anchor: .center) } }
    }
}

/// Shared by the live scroll view and its explicitly static offscreen style
/// sample; the sample never claims to validate native scrolling behavior.
struct LyricRowView: View {
    @Environment(\.appPalette) private var palette
    var line: LyricLine
    var active: Bool
    var plain: Bool
    var width: CGFloat
    var reduceMotion: Bool
    var position: Double? = nil
    var isPlaying = false
    var onSeek: (Double) -> Void
    @State private var hover = false
    @State private var anchorDate = Date()
    @State private var anchorPosition: Double?
    @State private var frozenPosition: Double?
    @Environment(\.scenePhase) private var scenePhase
    private var fontSize: CGFloat { min(31, max(22, width * 0.062)) }
    private var animates: Bool { active && isPlaying && !reduceMotion && scenePhase == .active }
    var body: some View {
        Button { if let start = line.start { onSeek(start) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 13) {
                Circle().fill(active ? palette.accent : .clear).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 7 }
                VStack(alignment: .leading, spacing: 9) {
                    let reading = LyricTypography.readingText(line.text, width: max(1, width - 44), fontSize: fontSize)
                    Group {
                        if active, !plain, position != nil {
                            TimelineView(.animation(minimumInterval: 1 / 60, paused: !animates)) { tick in
                                LyricProgressText(line: line, text: reading, position: visualPosition(tick.date),
                                                  appearance: .highlight, reduceMotion: reduceMotion)
                            }
                        } else { Text(reading) }
                    }
                        .font(.system(size: fontSize, weight: active ? .semibold : .medium))
                        .foregroundStyle(active || hover || plain ? palette.text : palette.text.opacity(0.31))
                        .lineSpacing(8).fixedSize(horizontal: false, vertical: true)
                    if let translation = line.translation, !translation.isEmpty {
                        Text(translation).font(.system(size: 13, weight: .regular)).lineSpacing(4)
                            .foregroundStyle(palette.text.opacity(active ? 0.6 : 0.24)).fixedSize(horizontal: false, vertical: true)
                    }
                    if let start = line.start {
                        Text(Self.time(start)).font(.system(size: 9, design: .monospaced)).tracking(0.8)
                            .foregroundStyle(palette.secondary.opacity(active || hover ? 0.9 : 0.4))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.vertical, 4).contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(line.start == nil)
        .onHover { hover = $0 }
        .onAppear { resetProjection() }
        .onChange(of: position) { _, _ in resetProjection() }
        .onChange(of: line) { _, _ in resetProjection() }
        .onChange(of: scenePhase) { _, _ in resetProjection() }
        .onChange(of: isPlaying) { wasPlaying, playing in
            let now = Date()
            frozenPosition = wasPlaying && !playing && anchorPosition == position
                ? LyricPlaybackProjection.position(position ?? 0, anchoredAt: anchorDate, now: now, cueEnd: line.end)
                : nil
            anchorPosition = position; anchorDate = now
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.32), value: active)
        .accessibilityLabel(line.text)
        .accessibilityValue(active ? "当前歌词" : "")
        .accessibilityHint(line.start.map { "跳转到 \(Self.time($0))" } ?? "无时间标记")
    }
    private func visualPosition(_ date: Date) -> Double {
        guard let position else { return line.start ?? 0 }
        if !isPlaying { return frozenPosition ?? position }
        guard animates, anchorPosition == position else { return position }
        return LyricPlaybackProjection.position(position, anchoredAt: anchorDate, now: date, cueEnd: line.end)
    }
    private func resetProjection() {
        anchorDate = Date(); anchorPosition = position
        frozenPosition = isPlaying ? nil : position
    }
    private static func time(_ value: Double) -> String { let seconds = max(0, Int(value)); return String(format: "%d:%02d", seconds / 60, seconds % 60) }
}

/// One production drawing path is also used by the offscreen temporal QA.
@MainActor enum LyricStageRenderer {
    static func draw(in context: inout GraphicsContext, frame: LyricStageFrame, position: Double) {
        for piece in frame.fragments {
            var layer = context
            layer.opacity = piece.opacity
            layer.translateBy(x: piece.center.x, y: piece.center.y)
            layer.rotate(by: .degrees(piece.rotation))
            layer.scaleBy(x: piece.scale, y: piece.scale)
            if let accent = piece.accent {
                layer.scaleBy(x: CGFloat(accent.scaleX), y: CGFloat(accent.scaleY))
            }
            // Provider fragments can be syllables or individual letters. Their
            // reading brightness must follow the same complete-word reveal.
            let upcoming = piece.timedStart.map { position < (piece.revealUnits.map(\.revealStart).min() ?? $0) } ?? false
            let passed = piece.timedEnd.map { position >= (piece.revealUnits.map(\.revealEnd).max() ?? $0) } ?? false
            let level = piece.role == .completingAccent ? piece.glyphOpacity : (upcoming ? 0.32 : (passed ? 0.72 : 1.0))
            if let accent = piece.accent, piece.role == .primary || piece.role == .completingAccent {
                LyricAccentRenderer.drawMark(in: &layer, piece: piece, accent: accent)
            }
            LyricGlyphRenderer.draw(in: &layer, piece: piece, position: position, readingLevel: level)
        }
    }
}

/// No clock and no model dependencies: a screenshot of this view samples exactly
/// the same stage and renderer as the live lyric player at the requested time.
struct KineticLyricFrameView: View {
    @Environment(\.appPalette) private var palette
    var document: LyricDocument
    var position: Double
    var reduceMotion: Bool = false
    var audio = VisualizationAudio()
    var showsInterlude = false
    var completionsOnly = false
    var body: some View {
        GeometryReader { geometry in
            let frame = LyricTypography.frame(document: document, position: position, in: geometry.size, reduceMotion: reduceMotion, audio: audio)
            Canvas { context, _ in
                let rendered = completionsOnly ? LyricStageFrame(activeLineID: nil,
                    fragments: frame.fragments.filter { $0.role == .completingAccent }) : frame
                LyricStageRenderer.draw(in: &context, frame: rendered, position: position)
            }.colorMultiply(AppPalette.listeningRoom.text).overlay {
                if showsInterlude && frame.activeLineID == nil && frame.fragments.isEmpty {
                    VStack(spacing: 16) {
                        HStack(spacing: 8) { ForEach(0..<3) { _ in Circle().fill(palette.text.opacity(0.35)).frame(width: 4, height: 4) } }
                        Text(position < (document.lines.first?.start ?? 0) ? "等待第一句" : "间奏")
                            .font(.system(size: 11, weight: .light)).tracking(4).foregroundStyle(palette.text.opacity(0.42))
                    }
                }
            }
        }.clipped().accessibilityHidden(true)
    }
}

struct KineticLyricsView: View {
    @Environment(\.appPalette) private var palette
    var document: LyricDocument
    var position: Double
    var isPlaying: Bool
    var reduceMotion: Bool
    var onSeek: (Double) -> Void
    var signal: (@MainActor () -> AudioLevels)? = nil
    @State private var rhythm = LyricRhythmClock()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var anchorDate = Date()
    @State private var anchorPosition: Double = 0
    @State private var frozenPosition: Double?
    private var activeIndex: Int? { document.activeIndex(at: position) }
    private var activeLine: LyricLine? { activeIndex.map { document.lines[$0] } }
    private var prefersReducedMotion: Bool { reduceMotion || systemReduceMotion }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let line = activeLine, requiresReadingLayout(line, in: geometry.size) {
                    longLine(line, width: geometry.size.width).id(line.id)
                        .overlay { animatedStage(completionsOnly: true).allowsHitTesting(false) }
                } else {
                    VStack(spacing: 0) {
                        animatedStage(completionsOnly: false)
                        Group {
                            if let translation = activeLine?.translation, !translation.isEmpty {
                                Text(translation).font(.system(size: 14, weight: .regular)).foregroundStyle(palette.text.opacity(0.55))
                                    .multilineTextAlignment(.center).lineSpacing(4).lineLimit(3).minimumScaleFactor(0.8)
                                    .frame(maxWidth: min(620, geometry.size.width * 0.78))
                            } else { Color.clear.frame(height: 1) }
                        }.frame(height: 58).frame(maxWidth: .infinity)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { seekCurrentLine() }
                    .help("从这句播放")
                }
            }
            .onChange(of: position) { old, new in
                if abs(new - old) > 0.5 { rhythm.reset() }
                anchorPosition = new; anchorDate = Date()
                if !isPlaying { frozenPosition = new }
            }
            .onChange(of: isPlaying) { old, playing in
                let now = Date()
                rhythm.suspend()
                if old && !playing { frozenPosition = projectedPosition(now) }
                else { frozenPosition = nil }
                anchorPosition = position; anchorDate = now
            }
            .onChange(of: document) { _, _ in
                rhythm.reset()
                anchorPosition = position; anchorDate = Date(); frozenPosition = isPlaying ? nil : position
            }
            .onChange(of: scenePhase) { _, _ in rhythm.suspend() }
            .onChange(of: prefersReducedMotion) { _, _ in rhythm.suspend() }
            .onAppear { anchorPosition = position; anchorDate = Date(); frozenPosition = isPlaying ? nil : position }
        }
        // A single stable accessible element announces the actual current line,
        // not only the generic presentation name or decorative duplicate text.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activeLine.map { "动态字幕，" + $0.text } ?? "动态字幕，间奏")
        .accessibilityValue(activeLine?.translation ?? "")
        .accessibilityAction(named: "从这句播放") { seekCurrentLine() }
    }

    private func requiresReadingLayout(_ line: LyricLine, in size: CGSize) -> Bool {
        if line.text.count > 220 || line.words.count > 48 { return true }
        // Evaluate a stationary pose, so an animated size change never switches
        // between the canvas and the reading view in the middle of a cue.
        let stageSize = CGSize(width: size.width, height: max(1, size.height - 58))
        if LyricTypography.needsReadingLayout(line: line, in: stageSize) { return true }
        let frame = LyricTypography.frame(document: document, position: line.start ?? position,
                                         in: stageSize, reduceMotion: true)
        return frame.fragments.filter { $0.role == .primary }.contains { $0.fontSize < 16 }
    }
    private func seekCurrentLine() { if let start = activeLine?.start { onSeek(start) } }
    private func visualPosition(_ date: Date) -> Double {
        if !isPlaying { return frozenPosition ?? position }
        guard !prefersReducedMotion, scenePhase == .active else { return position }
        return projectedPosition(date)
    }
    private func projectedPosition(_ date: Date) -> Double {
        guard anchorPosition == position else { return position }
        // Interpolation is bounded by the player's short observer cadence and
        // never advances into a future lyric before its authoritative cue.
        return LyricPlaybackProjection.position(position, anchoredAt: anchorDate, now: date, cueEnd: activeLine?.end)
    }
    private func animatedStage(completionsOnly: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !isPlaying || prefersReducedMotion || scenePhase != .active)) { timeline in
            let seconds = visualPosition(timeline.date)
            let audio = rhythm.sample(at: timeline.date, levels: signal?() ?? AudioLevels(),
                                      animated: isPlaying && !prefersReducedMotion && scenePhase == .active)
            KineticLyricFrameView(document: document, position: seconds, reduceMotion: prefersReducedMotion,
                                 audio: audio, showsInterlude: !completionsOnly, completionsOnly: completionsOnly)
        }
    }
    private func longLine(_ line: LyricLine, width: CGFloat) -> some View {
        ScrollView {
            Button { if let start = line.start { onSeek(start) } } label: {
                VStack(alignment: .leading, spacing: 24) {
                    let reading = LyricTypography.readingText(line.text, width: min(760, max(120, width - 80)), fontSize: 28)
                    TimelineView(.animation(minimumInterval: 1 / 60, paused: !isPlaying || prefersReducedMotion || scenePhase != .active)) { tick in
                        LyricProgressText(line: line, text: reading, position: visualPosition(tick.date),
                                          appearance: .reveal, reduceMotion: prefersReducedMotion)
                    }
                        .font(.system(size: 28, weight: .medium)).lineSpacing(12).foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let translation = line.translation {
                        Text(translation).font(.system(size: 14)).lineSpacing(5).foregroundStyle(palette.text.opacity(0.58))
                    }
                }.frame(maxWidth: min(760, max(120, width - 80)), alignment: .leading).padding(.vertical, 52).padding(.horizontal, 40)
                    .contentShape(.rect)
            }.buttonStyle(.plain).accessibilityHint("从这句播放")
        }.scrollIndicators(.visible)
    }
}

/// Only referenced by the standalone QA harness. These are original sentences,
/// never bundled as substitute lyrics for real tracks.
enum LyricsQAFixture {
    static let duration: Double = 68
    static let document = LyricDocument(lines: [
        .init(id: 0, text: "把夜色折成一封信", start: 2, end: 9, translation: "Fold the night into a letter"),
        .init(id: 1, text: "We leave a little light beside the rain", start: 9, end: 16, translation: "在雨的身旁，留一小片光"),
        .init(id: 2, text: "风经过 空白的页", start: 16, end: 23),
        .init(id: 3, text: "There is room for every quiet beginning", start: 23, end: 30),
        .init(id: 4, text: "让此刻慢慢靠近", start: 30, end: 38, words: [.init(id: 0, text: "让", start: 30, end: 31), .init(id: 1, text: "此刻", start: 31, end: 33), .init(id: 2, text: "慢慢", start: 33, end: 35), .init(id: 3, text: "靠近", start: 35, end: 38)]),
        .init(id: 5, text: "and the world becomes a softer place", start: 40, end: 50, translation: "世界，渐渐柔软"),
        .init(id: 6, text: "海风轻轻带走昨日的回声", start: 50, end: 58, translation: "The sea carries yesterday away"),
        .init(id: 7, text: "We make room for the light to return", start: 58, end: 66, translation: "为再次到来的光，留一处空白")
    ], timing: .word, sourceDescription: "原创排版测试", title: "Quiet Letters", artist: "AlpacaMusic QA")
}

struct LyricsQAPreview: View {
    var mode: LyricPresentationMode = .kinetic
    var position: Double = 12
    var isPlaying = false
    var reduceMotion = false
    var onSeek: (Double) -> Void = { _ in }
    var body: some View {
        LyricsPresentationView(document: LyricsQAFixture.document, status: .ready, error: nil, mode: mode, position: position, isPlaying: isPlaying, reduceMotion: reduceMotion, onSeek: onSeek)
            .appTheme(.listeningRoom)
    }
}
