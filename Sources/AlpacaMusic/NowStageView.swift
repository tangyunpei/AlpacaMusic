import AppKit
import SwiftUI

/// The top of the Now page: the visual the listener chose, with the song,
/// its lyric line and the controls that belong to what is playing.
///
/// Its parts each take only the sizes they show, so a resize lays them out
/// again but builds again only the few whose own sizes changed.
struct NowStageView: View {
    @Environment(\.nowMotion) private var motion
    let model: AppModel
    let metrics: NowStageMetrics

    var body: some View {
        let style = NowStageStyle(light: model.visualMode == .bauhaus)
        ZStack(alignment: .topLeading) {
            style.palette.background
            // The chosen visual, or the cover's wash of colour where the cover
            // shows instead. While one gives way to the other both are here; at
            // rest only one is, so a visual that is not shown costs nothing.
            if metrics.cover < 0.999 {
                NowStageVisual(model: model)
                    .frame(width: metrics.visualFrame.width, height: metrics.visualFrame.height)
                    .offset(x: metrics.visualFrame.minX, y: metrics.visualFrame.minY)
                    .opacity(Double(1 - metrics.cover))
            }
            if metrics.cover > 0.001 {
                ArtworkAtmosphere(track: model.activeTrack)
                    .frame(width: metrics.visualFrame.width, height: metrics.visualFrame.height)
                    .offset(x: metrics.visualFrame.minX, y: metrics.visualFrame.minY)
                    .opacity(Double(metrics.cover))
                    .accessibilityHidden(true)
            }
            NowStageScrim(style: style, stacked: metrics.stacked, textShare: metrics.textHeight / max(1, metrics.height))
                .allowsHitTesting(false)
            if metrics.cover > 0.001 {
                NowStageCover(model: model)
                    .frame(width: metrics.coverFrame.width, height: metrics.coverFrame.height)
                    .scaleEffect(0.94 + 0.06 * metrics.cover)
                    .offset(x: metrics.coverFrame.minX, y: metrics.coverFrame.minY)
                    .opacity(Double(metrics.cover))
            }
            NowStageText(model: model, metrics: metrics, style: style)
                .frame(width: metrics.contentWidth, alignment: .bottomLeading)
                .padding(.horizontal, NowLayout.sidePadding).padding(.bottom, 26)
                .frame(width: metrics.pageWidth, height: metrics.height, alignment: .bottomLeading)
            NowStageProgress(model: model, style: style)
                .frame(width: metrics.pageWidth, height: metrics.height, alignment: .bottomLeading)
        }
        .frame(width: metrics.pageWidth, height: metrics.height, alignment: .topLeading)
        .clipped()
        .appTheme(style.palette)
        .animation(motion.reduced ? nil : ExperienceMotion.visualization, value: style.light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("正在播放"))
        .accessibilityIdentifier("now-stage")
    }
}

/// When the stage shows the song's cover, and why.
@MainActor enum NowCover {
    /// A visual that draws measured audio has nothing to draw for a source
    /// that gives none. The cover stands in while such a song plays. The
    /// listener's choice is not touched, so it is back with the next song
    /// that has live audio. Whether a source can give audio decides this, not
    /// whether samples have arrived: a song still loading keeps its visual.
    static func standsIn(_ model: AppModel) -> Bool {
        model.player.current?.source.supportsAudioAnalysis == false && model.visualMode.isSignalDisplay
    }
    /// The cover shows: as the chosen visual, or standing in for one.
    static func shows(_ model: AppModel) -> Bool { model.visualMode == .artwork || standsIn(model) }
}

/// The listener's visual, drawn as the room draws it. One scene at a time:
/// while the room is open it has the scene and the stage rests.
///
/// The cover has its own place on the stage, so this never draws Album
/// artwork: when the cover takes over, the visual that was showing stays as
/// it was while it fades.
private struct NowStageVisual: View {
    @Environment(\.nowMotion) private var motion
    let model: AppModel
    /// The visual last drawn here.
    @State private var last: VisualizationMode?

    var body: some View {
        let chosen = model.visualMode
        let mode = chosen == .artwork ? last ?? chosen : chosen
        ZStack {
            if !model.immersive {
                MusicVisualizationView(track: model.activeTrack, mode: mode, settings: model.visual,
                                       // A visual on its way out for want of audio rests rather than wait for samples.
                                       isPlaying: model.player.status == .playing && !NowCover.standsIn(model),
                                       signal: { model.player.readLevels() }, showsStatus: false, showsMissingAudioStatus: false)
                    .id(mode).transition(.opacity)
            }
        }
        .animation(motion.reduced ? nil : ExperienceMotion.visualization, value: mode)
        .onChange(of: chosen, initial: true) { _, new in if new != .artwork { last = new } }
    }
}

/// The song's cover on the stage, drawn as the Album artwork visual draws it.
private struct NowStageCover: View {
    @Environment(\.nowMotion) private var motion
    let model: AppModel
    var body: some View {
        let track = model.activeTrack
        ZStack {
            ArtworkView(track: track, radius: 10, highResolution: true)
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.16), lineWidth: 0.7) }
                .id(track?.id)
                .transition(.opacity)
        }
        .shadow(color: .black.opacity(0.34), radius: 36, x: 0, y: 22)
        .animation(motion.reflow, value: track?.id)
        .allowsHitTesting(false)
    }
}

/// Keeps the text readable over the visual: from the side when they stand
/// side by side, from below when the visual spans the stage. Each is solid
/// up to the visual's own edge, so a visual that paints its own background
/// never shows that edge, and clears over the next part of it.
private struct NowStageScrim: View {
    let style: NowStageStyle
    let stacked: CGFloat
    /// The text's share of the stage's height.
    let textShare: CGFloat
    var body: some View {
        let ink = style.palette.background
        let below = min(0.7, max(0.1, textShare))
        ZStack {
            LinearGradient(stops: [.init(color: ink, location: 0), .init(color: ink, location: 0.38),
                                   .init(color: ink.opacity(0), location: style.light ? 0.56 : 0.66)],
                           startPoint: .leading, endPoint: .trailing)
                .opacity(Double(1 - stacked))
            LinearGradient(stops: [.init(color: ink, location: 0), .init(color: ink, location: below),
                                   .init(color: ink.opacity(0), location: min(1, below + 0.22))],
                           startPoint: .bottom, endPoint: .top)
                .opacity(Double(stacked))
        }
    }
}

private enum NowStagePhase {
    case idle, paused, playing

    @MainActor init(_ player: PlayerController) {
        if player.current == nil { self = .idle }
        else { self = player.status == .playing || player.status == .loading ? .playing : .paused }
    }
}

/// What the stage's button starts when nothing is playing.
enum NowStart {
    case picks(MusicSource, [Track])
    case library([Track])
    case importMusic

    @MainActor static func current(_ model: AppModel) -> NowStart {
        if let source = model.browse.current, let songs = model.browse.entry(for: source)?.picks.value?.songs,
           songs.contains(where: { !$0.unavailable }) {
            return .picks(source, songs)
        }
        let tracks = model.library.tracks
        return tracks.contains { !$0.unavailable } ? .library(tracks) : .importMusic
    }
}

/// The stage's words, bottom left, and its controls, bottom right. The
/// song's name takes the stage's whole width; the controls stand beside the
/// lines under it.
private struct NowStageText: View {
    let model: AppModel
    let metrics: NowStageMetrics
    let style: NowStageStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NowStageEyebrow(model: model, gutter: metrics.gutter, style: style)
            NowStageTitle(model: model, size: metrics.titleSize, style: style)
                .padding(.top, 10)
                // The name ends before a cover that stands beside it.
                .padding(.trailing, (metrics.coverFrame.width + 24) * metrics.cover * (1 - metrics.stacked))
            HStack(alignment: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    NowStageSubtitle(model: model)
                        .padding(.top, 8)
                    NowStageAction(model: model)
                        .padding(.top, 18)
                        .nowReveal(metrics.action)
                    NowStageLyrics(model: model, size: metrics.lyricSize, nextSize: metrics.lyricNextSize, style: style)
                        .padding(.top, 16)
                        .nowReveal(metrics.lyrics)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                NowStageSide(model: model, compactNext: metrics.compactNext, gutter: metrics.gutter, style: style)
                    // As wide as the cover above it, so the lines beside it end before the cover too.
                    .frame(minWidth: metrics.coverFrame.width * metrics.cover * (1 - metrics.stacked), alignment: .trailing)
                    .padding(.leading, 24)
                    .fixedSize()
            }
        }
        .padding(.leading, max(0, metrics.rowInset))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            NowStageName(model: model, style: style)
                .offset(x: (metrics.gutter - 1) * 18)
                .opacity(Double(metrics.gutter))
                .accessibilityHidden(metrics.gutter < 0.5)
        }
    }
}

/// A song's name or line giving way to the next: the old one leaves upward as the new one arrives from below.
@MainActor private var nowStageSwap: AnyTransition {
    .asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity.combined(with: .offset(y: -14)))
}

/// "Now" and what it is doing, in the gutter.
private struct NowStageName: View {
    let model: AppModel
    let style: NowStageStyle
    var body: some View {
        let word: String = switch NowStagePhase(model.player) {
        case .idle: L10n.string("空闲")
        case .paused: L10n.string("已暂停")
        case .playing: model.player.status == .loading ? L10n.string("载入中") : L10n.string("播放中")
        }
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.string("此刻")).font(.system(size: 26, weight: .light)).tracking(-0.4).foregroundStyle(style.palette.text)
            Text(word).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).textCase(.uppercase)
                .foregroundStyle(style.palette.secondary)
        }
        .fixedSize()
    }
}

/// The source of the song. Without a gutter it also says what the gutter would.
private struct NowStageEyebrow: View {
    let model: AppModel
    let gutter: CGFloat
    let style: NowStageStyle
    var body: some View {
        let phase = NowStagePhase(model.player)
        let prefix: String = switch phase {
        case .idle: L10n.string("此刻")
        case .paused: L10n.string("已暂停")
        case .playing: L10n.string("此刻播放")
        }
        HStack(spacing: 0) {
            Text(verbatim: prefix + " · ").fixedSize().nowReveal(1 - gutter, axis: .horizontal)
            Text(verbatim: model.player.current?.sourcePlaybackTitle ?? L10n.string("未在播放"))
            if phase == .paused { NowPausedClock(model: model) }
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).textCase(.uppercase)
        .foregroundStyle(style.palette.secondary).lineLimit(1)
        .frame(height: 12)
    }
}

/// Reads the playback clock only while a paused song shows where it stopped.
private struct NowPausedClock: View {
    let model: AppModel
    var body: some View {
        let duration = model.player.duration
        if duration.isFinite, duration > 0 {
            Text(verbatim: " · \(formattedTime(model.player.position)) / \(formattedTime(duration))")
        }
    }
}

private struct NowStageTitle: View {
    @Environment(\.nowMotion) private var motion
    let model: AppModel
    let size: CGFloat
    let style: NowStageStyle
    var body: some View {
        let track = model.player.current
        ZStack(alignment: .leading) {
            Text(verbatim: track?.title ?? L10n.string("未在播放"))
                .font(.system(size: size, weight: .light)).tracking(-0.5)
                .foregroundStyle(style.palette.text).lineLimit(1).truncationMode(.tail)
                .id(track?.id ?? "now-stage-idle").transition(nowStageSwap)
        }
        .frame(maxWidth: .infinity, minHeight: size * 1.08, maxHeight: size * 1.08, alignment: .leading)
        // A name on its way out stays with this line while the stage reshapes around it.
        .geometryGroup()
        .animation(motion.reflow, value: track?.id)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct NowStageSubtitle: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.nowMotion) private var motion
    let model: AppModel
    var body: some View {
        let track = model.player.current
        ZStack(alignment: .leading) {
            Text(verbatim: text(track))
                .font(.system(size: 13)).foregroundStyle(palette.secondary).lineLimit(1).truncationMode(.tail)
                .id(track?.id ?? "now-stage-idle").transition(nowStageSwap)
        }
        .frame(maxWidth: .infinity, minHeight: 17, maxHeight: 17, alignment: .leading)
        .geometryGroup()
        .animation(motion.reflow, value: track?.id)
    }
    private func text(_ track: Track?) -> String {
        guard let track else {
            return switch NowStart.current(model) {
            case .picks: L10n.string("从今日推荐开始，或在下方任选。")
            case .library: L10n.string("从你的音乐库开始，或在下方任选。")
            case .importMusic: L10n.string("导入音乐，或在音源页连接一个音源。")
            }
        }
        return track.album.isEmpty ? track.artist : "\(track.artist) · \(track.album)"
    }
}

/// The stage's one button: play something when idle, resume when paused.
private struct NowStageAction: View {
    @Environment(\.appPalette) private var palette
    let model: AppModel
    /// What the button last offered, kept while it folds away after playback
    /// starts, so it does not change its words on the way out.
    @State private var offeredIdle = true

    var body: some View {
        let phase = NowStagePhase(model.player)
        let idle = phase == .playing ? offeredIdle : phase == .idle
        let start = NowStart.current(model)
        content(idle: idle, start: start)
            .onChange(of: phase, initial: true) { _, phase in
                if phase != .playing { offeredIdle = phase == .idle }
            }
    }

    private func content(idle: Bool, start: NowStart) -> some View {
        HStack(spacing: 12) {
            Button { act(idle: idle, start: start) } label: {
                Label(label(idle: idle, start: start), systemImage: symbol(idle: idle, start: start)).lineLimit(1)
            }
            .buttonStyle(PrimaryButtonStyle()).fixedSize()
            .accessibilityIdentifier("start-listening")
            if idle {
                Text(verbatim: hint(start)).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
            } else {
                NowResumeHint(model: model)
            }
        }
        .frame(height: 37)
    }

    private func symbol(idle: Bool, start: NowStart) -> String {
        if idle, case .importMusic = start { return "plus" }
        return "play.fill"
    }
    private func label(idle: Bool, start: NowStart) -> String {
        guard idle else { return L10n.string("继续播放") }
        return switch start {
        case .picks: L10n.string("播放今日推荐")
        case .library: L10n.string("播放音乐库")
        case .importMusic: L10n.string("导入音乐")
        }
    }
    private func hint(_ start: NowStart) -> String {
        switch start {
        case .picks(let source, let songs): L10n.string("\(songs.count) 首 · 来自\(source.title)")
        case .library(let tracks): L10n.string("\(tracks.count) 首歌")
        case .importMusic: L10n.string("从这台 Mac 选择音频文件")
        }
    }
    private func act(idle: Bool, start: NowStart) {
        guard idle else { Task { await model.toggle() }; return }
        switch start {
        case .picks(_, let songs):
            if let first = songs.first(where: { !$0.unavailable }) { model.play(first, context: songs) }
        case .library(let tracks):
            if let first = tracks.first(where: { !$0.unavailable }) { model.play(first, context: tracks) }
        case .importMusic:
            model.beginImport(folder: false)
        }
    }
}

private struct NowResumeHint: View {
    @Environment(\.appPalette) private var palette
    let model: AppModel
    var body: some View {
        Text(verbatim: L10n.string("从 \(formattedTime(model.player.position)) 继续"))
            .font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
    }
}

/// The line being sung and the one after it. Paused, the line rests in the unsung ink.
private struct NowStageLyrics: View {
    let model: AppModel
    let size: CGFloat
    let nextSize: CGFloat
    let style: NowStageStyle
    var body: some View {
        CompactLyricLines(model: model, primarySize: size, secondarySize: nextSize, alignment: .leading, fallback: .hidden,
                          look: CompactLyricLook(weight: .medium, unsungOpacity: style.unsung,
                                                 showsProgress: model.player.status == .playing || model.player.status == .loading,
                                                 nextInSecondaryInk: true, spacing: 4))
            .frame(height: size * 1.3 + 4 + nextSize * 1.3, alignment: .topLeading)
    }
}

/// The stage's lower right: what comes next when the strip has no room, the
/// visual's name and the room.
private struct NowStageSide: View {
    let model: AppModel
    let compactNext: CGFloat
    /// How much of the label gutter shows; with it the visual's button has room for a word more.
    let gutter: CGFloat
    let style: NowStageStyle

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            // A line that is folded away takes no width either, so the words beside the column keep theirs.
            NowCompactNext(model: model, style: style)
                .padding(.bottom, 12)
                .nowReveal(compactNext, foldsAcross: true, anchor: .topTrailing)
            // Each button keeps its own width. Left to share the row, the one with
            // less to give is offered half of it first and cuts its name short.
            HStack(spacing: 8) {
                NowVisualChip(model: model, gutter: gutter, style: style).fixedSize()
                NowRoomChip(model: model, style: style).fixedSize()
            }
        }
    }
}

/// Names the visual on the stage and opens the list of visuals. While the
/// cover stands in for a visual that needs live audio, the visual keeps its
/// name here in the quieter ink, since it is still the listener's choice.
private struct NowVisualChip: View {
    let model: AppModel
    let gutter: CGFloat
    let style: NowStageStyle
    var body: some View {
        let palette = style.palette
        let mode = model.visualMode
        let standsIn = NowCover.standsIn(model)
        let waiting = L10n.string("\(mode.title)需要实时音频，这个音源没有，暂由专辑封面代替。")
        HStack(spacing: 0) {
            Label(mode.title, systemImage: mode.symbol)
            if standsIn {
                Text(L10n.string("· 无实时音频")).fixedSize().padding(.leading, 7)
                    .nowReveal(gutter, axis: .horizontal)
            }
        }
        .font(.system(size: 11)).lineLimit(1)
        .padding(.horizontal, 12).frame(height: 34)
        .foregroundStyle(standsIn ? palette.secondary : palette.accent)
        .background(style.chipFill, in: .rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(style.chipLine))
        .nowMenu {
            Picker(L10n.string("视觉效果"), selection: Binding(get: { model.visualMode }, set: { model.visualMode = $0 })) {
                ForEach(VisualizationMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
            }.pickerStyle(.inline)
            Divider()
            Button(L10n.string("调整视觉效果…")) { model.sheet = .visual }
        }
        .help(standsIn ? waiting : mode == .pointCloud ? L10n.string("拖动旋转 · 双击复位") : L10n.string("视觉效果：\(mode.title)"))
        .accessibilityLabel(L10n.string("选择视觉效果，当前为\(mode.title)"))
        .accessibilityValue(standsIn ? waiting : "")
        .accessibilityIdentifier("now-visual-menu")
    }
}

private struct NowRoomChip: View {
    let model: AppModel
    let style: NowStageStyle
    var body: some View {
        let palette = style.palette
        Button { withAnimation(.smooth(duration: 0.25)) { model.immersive = true } } label: {
            Label(L10n.string("进入沉浸空间"), systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 12).frame(height: 34)
                .foregroundStyle(palette.accent)
                .background(style.chipFill, in: .rect(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(style.roomLine))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("now-open-room")
    }
}

/// One line for the next song, shown on the stage when the window is too
/// short for the Next strip.
private struct NowCompactNext: View {
    let model: AppModel
    let style: NowStageStyle
    var body: some View {
        let palette = style.palette
        let upcoming = model.player.upcoming(limit: 1)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.string("接下来")).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).textCase(.uppercase)
                .foregroundStyle(palette.secondary)
            if let next = upcoming.tracks.first {
                Text(verbatim: next.title).foregroundStyle(palette.text)
                Text(verbatim: next.artist).foregroundStyle(palette.secondary)
            } else if model.player.shuffle, upcoming.shuffled > 0 {
                Text(L10n.string("随机播放其余 \(upcoming.shuffled) 首")).foregroundStyle(palette.secondary)
            } else {
                Text(L10n.string("之后没有排队的歌曲")).foregroundStyle(palette.secondary)
            }
        }
        .font(.system(size: 11)).lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 5)
        // A chip of its own, so the line reads over whatever the visual draws behind it.
        .background(style.chipFill, in: .rect(cornerRadius: 7))
        .frame(maxWidth: 340, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }
}

/// The song's progress along the stage's bottom edge.
private struct NowStageProgress: View {
    @Environment(\.nowMotion) private var motion
    let model: AppModel
    let style: NowStageStyle
    var body: some View {
        let duration = model.player.duration, position = model.player.position
        let fraction = duration.isFinite && duration > 0 && position.isFinite ? min(1, max(0, position / duration)) : 0
        NowProgressLine(fraction: fraction, track: NSColor(style.track), fill: NSColor(style.palette.accent), glides: !motion.reduced)
            .frame(height: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The line itself: two layers, the played one moved by Core Animation.
///
/// The player reports its position ten times a second and the line glides
/// from one report to the next. Gliding it as a SwiftUI animation makes the
/// page draw at every display refresh for as long as a song plays, and each
/// of those passes redraws the stage's text and shading with it; that held
/// the main thread for most of every frame. A layer animation runs outside
/// the app's drawing and costs it nothing between reports.
private struct NowProgressLine: NSViewRepresentable {
    var fraction: Double
    var track: NSColor
    var fill: NSColor
    var glides: Bool

    final class LineView: NSView {
        private let played = CALayer()
        private var fraction: CGFloat = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            played.anchorPoint = .zero
            layer?.addSublayer(played)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            place(glide: false)
        }

        func show(_ fraction: CGFloat, track: NSColor, fill: NSColor, glide: Bool) {
            layer?.backgroundColor = track.cgColor
            played.backgroundColor = fill.cgColor
            guard fraction != self.fraction else { return }
            self.fraction = fraction
            place(glide: glide)
        }

        /// A resize sets the line at once; a new report glides to it.
        private func place(glide: Bool) {
            CATransaction.begin()
            if glide {
                CATransaction.setAnimationDuration(0.1)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
            } else {
                CATransaction.setDisableActions(true)
            }
            played.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> LineView { LineView() }
    func updateNSView(_ view: LineView, context: Context) {
        view.show(CGFloat(fraction), track: track, fill: fill, glide: glides)
    }
}

// MARK: Search and Import

/// Search and Import at the stage's top right. They sit in the strip that
/// drags the window and are the only things there that take clicks.
struct NowStageChrome: View {
    let model: AppModel
    let scroll: NowScrollState
    /// How far a floating panel covers the stage's right end.
    let covered: CGFloat
    @FocusState private var searchFocused: Bool

    var body: some View {
        let style = NowStageStyle(light: model.visualMode == .bauhaus)
        HStack(spacing: 16) {
            MusicSearchField(model: model, focused: $searchFocused, fill: style.pillFill, line: style.pillLine, hint: style.palette.secondary)
            ImportMenu(model: model, plain: true)
        }
        .padding(.top, 10).padding(.trailing, NowLayout.sidePadding + covered)
        .appTheme(style.palette)
        .background {
            Button { scroll.topRequests &+= 1; searchFocused = true } label: { EmptyView() }
                .keyboardShortcut("k", modifiers: .command).hidden().frame(width: 0, height: 0)
        }
    }
}

/// The search field of the page header and of the Now stage.
struct MusicSearchField: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var focused: FocusState<Bool>.Binding
    var fill: Color
    var line: Color
    var hint: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(palette.secondary)
            TextField(L10n.string("搜索歌曲、艺术家或专辑"), text: $model.query).textFieldStyle(.plain).font(.system(size: 11))
                .focused(focused).onSubmit { model.search() }.accessibilityIdentifier("music-search")
            if !model.query.isEmpty {
                Button { model.navigate(model.destination) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain).help(L10n.string("清除搜索"))
            } else {
                Text("⌘ K").font(.system(size: 9)).foregroundStyle(hint)
            }
        }
        .padding(.horizontal, 11).frame(width: 270, height: 33)
        .background(fill, in: .rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(line))
    }
}

/// Import files, a folder or a link.
struct ImportMenu: View {
    @Environment(\.appPalette) private var palette
    let model: AppModel
    /// Drawn as plain text and a plus, without the menu's own arrow.
    var plain = false
    var body: some View {
        if plain {
            Label(L10n.string("导入"), systemImage: "plus").font(.system(size: 11)).foregroundStyle(palette.accent)
                .padding(.horizontal, 4).frame(height: 33)
                .nowMenu { items }
                .accessibilityLabel(L10n.string("导入"))
        } else {
            Menu { items } label: { Label(L10n.string("导入"), systemImage: "plus").font(.system(size: 11)) }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(palette.accent)
        }
    }
    @ViewBuilder private var items: some View {
        Group {
            Button(L10n.string("选择音频文件…")) { model.beginImport(folder: false) }
            Button(L10n.string("导入文件夹…")) { model.beginImport(folder: true) }
        }.disabled(model.library.busy)
        Divider()
        Button(L10n.string("添加音频链接…")) { model.sheet = .url }
    }
}

extension View {
    /// Opens a menu from this view. The view is drawn as it is: the system's
    /// own menu button would restyle the label and dim it in a window that
    /// is not in front, unlike the plain buttons beside it.
    func nowMenu<Items: View>(@ViewBuilder _ items: () -> Items) -> some View {
        overlay {
            Menu(content: items) { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(.rect) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        }
    }
}
