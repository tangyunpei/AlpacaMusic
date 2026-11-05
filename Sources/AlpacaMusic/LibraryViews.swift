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
                Button { model.beginImport(folder: false) } label: { Label(L10n.string("添加音乐"), systemImage: "plus") }.buttonStyle(QuietButtonStyle()).disabled(model.library.busy)
            }
            HStack(spacing: 19) {
                Button { if let track = tracks.first { model.play(track) } } label: { Label(L10n.string("播放全部"), systemImage: "play.fill") }.buttonStyle(PrimaryButtonStyle()).disabled(tracks.isEmpty)
                ScrollView(.horizontal) { HStack(spacing: 5) { filter(L10n.string("全部"), nil); ForEach(MusicSource.allCases.filter(MusicSourceAvailability.isVisible), id: \.self) { source in filter(source.title, source) } } }.scrollIndicators(.hidden)
            }
            if !model.searchTerm.isEmpty { SearchResultsView(model: model) }
            else if !tracks.isEmpty { TrackList(model: model, tracks: tracks) }
            else {
                EmptyState(symbol: model.destination == .favorites ? "heart" : "music.note", title: emptyTitle, actionTitle: model.destination == .library ? L10n.string("添加音乐") : L10n.string("浏览音乐库")) { if model.destination == .library { model.beginImport(folder: false) } else { model.navigate(.library) } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("music-library-content")
        .animation(ExperienceMotion.control, value: model.sourceFilter)
    }
    private var emptyTitle: String {
        if model.sourceFilter != nil { return L10n.string("没有符合筛选条件的歌曲") }
        if model.destination == .favorites { return L10n.string("还没有喜欢的歌曲") }
        if model.selectedPlaylist != nil { return L10n.string("歌单为空") }
        return L10n.string("音乐库为空")
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
    /// Column titles; a second list in the same page can omit them.
    var showsHeader = true
    /// Rows are online search results rather than library songs.
    var online = false
    var body: some View {
        if compact {
            VStack(spacing: 0) { rows }
                .accessibilityElement(children: .contain)
        } else {
            // ContentView supplies the scrolling viewport. Keep individual rows
            // directly in its lazy stack so offscreen artwork is not created.
            LazyVStack(spacing: 0) {
                if showsHeader { header }
                rows
            }
        }
    }
    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) { Text("#").frame(width: 24); Text(L10n.string("曲目 / 艺术家")).frame(maxWidth: .infinity, alignment: .leading); if !model.queueOpen { Text(L10n.string("专辑")).frame(width: 140, alignment: .leading) }; Text(L10n.string("音源")).frame(width: 72, alignment: .leading); Text(L10n.string("时长")).frame(width: 48); Color.clear.frame(width: 61, height: 1) }.font(.system(size: 9)).foregroundStyle(palette.faint).padding(.horizontal, 8).padding(.bottom, 13)
            Rectangle().fill(palette.line).frame(height: 1)
        }
    }
    private var rows: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            TrackRow(track: track, index: index, tracks: tracks, model: model, compact: compact, online: online)
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
    var online = false
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
                    VStack(alignment: .leading, spacing: 6) { HStack(spacing: 5) { Text(track.title).font(.system(size: 12, weight: .medium)).foregroundStyle(current ? palette.accent : palette.text).lineLimit(1); if online { LibraryMatchMark(track: track, model: model) } }; Text(track.unavailable ? (track.source == .local ? L10n.string("\(track.artist) · 请重新导入") : L10n.string("\(track.artist) · 当前不可播放")) : track.artist).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1) }
                    Spacer(minLength: 1)
                }.contentShape(.rect)
            }.buttonStyle(.plain).disabled(track.unavailable).frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel(L10n.string("播放 \(track.title)，\(track.artist)"))
                .accessibilityValue(online && model.searchResultMatchesLibrary(track) ? L10n.string("已在音乐库") : "")
            if !model.queueOpen && !compact { Text(track.album.isEmpty ? "—" : track.album).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1).frame(width: 140, alignment: .leading) }
            SourceBadge(source: track.source, isPreview: displayTrack.source == .soda && displayTrack.sodaPlayback?.isPreview == true).frame(width: 72, alignment: .leading)
            Text(displayTrack.duration > 0 ? formattedTime(displayTrack.duration) : "—").font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.faint).frame(width: 48)
            HStack(spacing: 1) {
                if online { LibraryAddButton(track: track, model: model) }
                else { ToolButton(symbol: model.library.favorites.contains(track.id) ? "heart.fill" : "heart", label: L10n.string("喜欢 \(track.title)"), active: model.library.favorites.contains(track.id)) { model.favorite(track) } }
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

/// Search results grouped by provenance: library songs and albums first,
/// then online results, with one compact strip of per-source status.
struct SearchResultsView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    @Bindable var model: AppModel
    private var reduced: Bool { systemReduced || appReduced || model.visual.reduceMotion }
    var body: some View {
        let local = model.searchLibraryMatches
        let albums = model.searchAlbumMatches
        let online = model.searchOnlineResults
        let link = model.searchLink
        VStack(alignment: .leading, spacing: 24) {
            if !model.visibleSearchStatuses.isEmpty { SearchSourceStrip(model: model) }
            if let link { SearchLinkRow(model: model, url: link) }
            if !local.isEmpty || !albums.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SearchSectionTitle(title: L10n.string("音乐库"), symbol: "music.note.house", count: local.count)
                    if !albums.isEmpty { SearchAlbumRow(model: model, albums: albums) }
                    if !local.isEmpty { TrackList(model: model, tracks: local) }
                }
            }
            if !online.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SearchSectionTitle(title: L10n.string("在线"), symbol: "globe", count: online.count)
                    TrackList(model: model, tracks: online, showsHeader: local.isEmpty, online: true)
                }
            }
            if local.isEmpty && albums.isEmpty && online.isEmpty && !model.searching && link == nil {
                EmptyState(symbol: "magnifyingglass", title: L10n.string("没有找到歌曲"), actionTitle: L10n.string("管理音源")) { model.navigate(.sources) }
            }
        }
        .environment(\.appReducedMotion, reduced)
        .animation(reduced ? nil : ExperienceMotion.control, value: model.visibleSearchStatuses)
    }
}

private struct SearchSectionTitle: View {
    @Environment(\.appPalette) private var palette
    var title: String
    var symbol: String
    var count: Int
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(palette.secondary).accessibilityHidden(true)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text)
            Text(count, format: .number).font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.faint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One chip per searched source: a spinner while it runs, the result count
/// when done, and an orange retry glyph when it failed, with the first
/// failure as one compact orange line below.
private struct SearchSourceStrip: View {
    @Bindable var model: AppModel
    var body: some View {
        let statuses = model.visibleSearchStatuses
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(statuses) { status in
                        SearchSourceChip(status: status) { model.query = model.searchTerm; model.search() }
                    }
                }
            }
            .scrollIndicators(.hidden)
            SearchFailureLine(statuses: statuses)
        }
    }
}

/// The first failed source as one short orange line; full text in the tooltip.
private struct SearchFailureLine: View {
    var statuses: [SearchSourceStatus]
    private var failure: (source: MusicSource, message: String)? {
        for status in statuses {
            if case .failed(let message) = status.state { return (source: status.source, message: message) }
        }
        return nil
    }
    var body: some View {
        if let failure {
            Text(L10n.string("\(failure.source.title)：\(failure.message)"))
                .font(.system(size: 10)).foregroundStyle(Color.orange.opacity(0.85))
                .lineLimit(1).truncationMode(.tail)
                .textSelection(.enabled).help(failure.message)
        }
    }
}

private struct SearchSourceChip: View {
    @Environment(\.appPalette) private var palette
    var status: SearchSourceStatus
    var retry: () -> Void
    private var failed: Bool {
        switch status.state { case .failed: true; default: false }
    }
    private var detail: String {
        switch status.state {
        case .searching: L10n.string("搜索歌曲")
        case .done(let count): L10n.string("\(count) 首")
        case .failed(let message): message
        }
    }
    var body: some View {
        let description = L10n.string("\(status.source.title)：\(detail)")
        Group {
            if failed {
                Button(action: retry) { content }
                    .buttonStyle(.plain)
                    .accessibilityLabel(description)
                    .accessibilityHint(L10n.string("重试「\(status.source.title)」"))
            } else {
                content.accessibilityElement(children: .ignore).accessibilityLabel(description)
            }
        }
        .help(description)
    }
    private var content: some View {
        HStack(spacing: 5) {
            Image(systemName: status.source.symbol).font(.system(size: 9)).foregroundStyle(palette.secondary)
            Text(status.source.title).font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(1)
            indicator.frame(minWidth: 9, minHeight: 9)
        }
        .padding(.horizontal, 9).frame(height: 24)
        .background(failed ? Color.orange.opacity(0.06) : palette.accent.opacity(0.04), in: .rect(cornerRadius: 6))
        .contentShape(.rect)
    }
    @ViewBuilder private var indicator: some View {
        switch status.state {
        case .searching:
            ImportStatusGlyph(state: .working(nil), size: 9)
        case .done(let count):
            Text(count, format: .number).font(.system(size: 9, design: .monospaced))
                .foregroundStyle(count > 0 ? palette.text : palette.faint)
                .contentTransition(.numericText(value: Double(count)))
        case .failed:
            Image(systemName: "arrow.clockwise").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.orange)
        }
    }
}

/// A pasted HTTP(S) address: offered as one row to add, never searched.
private struct SearchLinkRow: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var url: URL
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.accent)
                .frame(width: 30, height: 30).background(palette.accent.opacity(0.06), in: .rect(cornerRadius: 7))
                .accessibilityLabel(L10n.string("音频链接"))
            Text(url.host() ?? url.absoluteString).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.text)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(url.absoluteString)
            Spacer(minLength: 8)
            Button {
                do { try model.addLink(title: "", address: model.searchTerm) } catch { model.notify(error.localizedDescription) }
            } label: { Label(L10n.string("添加到音乐库"), systemImage: "plus") }
                .buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(palette.accent.opacity(0.035), in: .rect(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }
}

/// Matching albums from the album library; a tile opens the album page.
private struct SearchAlbumRow: View {
    @Bindable var model: AppModel
    var albums: [MusicAlbum]
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(albums) { album in SearchAlbumTile(model: model, album: album) }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("专辑"))
    }
}

private struct SearchAlbumTile: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    @Bindable var model: AppModel
    var album: MusicAlbum
    @State private var hovered = false
    /// The first track with artwork; the album's own artwork wins when it has
    /// one, carried by a lightweight track if no song is loaded yet.
    private var coverTrack: Track? {
        let ids = album.artworkURL == nil ? album.trackIDs : Array(album.trackIDs.prefix(1))
        let tracks = model.library.tracks(withIDs: ids)
        let found = tracks.first { $0.artworkData?.isEmpty == false || $0.artworkURL != nil } ?? tracks.first
        guard let url = album.artworkURL else { return found }
        var track = found ?? Track(id: album.id, title: album.name, artist: album.artist, album: album.name, duration: 0, source: album.source)
        track.artworkURL = url
        track.artworkData = nil
        return track
    }
    var body: some View {
        let count = album.trackIDs.count
        Button { model.navigate(.album(album.id)) } label: {
            VStack(alignment: .leading, spacing: 7) {
                ArtworkView(track: coverTrack, radius: 7).frame(width: 96, height: 96)
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(hovered ? palette.accent.opacity(0.45) : palette.line) }
                Text(album.name).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.text).lineLimit(1)
                HStack(spacing: 4) {
                    Text(album.artist).lineLimit(1)
                    Text(verbatim: "·").foregroundStyle(palette.faint)
                    Text(count, format: .number).monospacedDigit()
                }
                .font(.system(size: 9)).foregroundStyle(palette.secondary)
            }
            .frame(width: 96, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(L10n.string("打开专辑 \(album.name)"))
        .accessibilityLabel(L10n.string("打开专辑 \(album.name)"))
        .accessibilityValue([album.artist, album.source.title, L10n.string("\(count) 首歌曲")].filter { !$0.isEmpty }.joined(separator: " · "))
        .accessibilityIdentifier("search-album-\(album.id)")
        .animation(systemReduced || appReduced ? nil : ExperienceMotion.control, value: hovered)
    }
}

/// Small accent check beside an online result whose title and artist
/// already exist in the library.
private struct LibraryMatchMark: View {
    @Environment(\.appPalette) private var palette
    var track: Track
    @Bindable var model: AppModel
    var body: some View {
        if model.searchResultMatchesLibrary(track) && !model.isLibraryTrack(track) {
            Image(systemName: "checkmark.circle").font(.system(size: 9, weight: .medium)).foregroundStyle(palette.accent)
                .help(L10n.string("已在音乐库")).accessibilityLabel(L10n.string("已在音乐库"))
        }
    }
}

/// Quick add for an online result; springs into a check once saved.
private struct LibraryAddButton: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.appReducedMotion) private var appReduced
    var track: Track
    @Bindable var model: AppModel
    var body: some View {
        let added = model.isLibraryTrack(track)
        let reduced = systemReduced || appReduced
        ZStack {
            if added {
                // Once saved it is a plain status mark, not a button that does nothing.
                Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent)
                    .font(.system(size: 15, weight: .regular)).frame(width: 30, height: 30)
                    .help(L10n.string("已在音乐库")).accessibilityLabel(L10n.string("已在音乐库"))
                    .transition(reduced ? AnyTransition.opacity : AnyTransition.scale(scale: 0.4).combined(with: .opacity))
            } else {
                let label = L10n.string("添加「\(track.title)」到音乐库")
                Button { model.addToLibrary(track) } label: {
                    Image(systemName: "plus.circle").foregroundStyle(palette.secondary)
                        .font(.system(size: 15, weight: .regular)).frame(width: 30, height: 30).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(label).accessibilityLabel(label)
                .transition(AnyTransition.opacity)
            }
        }
        .frame(width: 30, height: 30)
        .animation(reduced ? nil : Animation.spring(response: 0.32, dampingFraction: 0.62), value: added)
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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
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
                ToolButton(symbol: "quote.bubble", label: L10n.string("歌词"), active: model.immersive && model.lyricsVisible) { withAnimation(.smooth(duration: 0.25)) { model.toggleLyrics() } }
                ToolButton(symbol: "arrow.up.left.and.arrow.down.right", label: L10n.string("沉浸模式"), active: model.immersive) { withAnimation(.smooth(duration: 0.25)) { model.immersive.toggle() } }
                ToolButton(symbol: "music.note.list", label: L10n.string("播放队列"), active: model.queueOpen) { withAnimation(.smooth(duration: 0.22)) { model.queueOpen.toggle() } }
                ToolButton(symbol: "pip.enter", label: L10n.string("迷你播放器")) {
                    PlayerWindows.switchWindow(to: PlayerWindowID.miniPlayer, from: PlayerWindowID.main, open: openWindow, dismiss: dismissWindow)
                }
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
