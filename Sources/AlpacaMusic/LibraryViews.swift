import SwiftUI

struct LibraryView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var body: some View {
        let tracks = model.visibleTracks
        VStack(alignment: .leading, spacing: 25) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 11) {
                    Text(model.pageTitle).font(.system(size: 29, weight: .regular)).tracking(1).foregroundStyle(palette.text)
                    Text(L10n.string("\(tracks.count) 首音乐")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                Spacer()
                if let playlist = model.selectedPlaylist { ToolButton(symbol: "trash", label: L10n.string("删除歌单")) { model.library.deletePlaylist(playlist.id); model.navigate(.library); model.notify(L10n.string("歌单已删除，歌曲仍在音乐库中")) } }
                Button { model.beginImport(folder: false) } label: { Label(L10n.string("添加音乐"), systemImage: "plus") }.buttonStyle(QuietButtonStyle())
            }
            HStack(spacing: 19) {
                Button { if let track = tracks.first { model.play(track) } } label: { Label(L10n.string("播放全部"), systemImage: "play.fill") }.buttonStyle(PrimaryButtonStyle()).disabled(tracks.isEmpty)
                ScrollView(.horizontal) { HStack(spacing: 5) { filter(L10n.string("全部"), nil); ForEach(MusicSource.allCases.filter(MusicSourceAvailability.isVisible), id: \.self) { source in filter(source.title, source) } } }.scrollIndicators(.hidden)
            }
            if model.searching { HStack(spacing: 9) { ProgressView().controlSize(.mini); Text(L10n.string("正在查找已连接音源…")).font(.system(size: 11)).foregroundStyle(palette.secondary) } }
            ForEach(model.searchErrors, id: \.self) { error in Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange.opacity(0.8)).padding(13).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.04), in: .rect(cornerRadius: 7)) }
            if !tracks.isEmpty { TrackList(model: model, tracks: tracks) }
            else {
                EmptyState(symbol: model.destination == .favorites ? "heart" : "music.note", title: emptyTitle, message: emptyMessage, actionTitle: model.searchTerm.isEmpty ? (model.destination == .library ? L10n.string("添加音乐") : L10n.string("浏览音乐库")) : L10n.string("管理音源")) { if model.searchTerm.isEmpty { if model.destination == .library { model.beginImport(folder: false) } else { model.navigate(.library) } } else { model.navigate(.sources) } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("music-library-content")
        .animation(ExperienceMotion.control, value: model.sourceFilter)
    }
    private var emptyTitle: String {
        if !model.searchTerm.isEmpty { return L10n.string("没有找到歌曲") }
        if model.sourceFilter != nil { return L10n.string("没有符合筛选条件的歌曲") }
        if model.destination == .favorites { return L10n.string("还没有喜欢的歌曲") }
        if model.selectedPlaylist != nil { return L10n.string("歌单为空") }
        return L10n.string("音乐库为空")
    }
    private var emptyMessage: String {
        if !model.searchTerm.isEmpty { return L10n.string("尝试其他关键词，或连接音乐服务。") }
        return ""
    }
    private func filter(_ title: String, _ source: MusicSource?) -> some View {
        Button { model.sourceFilter = source } label: { Text(title).font(.system(size: 10)).foregroundStyle(model.sourceFilter == source ? palette.accent : palette.secondary).padding(.horizontal, 10).padding(.vertical, 8).background(model.sourceFilter == source ? palette.accent.opacity(0.08) : .clear, in: .rect(cornerRadius: 6)) }.buttonStyle(.plain)
    }
}

struct TrackList: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var tracks: [Track]
    var compact = false
    var body: some View {
        if compact {
            VStack(spacing: 0) { rows }
                .accessibilityElement(children: .contain)
        } else {
            // ContentView supplies the scrolling viewport. Keep individual rows
            // directly in its lazy stack so offscreen artwork is not created.
            LazyVStack(spacing: 0) {
                HStack(spacing: 12) { Text("#").frame(width: 24); Text(L10n.string("曲目 / 艺术家")).frame(maxWidth: .infinity, alignment: .leading); if !model.queueOpen { Text(L10n.string("专辑")).frame(width: 140, alignment: .leading) }; Text(L10n.string("音源")).frame(width: 72, alignment: .leading); Text(L10n.string("时长")).frame(width: 48); Color.clear.frame(width: 61, height: 1) }.font(.system(size: 9)).foregroundStyle(palette.faint).padding(.horizontal, 8).padding(.bottom, 13)
                Rectangle().fill(palette.line).frame(height: 1)
                rows
            }
        }
    }
    private var rows: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            TrackRow(track: track, index: index, tracks: tracks, model: model, compact: compact)
        }
    }
}

struct TrackRow: View {
    @Environment(\.appPalette) private var palette
    var track: Track
    var index: Int
    var tracks: [Track]
    @Bindable var model: AppModel
    var compact = false
    @State private var hovered = false
    private var current: Bool { model.player.current?.id == track.id }
    private var displayTrack: Track { current ? model.player.current ?? track : track }
    var body: some View {
        HStack(spacing: 12) {
            Button { model.play(track, context: tracks) } label: {
                Group { if current && model.player.status == .playing { Image(systemName: "waveform") } else if hovered { Image(systemName: "play.fill") } else { Text(String(format: "%02d", index + 1)) } }.font(.system(size: 10, design: .monospaced)).frame(width: 24, height: 35).foregroundStyle(current ? palette.accent : palette.faint)
            }.buttonStyle(.plain).disabled(track.unavailable).help(L10n.string("播放 \(track.title)"))
            Button { model.play(track, context: tracks) } label: {
                HStack(spacing: 12) {
                    ArtworkView(track: track, radius: 6).frame(width: 43, height: 43)
                    VStack(alignment: .leading, spacing: 6) { Text(track.title).font(.system(size: 12, weight: .medium)).foregroundStyle(current ? palette.accent : palette.text).lineLimit(1); Text(track.unavailable ? (track.source == .local ? L10n.string("\(track.artist) · 请重新导入") : L10n.string("\(track.artist) · 当前不可播放")) : track.artist).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1) }
                    Spacer(minLength: 1)
                }.contentShape(.rect)
            }.buttonStyle(.plain).disabled(track.unavailable).frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel(L10n.string("播放 \(track.title)，\(track.artist)"))
            if !model.queueOpen && !compact { Text(track.album.isEmpty ? "—" : track.album).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1).frame(width: 140, alignment: .leading) }
            SourceBadge(source: track.source, isPreview: displayTrack.source == .soda && displayTrack.sodaPlayback?.isPreview == true).frame(width: 72, alignment: .leading)
            Text(displayTrack.duration > 0 ? formattedTime(displayTrack.duration) : "—").font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.faint).frame(width: 48)
            HStack(spacing: 1) {
                ToolButton(symbol: model.library.favorites.contains(track.id) ? "heart.fill" : "heart", label: L10n.string("喜欢 \(track.title)"), active: model.library.favorites.contains(track.id)) { model.favorite(track) }
                Menu { TrackActions(track: track, model: model) } label: { Image(systemName: "ellipsis").frame(width: 25, height: 28).foregroundStyle(palette.secondary) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.string("\(track.title) 更多操作"))
            }.frame(width: 61)
        }.padding(.horizontal, 8).padding(.vertical, 10)
            .background(current ? palette.accent.opacity(0.055) : hovered ? palette.hover : .clear, in: .rect(cornerRadius: 7))
            .overlay(alignment: .bottom) { Rectangle().fill(palette.line.opacity(0.5)).frame(height: 1) }.onHover { hovered = $0 }
            .contextMenu { TrackActions(track: track, model: model) }
    }
}

struct TrackActions: View {
    var track: Track
    @Bindable var model: AppModel
    var body: some View {
        Button(L10n.string("下一首播放"), systemImage: "text.line.first.and.arrowtriangle.forward") { model.player.playNext(track) }
        Button(L10n.string("加入播放队列"), systemImage: "text.badge.plus") { model.player.enqueue(track); model.notify(L10n.string("已加入播放队列")) }
        Button(model.library.favorites.contains(track.id) ? L10n.string("取消喜欢") : L10n.string("喜欢这首歌"), systemImage: "heart") { model.favorite(track) }
        Button(L10n.string("添加到歌单…"), systemImage: "music.note.list") { model.selectedTrack = track; model.sheet = .addToPlaylist }
        if let playlist = model.selectedPlaylist { Button(L10n.string("从歌单移除"), systemImage: "minus.circle") { model.library.removeFromPlaylist(playlist.id, trackID: track.id) } }
        if model.library.tracks.contains(where: { $0.id == track.id }) { Divider(); Button(L10n.string("从音乐库移除"), systemImage: "trash", role: .destructive) { model.remove(track) } }
    }
}

struct QueueView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var floating = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(L10n.string("播放队列")).font(.system(size: 16, weight: .medium))
                    Text("\(model.player.queue.count)").font(.system(size: 10)).foregroundStyle(palette.secondary)
                }.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                Button(L10n.string("清空")) { model.player.clearQueue() }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(palette.secondary)
                    .frame(height: 30).contentShape(.rect)
                    .accessibilityLabel(L10n.string("清空播放队列"))
                ToolButton(symbol: "xmark", label: L10n.string("关闭播放队列")) {
                    withAnimation(.smooth(duration: 0.2)) { model.queueOpen = false }
                }
            }.padding(20)
            Divider().opacity(0.35)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(model.player.queue.enumerated()), id: \.element.id) { index, track in
                        VStack(alignment: .trailing, spacing: 4) {
                            Button { model.play(track, context: model.player.queue) } label: {
                                HStack(spacing: 10) { ArtworkView(track: track, radius: 5).frame(width: 39, height: 39); VStack(alignment: .leading, spacing: 6) { Text(track.title).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.text).lineLimit(1); Text(track.artist).font(.system(size: 9)).foregroundStyle(palette.secondary).lineLimit(1) }; Spacer(minLength: 1); if model.player.current?.id == track.id { Image(systemName: "waveform").font(.system(size: 14)).foregroundStyle(palette.accent) } }.contentShape(.rect)
                            }.buttonStyle(.plain)
                            HStack(spacing: 1) { ToolButton(symbol: "arrow.up", label: L10n.string("上移 \(track.title)")) { model.player.moveInQueue(track.id, direction: -1) }.disabled(index == 0); ToolButton(symbol: "arrow.down", label: L10n.string("下移 \(track.title)")) { model.player.moveInQueue(track.id, direction: 1) }.disabled(index == model.player.queue.count - 1); ToolButton(symbol: "xmark", label: L10n.string("从队列移除 \(track.title)")) { model.player.removeFromQueue(track.id) } }.scaleEffect(0.8, anchor: .trailing).frame(height: 23)
                        }.padding(10).background(model.player.current?.id == track.id ? palette.accent.opacity(0.045) : .clear, in: .rect(cornerRadius: 7))
                    }
                    if model.player.queue.isEmpty { VStack(spacing: 14) { Image(systemName: "music.note.list").font(.system(size: 26, weight: .light)); Text(L10n.string("播放队列为空")).font(.system(size: 13)) }.foregroundStyle(palette.secondary).padding(.top, 65) }
                }.padding(10)
            }
        }.foregroundStyle(palette.text).background(floating ? palette.raised : palette.panel)
            .contentShape(.rect)
            .overlay(alignment: .leading) { if !floating { Rectangle().fill(palette.line).frame(width: 1) } }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("playback-queue")
    }
}

struct PlayerBar: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var body: some View {
        HStack(spacing: 25) {
            HStack(spacing: 13) {
                Button { withAnimation(.smooth(duration: 0.25)) { model.immersive.toggle() } } label: { ArtworkView(track: model.player.current, radius: 7).frame(width: 53, height: 53) }.buttonStyle(.plain).help(L10n.string("沉浸模式"))
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.player.current?.title ?? L10n.string("未选择歌曲")).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
                    if let track = model.player.current {
                        Text("\(track.artist) · \(track.sourcePlaybackTitle)").font(.system(size: 9)).foregroundStyle(palette.secondary).lineLimit(1)
                    }
                }
                if let track = model.player.current { ToolButton(symbol: model.library.favorites.contains(track.id) ? "heart.fill" : "heart", label: L10n.string("喜欢当前歌曲"), active: model.library.favorites.contains(track.id)) { model.favorite(track) } }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity)
            PlaybackControls(model: model).frame(minWidth: 320, maxWidth: 480)
            HStack(spacing: 9) {
                if model.player.supportsVolumeControl {
                    ToolButton(symbol: model.player.muted || model.player.volume == 0 ? "speaker.slash" : "speaker.wave.2", label: model.player.muted ? L10n.string("取消静音") : L10n.string("静音")) { model.player.toggleMute() }
                    Slider(value: Binding(get: { model.player.muted ? 0 : model.player.volume }, set: { model.player.setVolume($0) }), in: 0...1).tint(palette.accent).controlSize(.mini).frame(width: 75).accessibilityLabel(L10n.string("音量"))
                } else {
                    Label(model.player.current?.source == .spotify ? L10n.string("使用 Spotify 音量") : L10n.string("使用系统音量"), systemImage: "speaker.wave.2").font(.system(size: 10)).fixedSize(horizontal: false, vertical: true).foregroundStyle(palette.secondary).help(model.player.current?.source == .spotify ? L10n.string("在 Spotify 官方播放设备上调节音量") : L10n.string("Apple Music 音量由系统控制"))
                }
                Divider().frame(height: 19).padding(.horizontal, 7)
                ToolButton(symbol: "quote.bubble", label: L10n.string("歌词"), active: model.immersive && model.lyricsVisible) { model.revealLyrics() }
                ToolButton(symbol: "arrow.up.left.and.arrow.down.right", label: L10n.string("沉浸模式"), active: model.immersive) { withAnimation(.smooth(duration: 0.25)) { model.immersive.toggle() } }
                ToolButton(symbol: "music.note.list", label: L10n.string("播放队列"), active: model.queueOpen) { withAnimation(.smooth(duration: 0.22)) { model.queueOpen.toggle() } }
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(.horizontal, 27).frame(height: 100).background(palette.panel.opacity(0.96)).overlay(alignment: .top) { Rectangle().fill(palette.accent.opacity(0.1)).frame(height: 1) }
    }
}

struct PlaybackControls: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    private var duration: Double { model.player.duration.isFinite && model.player.duration > 0 ? model.player.duration : 1 }
    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 19) {
                ToolButton(symbol: "shuffle", label: L10n.string("随机播放"), active: model.player.shuffle) { model.player.toggleShuffle() }
                ToolButton(symbol: "backward.end.fill", label: L10n.string("上一首")) { Task { await model.player.previous() } }.disabled(model.player.current == nil)
                Button { Task { await model.toggle() } } label: {
                    Group { if model.player.status == .loading { ProgressView().controlSize(.small).tint(palette.onPrimary) } else { Image(systemName: model.player.status == .playing ? "pause.fill" : "play.fill").font(.system(size: 16, weight: .medium)) } }
                        .frame(width: 37, height: 37).foregroundStyle(palette.onPrimary).background(palette.primary, in: .circle)
                }.buttonStyle(.plain).help(model.player.status == .playing ? L10n.string("暂停") : L10n.string("播放")).accessibilityLabel(model.player.status == .playing ? L10n.string("暂停") : L10n.string("播放")).accessibilityIdentifier("play-toggle").disabled(model.player.current == nil && model.library.tracks.isEmpty)
                ToolButton(symbol: "forward.end.fill", label: L10n.string("下一首")) { Task { await model.player.next() } }.disabled(model.player.current == nil)
                ToolButton(symbol: model.player.repeatMode == .one ? "repeat.1" : "repeat", label: L10n.string("循环模式：\(model.player.repeatMode == .off ? L10n.string("不循环") : model.player.repeatMode == .all ? L10n.string("列表循环") : L10n.string("单曲循环"))"), active: model.player.repeatMode != .off) { model.player.cycleRepeat() }
            }
            HStack(spacing: 10) {
                Text(formattedTime(model.player.position)).frame(width: 30)
                Slider(value: Binding(get: { min(duration, max(0, model.player.position.isFinite ? model.player.position : 0)) }, set: { model.player.seek(to: $0) }), in: 0...duration).controlSize(.mini).tint(palette.accent).disabled(!model.player.duration.isFinite || model.player.duration <= 0).accessibilityLabel(L10n.string("播放进度"))
                Text(formattedTime(model.player.duration)).frame(width: 30)
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.secondary)
        }
    }
}
