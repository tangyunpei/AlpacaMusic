import AppKit
import SwiftUI

/// Copied into a separate temporary target by preview-experience.sh. This file
/// is never part of the production target and creates no account or library model.
@main struct AlpacaExperienceQAApp: App {
    var body: some Scene {
        Window("AlpacaMusic · Experience QA", id: "experience-qa") {
            ExperienceQARoom()
                .frame(minWidth: 900, minHeight: 650)
                .appTheme(.listeningRoom)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 980, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands { CommandGroup(replacing: .newItem) { } }
    }
}

private enum QASignalMode: String, CaseIterable, Identifiable {
    case synthesized, rhythm, unavailable, appleMusic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .synthesized: "合成测试信号"
        case .rhythm: "节奏起音测试"
        case .unavailable: "无音频数据"
        case .appleMusic: "Apple Music 策略"
        }
    }
}

@MainActor private struct ExperienceQARoom: View {
    @State private var visualMode = VisualizationMode.spectrumBars
    @State private var lyricMode = LyricPresentationMode.kinetic
    @State private var settings = VisualSettings.standard
    @State private var position = 0.0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var lyricsVisible = false
    @State private var signalMode = QASignalMode.rhythm
    @State private var notice: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduced

    private var document: LyricDocument { LyricsQAFixture.document }
    private var duration: Double { LyricsQAFixture.duration }
    private var reduced: Bool { systemReduced || settings.reduceMotion }
    private var clockRuns: Bool { isPlaying && !isScrubbing && scenePhase == .active }
    private var track: Track {
        Track(id: "experience-qa-original", title: document.title ?? "晚风经过音乐室", artist: document.artist ?? "AlpacaMusic · 原创测试文本",
              album: "Independent Experience Fixture", duration: duration,
              source: signalMode == .appleMusic ? .appleMusic : .demo,
              sourceID: signalMode == .appleMusic ? "qa-only-never-requested" : nil,
              addedAt: Date(timeIntervalSince1970: 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                ZStack {
                    RadialGradient(colors: [AppPalette.listeningRoom.raised.opacity(0.5), AppPalette.listeningRoom.background], center: .center, startRadius: 20, endRadius: 760)
                    if !lyricsVisible {
                        visualization.padding(.vertical, 32)
                    } else if lyricMode == .scroll {
                        HStack(spacing: 28) {
                            visualization.frame(width: geometry.size.width * 0.43)
                            lyrics.padding(.trailing, 35)
                        }.padding(.vertical, 35)
                    } else {
                        visualization.modifier(KineticBackdrop(mode: visualMode))
                        lyrics.padding(.horizontal, 42).padding(.vertical, 40)
                    }
                }.animation(reduced ? nil : ExperienceMotion.panel, value: lyricMode)
                    .animation(reduced ? nil : ExperienceMotion.panel, value: lyricsVisible)
            }
            transport
        }
        .foregroundStyle(AppPalette.listeningRoom.text).background(AppPalette.listeningRoom.background)
        .transaction { if reduced { $0.animation = nil; $0.disablesAnimations = true } }
        .task(id: clockRuns) {
            guard clockRuns else { return }
            let clock = ContinuousClock()
            var previous = clock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                guard !Task.isCancelled, clockRuns else { return }
                let now = clock.now, elapsed = previous.duration(to: now).components
                previous = now
                let delta = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                position = min(duration, position + max(0, min(0.2, delta)))
                if position >= duration { isPlaying = false; return }
            }
        }
        .accessibilityIdentifier("experience-qa-room")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ALPACA / EXPERIENCE QA").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(AppPalette.listeningRoom.accent)
                    Text("原创测试歌词与合成频谱 · 不播放声音 · 不读取真实曲库或账号")
                        .font(.system(size: 10)).foregroundStyle(AppPalette.listeningRoom.secondary)
                }
                Spacer()
                Toggle("减少动态", isOn: $settings.reduceMotion).toggleStyle(.switch).controlSize(.small)
                Toggle("显示歌词", isOn: $lyricsVisible).toggleStyle(.switch).controlSize(.small)
            }
            HStack(spacing: 20) {
                Picker("视觉", selection: $visualMode) {
                    ForEach(VisualizationMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.frame(width: 245).accessibilityIdentifier("qa-visual-mode")
                Picker("字幕", selection: $lyricMode) {
                    Text("滚动歌词").tag(LyricPresentationMode.scroll)
                    Text("动态字幕").tag(LyricPresentationMode.kinetic)
                }.pickerStyle(.segmented).frame(width: 230).accessibilityIdentifier("qa-lyric-mode")
                Spacer()
                Picker("测试输入", selection: $signalMode) {
                    ForEach(QASignalMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.frame(width: 235).accessibilityIdentifier("qa-signal-mode")
            }.font(.system(size: 11))
        }.padding(24).background(AppPalette.listeningRoom.panel)
    }

    private var visualization: some View {
        ZStack {
            MusicVisualizationView(track: track, mode: visualMode, settings: settings,
                                   isPlaying: clockRuns, signal: fixtureLevels)
                .id(visualMode).transition(.opacity)
        }.animation(reduced ? nil : ExperienceMotion.visualization, value: visualMode)
    }

    private var lyrics: some View {
        LyricsPresentationView(document: document, status: .ready, error: nil,
                               mode: lyricMode, position: position, isPlaying: clockRuns, reduceMotion: reduced,
                               onSeek: seek,
                               onImport: { notice = "独立预览使用内置原创测试歌词，不打开真实文件。" },
                               onRetry: { seek(0); notice = "测试时钟已归零。" },
                               signal: fixtureLevels)
    }

    private var transport: some View {
        VStack(spacing: 12) {
            HStack(spacing: 15) {
                Button {
                    if !isPlaying && position >= duration { seek(0) }
                    isPlaying.toggle()
                } label: {
                    Label(isPlaying ? "暂停测试" : "播放测试时钟", systemImage: isPlaying ? "pause.fill" : "play.fill")
                }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.space, modifiers: []).accessibilityIdentifier("qa-play-pause")
                Button("归零") { seek(0) }.buttonStyle(QuietButtonStyle())
                Text(formattedTime(position)).monospacedDigit().frame(width: 38)
                Slider(value: Binding(get: { position }, set: seek), in: 0...duration, onEditingChanged: { isScrubbing = $0 })
                    .tint(AppPalette.listeningRoom.accent).accessibilityLabel("测试进度").accessibilityIdentifier("qa-position")
                Text(formattedTime(duration)).monospacedDigit().frame(width: 38)
            }
            HStack {
                Text(notice ?? "点击歌词可跳转 · 拖动进度检查前后定位 · 点云支持旋转、缩放和双击复位")
                Spacer()
                Text(signalMode == .rhythm ? "原创节奏 · " + OrbitRhythmQAFixture.phase(at: position.truncatingRemainder(dividingBy: 16)) : signalMode == .synthesized ? "当前为合成测试数据" : signalMode == .appleMusic ? "验证 Apple Music 氛围模式，不联网" : "验证无音频数据的静候状态")
            }.font(.system(size: 9)).foregroundStyle(AppPalette.listeningRoom.secondary)
        }.font(.system(size: 11)).padding(24).background(AppPalette.listeningRoom.panel)
    }

    private func seek(_ value: Double) {
        guard value.isFinite else { return }
        position = min(duration, max(0, value))
    }

    private func fixtureLevels() -> AudioLevels {
        guard clockRuns else { return AudioLevels() }
        if signalMode == .rhythm {
            return OrbitRhythmQAFixture.levels(at: position.truncatingRemainder(dividingBy: 16))
        }
        guard signalMode == .synthesized else { return AudioLevels() }
        // Deliberately synthetic and labelled in the QA chrome. Production code
        // receives AudioAnalyzer values instead; no generated audio is played.
        // Repeating twelve-second exercise: silence, bass impulses, treble
        // sweep, crescendo, abrupt silence. Each stage has a distinct signal.
        let phase = position.truncatingRemainder(dividingBy: 12)
        let rate = 44_100.0
        let pulse = phase >= 2 && phase < 5 ? pow(max(0, sin((phase - 2) * .pi * 2)), 10) : 0
        let crescendo = phase >= 7 && phase < 10 ? (phase - 7) / 3 : 0
        let samples = (0..<8_192).map { index -> Float in
            let t = Double(index) / rate
            guard phase >= 2, phase < 10 else { return 0 }
            if phase < 5 { return Float((0.13 + pulse * 0.58) * sin(2 * .pi * 80 * t)) }
            if phase < 7 {
                let frequency = 80 * pow(150, (phase - 5) / 2)
                return Float(0.45 * sin(2 * .pi * frequency * t))
            }
            return Float(crescendo * 0.82 * (sin(2 * .pi * 80 * t) * 0.5 + sin(2 * .pi * 1_000 * t) * 0.3 + sin(2 * .pi * 8_000 * t) * 0.2))
        }
        var levels = AudioBandAnalysis.analyze(samples: samples, sampleRate: rate)
        levels.beat = Float(pulse)
        return levels

    }
}

// Original PCM-only rhythm exercise shared conceptually with the opt-in test export.
private enum OrbitRhythmQAFixture {
    static let duration = 16.0
    static let sampleRate = 44_100.0
    private enum Voice { case kick, snare, hat }
    private struct Event {
        var time: Double
        var voice: Voice
        var amplitude: Double
    }
    private static let events: [Event] = {
        var result: [Event] = [
            .init(time: 1, voice: .kick, amplitude: 0.78),
            .init(time: 1.5, voice: .kick, amplitude: 0.56),
            .init(time: 3, voice: .snare, amplitude: 0.73),
            .init(time: 3.5, voice: .snare, amplitude: 0.52),
            .init(time: 5, voice: .hat, amplitude: 0.56),
            .init(time: 5.25, voice: .hat, amplitude: 0.35),
            .init(time: 5.5, voice: .hat, amplitude: 0.49),
            .init(time: 5.75, voice: .hat, amplitude: 0.31)
        ]
        // Five seconds of 120 BPM quarter-note kicks, backbeats, and eighth hats.
        for index in 0..<10 {
            result.append(.init(time: 7 + Double(index) * 0.5, voice: .kick,
                                amplitude: index.isMultiple(of: 4) ? 0.72 : 0.59))
            if !index.isMultiple(of: 2) {
                result.append(.init(time: 7 + Double(index) * 0.5, voice: .snare, amplitude: 0.46))
            }
        }
        for index in 0..<20 {
            result.append(.init(time: 7 + Double(index) * 0.25, voice: .hat,
                                amplitude: index.isMultiple(of: 2) ? 0.21 : 0.13))
        }
        // A one-second rest precedes a denser two-second fill with actual rising gain.
        for index in 0..<4 {
            result.append(.init(time: 13 + Double(index) * 0.5, voice: .kick,
                                amplitude: 0.52 + Double(index) * 0.07))
            result.append(.init(time: 13.25 + Double(index) * 0.5, voice: .snare,
                                amplitude: 0.32 + Double(index) * 0.05))
        }
        for index in 0..<16 {
            result.append(.init(time: 13 + Double(index) * 0.125, voice: .hat,
                                amplitude: 0.13 + Double(index) * 0.006))
        }
        return result
    }()
    static let pcm: [Float] = {
        var output = [Float](repeating: 0, count: Int(duration * sampleRate))
        for event in events {
            let length: Double
            let decay: Double
            switch event.voice {
            case .kick: length = 0.46; decay = 0.11
            case .snare: length = 0.27; decay = 0.065
            case .hat: length = 0.11; decay = 0.026
            }
            let start = Int((event.time * sampleRate).rounded())
            for index in 0..<Int(length * sampleRate) {
                guard start + index < output.count else { break }
                let age = Double(index) / sampleRate
                let envelope = (1 - exp(-age / 0.0025)) * exp(-age / decay)
                    * min(1, max(0, (length - age) / 0.01))
                let carrier: Double
                switch event.voice {
                case .kick:
                    carrier = sin(2 * .pi * 80 * age) * 0.85 + sin(2 * .pi * 160 * age) * 0.15
                case .snare:
                    carrier = sin(2 * .pi * 880 * age) * 0.46 + sin(2 * .pi * 1_350 * age) * 0.34
                        + sin(2 * .pi * 2_150 * age) * 0.2
                case .hat:
                    carrier = sin(2 * .pi * 7_400 * age) * 0.40 + sin(2 * .pi * 10_400 * age) * 0.35
                        + sin(2 * .pi * 13_700 * age) * 0.25
                }
                output[start + index] += Float(event.amplitude * envelope * carrier)
            }
        }
        // Fixed full-scale safety clipping only, never input-dependent normalization.
        return output.map { min(1, max(-1, $0)) }
    }()
    static func levels(at time: Double) -> AudioLevels {
        let end = Int((min(duration, max(0, time)) * sampleRate).rounded())
        let samples: [Float] = (0..<8_192).map { offset in
            let index = end - 8_192 + offset
            return pcm.indices.contains(index) ? pcm[index] : 0
        }
        return AudioBandAnalysis.analyze(samples: samples, sampleRate: sampleRate)
    }
    static func phase(at time: Double) -> String {
        switch time {
        case ..<1: "留白"
        case ..<2.15: "独立起音 ①"
        case ..<3: "留白"
        case ..<4.15: "独立起音 ②"
        case ..<5: "留白"
        case ..<6.15: "独立起音 ③"
        case ..<7: "留白"
        case ..<12: "120 BPM 组合节奏"
        case ..<13: "节奏间隙"
        case ..<15: "密集加重"
        default: "收尾留白"
        }
    }
}
