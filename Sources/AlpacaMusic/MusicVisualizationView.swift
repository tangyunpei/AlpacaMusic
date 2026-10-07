import AppKit
import SwiftUI

struct MusicVisualizationView: View {
    let track: Track?
    let mode: VisualizationMode
    let settings: VisualSettings
    let isPlaying: Bool
    let signal: @MainActor () -> AudioLevels
    var showsStatus = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var clock = VisualizationClock()

    private var reduceMotion: Bool { settings.reduceMotion || systemReduceMotion }
    private var animate: Bool { isPlaying && scenePhase == .active && !reduceMotion }
    private var lowPower: Bool { settings.batterySaver && ProcessInfo.processInfo.isLowPowerModeEnabled }

    var body: some View {
        Group {
            switch mode {
            case .pointCloud:
                PointCloudView(track: track, settings: settings, isPlaying: isPlaying, signal: signal)
            case .artwork:
                albumPresentation
            case .spectrumRing, .ribbons, .starfield:
                ZStack {
                    ParticleFieldView(mode: mode, settings: settings, isPlaying: isPlaying,
                                      isActive: scenePhase == .active, reduceMotion: reduceMotion,
                                      seed: Artwork.seed(for: track), signal: {
                        track?.source.supportsAudioAnalysis != false ? signal() : AudioLevels()
                    })
                    .id(track?.id ?? "empty-particle-stage")
                    .transition(.opacity)
                    if showsStatus {
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            statusLabel(audioAvailable: isPlaying && track?.source.supportsAudioAnalysis != false && signal().available)
                        }
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.9), value: track?.id)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.string("\(mode.title)，\(track?.title ?? "AlpacaMusic")"))
                .accessibilityValue(!isPlaying ? L10n.string("已暂停") : reduceMotion ? L10n.string("减少动态，画面已静止") : track?.source.supportsAudioAnalysis == false ? L10n.string("氛围模式，当前播放通道尚无实时音频采样") : L10n.string("氛围运动，随可用音频变化"))
            case .waveform, .spectrumBars:
                TimelineView(.animation(minimumInterval: lowPower ? 1.0 / 30 : 1.0 / 60, paused: !animate)) { timeline in
                    let levels = isPlaying && scenePhase == .active && track?.source.supportsAudioAnalysis != false ? signal() : AudioLevels()
                    let frame = clock.frame(at: timeline.date, animated: animate, levels: levels, playing: isPlaying,
                                            captureStaticSignal: reduceMotion && isPlaying && scenePhase == .active,
                                            spectrumBarsActive: mode == .spectrumBars)
                    ZStack {
                        Canvas(opaque: true, rendersAsynchronously: false) { context, size in
                            switch mode {
                            case .spectrumBars:
                                SpectrumBarsRenderer.draw(in: &context, size: size, audio: frame.audio, time: frame.time, glow: settings.glow, presentation: frame.spectrumBars)
                            default:
                                WaveformRenderer.draw(in: &context, size: size, audio: frame.audio, time: frame.time, glow: settings.glow)
                            }
                        }
                        .allowsHitTesting(false)
                        if showsStatus || (isPlaying && !frame.audio.available) { statusLabel(audioAvailable: frame.audio.available) }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.string("\(mode.title)，\(track?.title ?? "AlpacaMusic")"))
                .accessibilityValue(!isPlaying ? L10n.string("已暂停") : reduceMotion ? L10n.string("减少动态，画面已静止") : track?.source.supportsAudioAnalysis == false ? L10n.string("当前播放通道尚无实时音频采样，显示静候画面") : mode == .spectrumBars ? L10n.string("显示可用的真实音频频谱") : L10n.string("显示可用的真实音频波形"))
                .onChange(of: animate) { _, _ in clock.resetFrameDate() }
                .onChange(of: track?.id) { _, _ in clock.resetSignal() }
            }
        }
        .clipped()
        .onChange(of: mode) { _, _ in clock.resetSpectrumBars() }
    }

    private var albumAtmosphere: some View {
        GeometryReader { geometry in
            ZStack {
                ArtworkView(track: track, radius: 0, highResolution: true)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .blur(radius: 65).opacity(0.13).saturation(0.65)
                RadialGradient(colors: [Color.black.opacity(0.12), Color.black.opacity(0.03), Color.black.opacity(0.22)],
                               center: .center, startRadius: 0, endRadius: max(1, min(geometry.size.width, geometry.size.height) * 0.65))
            }.allowsHitTesting(false)
        }
    }

    private var albumPresentation: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width * 0.68, geometry.size.height * 0.72)
            ZStack {
                albumAtmosphere
                ArtworkView(track: track, radius: 10, highResolution: true)
                    .frame(width: side, height: side)
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.16), lineWidth: 0.7) }
                    .shadow(color: .black.opacity(0.34), radius: 36, x: 0, y: 22)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func statusLabel(audioAvailable: Bool) -> some View {
        let unavailable = mode.isSignalDisplay
            ? (track?.source.supportsAudioAnalysis == false ? L10n.string("\(track?.source.title ?? L10n.string("当前音源")) · 尚无实时音频采样") : L10n.string("等待音频采样"))
            : (track?.source.supportsAudioAnalysis == false ? L10n.string("氛围模式 · 无实时频谱") : L10n.string("氛围模式"))
        let label = !isPlaying ? L10n.string("已暂停") : reduceMotion ? L10n.string("减少动态") : audioAvailable ? L10n.string("实时音频") : unavailable
        return HStack(spacing: 6) {
            Circle().fill(audioAvailable && isPlaying ? AppPalette.listeningRoom.highlight : .white.opacity(0.3)).frame(width: 3, height: 3)
            Text(label).font(.system(size: 9, weight: .medium)).tracking(0.6).foregroundStyle(.white.opacity(0.42))
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).allowsHitTesting(false)
    }
}

struct VisualizationFrame {
    var time: Double
    var audio: VisualizationAudio
    var spectrumBars: SpectrumBarsPresentation = .empty
}

/// Timeline dates resume after pauses, while this clock only advances on active
/// frames. No wall-clock jump or synthetic beat is introduced on resume.
@MainActor final class VisualizationClock {
    private var previousDate: Date?
    private var time = 0.0
    private var smoothed = VisualizationAudio()
    private var barsClock = SpectrumBarsMotionClock()
    private var barsPresentation = SpectrumBarsPresentation.empty

    func resetFrameDate() { previousDate = nil }
    func resetSpectrumBars() { barsClock.reset(); barsPresentation = .empty }
    func resetSignal() { previousDate = nil; smoothed = VisualizationAudio(); barsClock.reset(); barsPresentation = .empty }

    func frame(at date: Date, animated: Bool, levels: AudioLevels, playing: Bool,
               captureStaticSignal: Bool = false, spectrumBarsActive: Bool = false) -> VisualizationFrame {
        // Freeze the complete composition, including its last real audio shape.
        // A paused/reduced/background render must not snap to a silent frame.
        guard animated else {
            previousDate = nil
            // Entering a scene with reduced motion already enabled still shows
            // one real snapshot. Subsequent frozen frames retain that shape.
            if captureStaticSignal, playing {
                let initial = VisualizationAudio(levels, playing: playing)
                if !initial.available || !smoothed.available || smoothed.sampleRate != initial.sampleRate
                    || smoothed.spectrumBinWidth != initial.spectrumBinWidth || smoothed.waveformDuration != initial.waveformDuration {
                    smoothed = initial
                    if spectrumBarsActive { barsPresentation = barsClock.step(dt: 0, audio: initial, resetInput: true) }
                }
            }
            return VisualizationFrame(time: time, audio: smoothed, spectrumBars: barsPresentation)
        }
        let dt = previousDate.map { min(0.08, max(0, date.timeIntervalSince($0))) } ?? 0
        previousDate = date
        time += dt
        let incoming = VisualizationAudio(levels, playing: playing)
        if spectrumBarsActive { barsPresentation = barsClock.step(dt: dt, audio: incoming) }
        guard incoming.available else {
            smoothed = incoming
            return VisualizationFrame(time: time, audio: incoming, spectrumBars: barsPresentation)
        }
        let follow = 1 - exp(-dt * 12)
        smoothed.energy += (incoming.energy - smoothed.energy) * follow
        smoothed.beat += (incoming.beat - smoothed.beat) * (1 - exp(-dt * 18))
        smoothed.amplitude += (incoming.amplitude - smoothed.amplitude) * follow
        smoothed.bass += (incoming.bass - smoothed.bass) * follow
        smoothed.mid += (incoming.mid - smoothed.mid) * follow
        smoothed.treble += (incoming.treble - smoothed.treble) * follow
        let formatChanged = smoothed.sampleRate != incoming.sampleRate || smoothed.waveformDuration != incoming.waveformDuration
        // All signed traces use the same gentle fixed-gain follow. A changed
        // audio format starts from silence instead of blending unrelated samples.
        let traceFollow = 1 - exp(-dt * 36)
        func followTrace(_ input: [Double], output: inout [Double]) {
            if output.count != input.count || formatChanged { output = Array(repeating: 0, count: input.count) }
            for index in output.indices { output[index] += (input[index] - output[index]) * traceFollow }
        }
        followTrace(incoming.waveform, output: &smoothed.waveform)
        followTrace(incoming.bassWaveform, output: &smoothed.bassWaveform)
        followTrace(incoming.midWaveform, output: &smoothed.midWaveform)
        followTrace(incoming.trebleWaveform, output: &smoothed.trebleWaveform)
        smoothed.waveformDuration = incoming.waveformDuration
        smoothed.sampleRate = incoming.sampleRate
        if smoothed.spectrum.count != incoming.spectrum.count || smoothed.spectrumBinWidth != incoming.spectrumBinWidth {
            smoothed.spectrum = incoming.spectrum
        } else {
            for index in smoothed.spectrum.indices { smoothed.spectrum[index] += (incoming.spectrum[index] - smoothed.spectrum[index]) * follow }
        }
        smoothed.spectrumBinWidth = incoming.spectrumBinWidth
        smoothed.available = true
        return VisualizationFrame(time: time, audio: smoothed, spectrumBars: barsPresentation)
    }
}
