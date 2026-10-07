import SwiftUI

struct SheetHeading: View {
    @Environment(\.appPalette) private var palette
    var title: String
    var subtitle: String = ""
    var close: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 21, weight: .regular)).tracking(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.secondary).lineSpacing(5)
                }
            }
            Spacer()
            ToolButton(symbol: "xmark", label: L10n.string("关闭"), action: close).keyboardShortcut(.cancelAction)
        }
    }
}

struct AppSheetView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var sheet: AppSheet
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var error: String?
    var body: some View {
        if sheet == .qqOfficialPlayback, let track = model.officialPlaybackTrack {
            QQOfficialPlaybackView(track: track, client: model.accounts.client)
                .onDisappear { model.officialPlaybackTrack = nil }
        } else { standardSheet }
    }
    private var standardSheet: some View {
        VStack(alignment: .leading, spacing: 25) {
            switch sheet {
            case .qqOfficialPlayback:
                Text(L10n.string("请先选择要查看的 QQ 音乐歌曲。"))
            case .appleMusicSetup:
                SheetHeading(title: L10n.string("连接 Apple Music")) { dismiss() }
                if !model.appleMusic.isConfigured {
                    Label(L10n.string("此版本尚未启用 Apple Music"), systemImage: "wrench.and.screwdriver").font(.system(size: 13)).foregroundStyle(palette.accent)
                    Text(L10n.string("需在 Apple Developer 启用 MusicKit，并使用对应的开发者身份签名。")).font(.system(size: 12)).lineSpacing(6)
                    Text(L10n.string("配置步骤：docs/apple-music-setup.md。无需提供密码或私钥。")).font(.system(size: 11)).foregroundStyle(palette.secondary).lineSpacing(5)
                    Link(L10n.string("查看 Apple 官方配置说明"), destination: URL(string: "https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api")!).font(.system(size: 11)).foregroundStyle(palette.accent)
                }
                VStack(alignment: .leading, spacing: 15) {
                    Label(L10n.string("授权后可导入曲库和歌单、搜索并播放歌曲。"), systemImage: "music.note.list")
                    Label(L10n.string("目录歌曲需要有效订阅与所在地区的播放权限。"), systemImage: "person.crop.circle.badge.checkmark")
                    Label(L10n.string("音量由系统控制；当前无法获取实时音频，波形与频谱不随音乐变化。"), systemImage: "photo")
                }.font(.system(size: 11)).foregroundStyle(palette.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                Button(L10n.string("知道了")) { dismiss() }.buttonStyle(PrimaryButtonStyle()).frame(maxWidth: .infinity, alignment: .trailing)
            case .visual:
                SheetHeading(title: L10n.string("视觉设置")) { dismiss() }
                ScrollView { VisualSettingsView(model: model).padding(.trailing, 8) }.frame(maxHeight: 540)
            case .url:
                SheetHeading(title: L10n.string("添加音频链接")) { dismiss() }
                field(L10n.string("音频地址"), placeholder: "https://example.com/music.mp3", value: $address)
                field(L10n.string("显示名称"), placeholder: L10n.string("输入显示名称"), value: $name)
                Text(L10n.string("需要可直接播放的音频地址或 HLS 流。歌曲分享页面无法直接播放。")).font(.system(size: 11)).foregroundStyle(palette.secondary).lineSpacing(6)
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
                Button { do { try model.addLink(title: name, address: address); dismiss() } catch { self.error = error.localizedDescription } } label: { Label(L10n.string("添加到音乐库"), systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            case .playlist:
                SheetHeading(title: L10n.string("创建歌单")) { dismiss() }
                field(L10n.string("歌单名称"), placeholder: L10n.string("输入歌单名称"), value: $name)
                Button { let clean = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }; _ = model.library.createPlaylist(String(clean.prefix(60))); model.notify(L10n.string("已创建「\(clean)」")); dismiss() } label: { Label(L10n.string("创建歌单"), systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButtonStyle()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            case .addToPlaylist:
                SheetHeading(title: L10n.string("添加到歌单"), subtitle: model.selectedTrack?.title ?? "") { dismiss() }
                if let track = model.selectedTrack {
                    ScrollView { VStack(spacing: 8) { ForEach(model.library.playlists) { playlist in
                        Button { model.library.addToPlaylist(playlist.id, track: track); model.notify(L10n.string("已添加到「\(playlist.name)」")); dismiss() } label: { HStack(spacing: 12) { Image(systemName: "music.note.list"); Text(playlist.name).font(.system(size: 12)); Spacer(); Text(playlist.trackIDs.contains(track.id) ? L10n.string("已添加") : L10n.string("\(playlist.trackIDs.count) 首")).font(.system(size: 10)).foregroundStyle(palette.secondary); Image(systemName: "chevron.right").font(.system(size: 9)) }.padding(15).background(palette.accent.opacity(0.04), in: .rect(cornerRadius: 8)).foregroundStyle(palette.text) }.buttonStyle(.plain)
                    } } }.frame(maxHeight: 300)
                    HStack { TextField(L10n.string("新歌单名称"), text: $name).textFieldStyle(.roundedBorder); Button(L10n.string("创建并添加")) { let clean = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }; let playlist = model.library.createPlaylist(String(clean.prefix(60))); model.library.addToPlaylist(playlist.id, track: track); model.notify(L10n.string("已添加到新歌单「\(clean)」")); dismiss() }.buttonStyle(QuietButtonStyle()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
            }
        }.padding(29).frame(width: sheet == .visual ? 620 : 500).background(palette.panel).foregroundStyle(palette.text)
    }
    private func field(_ title: String, placeholder: String, value: Binding<String>) -> some View { VStack(alignment: .leading, spacing: 10) { Text(title).font(.system(size: 11)).foregroundStyle(palette.secondary); TextField(placeholder, text: value).textFieldStyle(.roundedBorder).font(.system(size: 12)).accessibilityLabel(title) } }
}

struct VisualSettingsView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var osReduced
    @State private var presetName = ""
    var body: some View {
        VStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L10n.string("后台音频字幕对齐"), isOn: $model.automaticLyricAudioAlignment)
                    .accessibilityIdentifier("lyric-audio-alignment-toggle")
                Text(L10n.string("在本机提前分析人声；首次可能下载语言模型。只缓存时间，不保存音频。"))
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
                Text(model.lyrics.audioAlignmentStatus.description)
                    .font(.system(size: 11)).foregroundStyle(palette.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 16) {
                Text(L10n.string("语言")).font(.system(size: 11)).foregroundStyle(palette.secondary)
                Spacer(minLength: 8)
                Picker(L10n.string("语言"), selection: $model.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 240)
                .accessibilityLabel(L10n.string("语言"))
                .accessibilityIdentifier("app-language-picker")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(VisualizationMode.allCases) { mode in
                    Button { model.visualMode = mode } label: {
                        VStack(spacing: 10) {
                            Image(systemName: mode.symbol).font(.system(size: 22, weight: .light))
                            Text(mode.title).font(.system(size: 10)).lineLimit(2)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                .frame(minHeight: 28)
                        }.foregroundStyle(model.visualMode == mode ? palette.accent : palette.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(palette.accent.opacity(model.visualMode == mode ? 0.12 : 0.03), in: .rect(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.accent.opacity(model.visualMode == mode ? 0.4 : 0.09)))
                    }.buttonStyle(.plain).accessibilityLabel(L10n.string("视觉效果：\(mode.title)"))
                        .accessibilityAddTraits(model.visualMode == mode ? [.isSelected] : [])
                }
            }
            if !model.canVisualizeActiveTrack {
                Label(model.visualMode.isSignalDisplay
                      ? L10n.string("当前无法获取 \(model.activeTrack?.source.title ?? L10n.string("此音源")) 实时音频，波形与频谱不随音乐变化。")
                      : L10n.string("\(model.activeTrack?.source.title ?? L10n.string("此音源")) 使用氛围动画，无法根据实时音频变化。"), systemImage: "sparkles")
                    .font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.visualMode == .pointCloud {
                HStack(spacing: 10) {
                    ForEach(Array(VisualSettings.presets.enumerated()), id: \.offset) { index, preset in
                        Button { var settings = preset.settings; settings.reduceMotion = model.visual.reduceMotion; settings.batterySaver = model.visual.batterySaver; model.visual = settings } label: {
                            HStack(spacing: 9) { Image(systemName: ["circle.dotted", "sparkle", "square.3.layers.3d"][index]); Text(preset.name) }.frame(maxWidth: .infinity)
                        }.buttonStyle(QuietButtonStyle())
                    }
                }
                HStack(spacing: 22) {
                    VStack(alignment: .leading, spacing: 9) { Text(L10n.string("点云密度")).font(.system(size: 11)); Picker(L10n.string("点云密度"), selection: $model.visual.density) { Text(L10n.string("稀疏")).tag(96); Text(L10n.string("均衡")).tag(160); Text(L10n.string("密集")).tag(224) }.labelsHidden() }
                    Spacer()
                    VStack(alignment: .leading, spacing: 9) { Text(L10n.string("运动方式")).font(.system(size: 11)); Picker(L10n.string("运动方式"), selection: $model.visual.scheme) { Text(L10n.string("轻盈跃动")).tag(0); Text(L10n.string("纵深呼吸")).tag(1) }.labelsHidden() }
                }.foregroundStyle(palette.secondary)
                Grid(horizontalSpacing: 26, verticalSpacing: 18) {
                    GridRow { slider(L10n.string("浮雕深度"), $model.visual.depth, 0...1); slider(L10n.string("颗粒大小"), $model.visual.pointSize, 0.5...4) }
                    GridRow { slider(L10n.string("律动强度"), $model.visual.bounce, 0...0.4); slider(L10n.string("流动速度"), $model.visual.speed, 0.5...8) }
                    GridRow { slider(L10n.string("波纹密度"), $model.visual.frequency, 1...10); slider(L10n.string("待机起伏"), $model.visual.idle, 0...0.05) }
                }
                Grid(horizontalSpacing: 26, verticalSpacing: 14) {
                    GridRow { toggle(L10n.string("反转明暗深度"), $model.visual.invert); toggle(L10n.string("柔和辉光"), $model.visual.glow) }
                    GridRow { toggle(L10n.string("节拍点亮"), $model.visual.beatPop); toggle(L10n.string("缓慢自动旋转"), $model.visual.autoOrbit) }
                }
                if !model.presets.isEmpty {
                    ScrollView(.horizontal) { HStack(spacing: 8) { ForEach(model.presets) { preset in HStack(spacing: 4) { Button(preset.name) { model.visual = preset.settings.validated() }.font(.system(size: 10)); Button { model.presets.removeAll { $0.id == preset.id } } label: { Image(systemName: "xmark").font(.system(size: 8)) }.help(L10n.string("删除 \(preset.name)")) }.buttonStyle(.plain).padding(9).foregroundStyle(palette.accent).background(palette.accent.opacity(0.06), in: .rect(cornerRadius: 6)) } } }.scrollIndicators(.hidden)
                }
                HStack(spacing: 11) { TextField(L10n.string("预设名称"), text: $presetName).textFieldStyle(.roundedBorder).font(.system(size: 11)).accessibilityLabel(L10n.string("自定义预设名称")); Button { model.savePreset(String(presetName.prefix(30))); presetName = "" } label: { Label(L10n.string("保存预设"), systemImage: "plus") }.buttonStyle(QuietButtonStyle()).disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            Divider().opacity(0.35)
            HStack(spacing: 26) { toggle(L10n.string("减少动态效果"), $model.visual.reduceMotion); toggle(L10n.string("低电量模式节能"), $model.visual.batterySaver) }
            if osReduced { Text(L10n.string("已遵循系统的“减少动态效果”设置。")).font(.system(size: 10)).foregroundStyle(palette.secondary).frame(maxWidth: .infinity, alignment: .leading) }
        }.tint(palette.accent).animation(ExperienceMotion.control, value: model.visualMode)
    }
    private func slider(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>) -> some View { VStack(spacing: 10) { HStack { Text(title); Spacer(); Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2)))).monospacedDigit().foregroundStyle(palette.faint) }.font(.system(size: 10)).foregroundStyle(palette.secondary); Slider(value: value, in: range).controlSize(.mini).accessibilityLabel(title) }.frame(maxWidth: .infinity) }
    private func toggle(_ title: String, _ value: Binding<Bool>) -> some View { Toggle(title, isOn: value).fixedSize(horizontal: false, vertical: true).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10)).foregroundStyle(palette.secondary).frame(maxWidth: .infinity, alignment: .leading) }
}
