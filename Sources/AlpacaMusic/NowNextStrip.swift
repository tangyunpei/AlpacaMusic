import SwiftUI

/// What plays after the current song, in a strip under the stage. In order,
/// as many songs as fit; under shuffle, the one queued to play next, if any,
/// and how many shuffle still picks from.
struct NowNextStrip: View {
    @Environment(\.nowMotion) private var motion
    let model: AppModel
    let pageWidth: CGFloat
    /// Songs the strip has room for.
    let room: Int
    /// How much of the label gutter shows: the strip's name grows into it.
    let gutter: CGFloat

    var body: some View {
        let style = NowStageStyle(light: model.visualMode == .bauhaus)
        let palette = style.palette
        HStack(spacing: 0) {
            NowLabelSlot(amount: gutter) {
                Text(L10n.string("接下来")).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).textCase(.uppercase)
                    .foregroundStyle(palette.secondary).fixedSize().opacity(Double(1 - gutter))
                Text(L10n.string("接下来")).font(.system(size: 26, weight: .light)).tracking(-0.4)
                    .foregroundStyle(palette.text).fixedSize().opacity(Double(gutter))
                    .accessibilityHidden(true)
            }
            .accessibilityAddTraits(.isHeader)
            NowNextSongs(model: model, room: room, style: style)
                // Narrower than its songs, the row clips the last one, as on the canvas.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
            NowQueueButton(model: model, style: style)
                .padding(.leading, 12)
        }
        .padding(.horizontal, NowLayout.sidePadding)
        .frame(width: pageWidth, height: NowLayout.nextStripHeight)
        .background(palette.panel)
        .appTheme(palette)
        .animation(motion.reduced ? nil : ExperienceMotion.visualization, value: style.light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("接下来"))
        .accessibilityIdentifier("now-next")
    }
}

/// The songs themselves. A song that joins or leaves moves in or out while
/// the others slide along; a resize alone leaves this part be.
private struct NowNextSongs: View {
    @Environment(\.nowMotion) private var motion
    let model: AppModel
    let room: Int
    let style: NowStageStyle

    var body: some View {
        let shuffle = model.player.shuffle
        let upcoming = model.player.upcoming(limit: room)
        HStack(spacing: 0) {
            ForEach(upcoming.tracks) { track in
                NowNextItem(model: model, track: track, tagged: shuffle, style: style)
                    .transition(.opacity.combined(with: .offset(x: 14)))
            }
            if shuffle {
                NowShufflePile(model: model, count: upcoming.shuffled, after: upcoming.tracks.first, style: style)
                    .transition(.opacity)
            } else if upcoming.tracks.isEmpty {
                Text(L10n.string("之后没有排队的歌曲")).font(.system(size: 11)).foregroundStyle(style.palette.secondary).lineLimit(1)
                    .transition(.opacity)
            }
        }
        // Songs on their way in or out stay with the strip while the page reshapes.
        .geometryGroup()
        .animation(motion.reflow, value: upcoming.tracks.map(\.id))
        .animation(motion.reflow, value: shuffle)
    }
}

private struct NowQueueButton: View {
    let model: AppModel
    let style: NowStageStyle
    var body: some View {
        let palette = style.palette
        Button { withAnimation(.smooth(duration: 0.22)) { model.queueOpen.toggle() } } label: {
            Label(L10n.string("队列 · \(model.player.queue.count)"), systemImage: "list.bullet")
                .font(.system(size: 11)).lineLimit(1).monospacedDigit()
                .padding(.horizontal, 12).frame(height: 34)
                .foregroundStyle(palette.accent)
                .background(model.queueOpen ? palette.accent.opacity(0.1) : .clear, in: .rect(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(style.chipLine))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.queueOpen ? .isSelected : [])
        .accessibilityIdentifier("now-queue")
    }
}

private struct NowNextItem: View {
    let model: AppModel
    let track: Track
    /// Under shuffle the one known song says that it plays next.
    let tagged: Bool
    let style: NowStageStyle
    @State private var hovered = false

    var body: some View {
        let palette = style.palette
        Button { model.play(track, context: model.player.queue) } label: {
            HStack(spacing: 10) {
                ArtworkView(track: track, radius: 6).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    if tagged {
                        Text(L10n.string("即将播放")).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.5)
                            .textCase(.uppercase).foregroundStyle(palette.accent).lineLimit(1)
                    }
                    Text(verbatim: track.title).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(hovered ? palette.accent : palette.text).lineLimit(1)
                    Text(verbatim: track.artist).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.trailing, 16)
            .frame(width: NowLayout.nextItemWidth, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu { TrackActions(track: track, model: model) }
        .help(L10n.string("播放 \(track.title)"))
        .accessibilityLabel(L10n.string("播放 \(track.title)，\(track.artist)"))
    }
}

/// Under shuffle the rest of the queue is a pile: which song comes off it
/// is decided when the current one ends.
private struct NowShufflePile: View {
    let model: AppModel
    let count: Int
    /// The song queued to play before the pile, if there is one.
    let after: Track?
    let style: NowStageStyle

    var body: some View {
        let palette = style.palette
        let covers = model.player.queue.filter { $0.id != model.player.current?.id && $0.id != after?.id && !$0.unavailable }.prefix(5)
        HStack(spacing: 14) {
            HStack(spacing: -14) {
                ForEach(Array(covers)) { track in
                    ArtworkView(track: track, radius: 6).frame(width: 40, height: 40)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.panel, lineWidth: 2).padding(-1))
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
                    .contentTransition(.numericText())
                if count > 0 {
                    Text(L10n.string("下一首在这首结束时选出")).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
                }
            }
        }
        .padding(.leading, after == nil ? 0 : 18)
        .overlay(alignment: .leading) {
            if after != nil { Rectangle().fill(style.chipLine).frame(width: 1, height: 40) }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if count == 0 { return L10n.string("之后没有排队的歌曲") }
        return after == nil ? L10n.string("随机播放其余 \(count) 首") : L10n.string("随后随机播放 \(count) 首")
    }
}
