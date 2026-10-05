import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import AlpacaMusic

/// Engineering acceptance for temporal behavior, not an automated aesthetic
/// score. Exported full-speed clips still require human/native review.
@Suite(.serialized) @MainActor struct TemporalDesignTests {
    private let size = CGSize(width: 960, height: 540)
    private struct FragmentState: Equatable {
        let text: String
        let center: CGPoint
        let font: CGFloat
        let rotation: Double
        let opacity: Double
        let scale: CGFloat
        let tracking: CGFloat
    }
    private func states(_ pieces: [LyricTypeFragment]) -> [FragmentState] {
        pieces.map { .init(text: $0.text, center: $0.center, font: $0.fontSize, rotation: $0.rotation, opacity: $0.opacity, scale: $0.scale, tracking: CGFloat($0.tracking)) }
    }
    private func movement(_ first: [LyricTypeFragment], _ last: [LyricTypeFragment]) -> (distance: Double, fontFraction: Double) {
        guard first.count == last.count else { return (.infinity, .infinity) }
        return zip(first, last).reduce((0, 0)) { result, pair in
            (max(result.0, hypot(pair.0.center.x - pair.1.center.x, pair.0.center.y - pair.1.center.y)),
             max(result.1, abs(pair.0.fontSize - pair.1.fontSize) / max(1, pair.0.fontSize)))
        }
    }

    @Test(arguments: LyricScene.allCases)
    func ordinaryLyricsHaveVisibleMidSentenceEvolution(_ scene: LyricScene) {
        let line = LyricLine(id: 0, text: "把窗外的雨交给缓慢旋转的夜", start: 0, end: 8)
        let first = LyricTypography.layout(line: line, index: scene.rawValue, in: size, position: 2, reduceMotion: false)
        let last = LyricTypography.layout(line: line, index: scene.rawValue, in: size, position: 6, reduceMotion: false)
        #expect(!first.isEmpty && first.count == last.count)
        let travel = movement(first, last)
        // A lower bound on the agreed composition travel; opacity changes or
        // subpixel drift alone do not pass. This is not a quality rating.
        #expect(travel.distance >= size.height * 0.04 || travel.fontFraction >= 0.08)
        #expect(first.allSatisfy { $0.timedStart == nil && $0.timedEnd == nil })
        var previous = first
        for frame in 1...120 {
            let now = LyricTypography.layout(line: line, index: scene.rawValue, in: size, position: 2 + Double(frame) / 30, reduceMotion: false)
            #expect(now.count == previous.count)
            #expect(movement(previous, now).distance < size.width * 0.12)
            #expect(now.allSatisfy { $0.center.x.isFinite && $0.center.y.isFinite && $0.fontSize.isFinite && $0.opacity.isFinite })
            previous = now
        }
    }

    @Test func scenesHaveDistinctCompositionsAndSeekingReconstructsExactFrames() {
        let line = LyricLine(id: 0, text: "Small rivers of light cross the room", start: 0, end: 8)
        var fingerprints = Set<String>()
        for scene in LyricScene.allCases {
            let initial = LyricTypography.layout(line: line, index: scene.rawValue, in: size, position: 4, reduceMotion: false)
            _ = LyricTypography.layout(line: line, index: scene.rawValue, in: size, position: 7.9, reduceMotion: false)
            let revisited = LyricTypography.layout(line: line, index: scene.rawValue, in: size, position: 4, reduceMotion: false)
            #expect(states(initial) == states(revisited))
            fingerprints.insert(initial.map { piece in
                [piece.center.x / 8, piece.center.y / 8, piece.fontSize / 2, CGFloat(piece.rotation), CGFloat(piece.tracking)].map { String(Int($0.rounded())) }.joined(separator: ",")
            }.joined(separator: ";"))
        }
        #expect(fingerprints.count >= 6)
    }

    @Test func reducedMotionIsStationaryAndLineTransitionUsesBoundedOutgoingText() {
        let document = TemporalDesignFixture.document
        let early = LyricTypography.frame(document: document, position: 4.65, in: size, reduceMotion: false)
        #expect(early.activeLineID == 1)
        #expect(early.fragments.contains { $0.role == .outgoing && $0.lineID == 0 })
        let settled = LyricTypography.frame(document: document, position: 5.1, in: size, reduceMotion: false)
        #expect(!settled.fragments.contains { $0.role == .outgoing })
        let first = LyricTypography.frame(document: document, position: 5.3, in: size, reduceMotion: true)
        let last = LyricTypography.frame(document: document, position: 7.4, in: size, reduceMotion: true)
        #expect(first.activeLineID == last.activeLineID)
        #expect(states(first.fragments) == states(last.fragments))
        #expect(first.fragments.allSatisfy { $0.role == .primary && $0.opacity == 1 && $0.scale == 1 })
        // Direct time evaluation must also reproduce a paused frame exactly.
        #expect(states(settled.fragments) == states(LyricTypography.frame(document: document, position: 5.1, in: size, reduceMotion: false).fragments))
    }

    @Test func productionFramesAreDeterministicAndRespectUnavailableAudio() throws {
        let probeSize = CGSize(width: 320, height: 180)
        let intense = TemporalDesignFixture.signal(at: 9.9)
        var modeFrames: [[UInt8]] = []
        for mode in TemporalDesignFixture.modes {
            let zero = try TemporalDesignExport.rgba(TemporalDesignExport.visualization(mode: mode, time: 0, size: probeSize))
            let one = try TemporalDesignExport.rgba(TemporalDesignExport.visualization(mode: mode, time: 1, size: probeSize))
            let three = try TemporalDesignExport.rgba(TemporalDesignExport.visualization(mode: mode, time: 3, size: probeSize))
            let again = try TemporalDesignExport.rgba(TemporalDesignExport.visualization(mode: mode, time: 1, size: probeSize))
            // Rendering another time then revisiting the same pose must not
            // depend on pipeline history. Pause-clock tests live separately.
            let repeated = TemporalDesignExport.difference(one, again)
            print("Repeated frame \(mode.rawValue): changed=\(repeated.changedPixelFraction), mean=\(repeated.meanChannelDifference)")
            #expect(one == again)
            if mode.isSignalDisplay {
                #expect(zero == one && one == three)
            } else {
                // Detect a disconnected clock, without calling the amount of
                // changed pixels an aesthetic or frame-rate acceptance test.
                #expect(zero != one && one != three)
            }
            let reactive = try TemporalDesignExport.rgba(TemporalDesignExport.visualization(mode: mode, time: 1, audio: intense, size: probeSize))
            #expect(one != reactive)
            let frozenReactive = try TemporalDesignExport.rgba(TemporalDesignExport.visualization(mode: mode, time: 1, audio: intense, size: probeSize))
            #expect(reactive == frozenReactive)
            modeFrames.append(one)
        }
        for index in modeFrames.indices {
            for next in modeFrames.indices where next > index {
                #expect(modeFrames[index] != modeFrames[next])
            }
        }
    }

    @Test func productionAdjacentFramesProvideFiniteContinuityDiagnostics() throws {
        let times = (0..<7).map { 3.25 + Double($0) / 30 }
        let heldAudio = TemporalDesignFixture.signal(at: 3.25)
        for mode in TemporalDesignFixture.modes {
            let samples = try TemporalDesignExport.continuity(mode: mode, times: times, size: .init(width: 320, height: 180)) { _ in heldAudio }
            #expect(samples.count == times.count - 1)
            #expect(samples.allSatisfy { $0.difference.meanChannelDifference.isFinite && $0.difference.changedPixelFraction.isFinite })
            if mode.isSignalDisplay {
                #expect(samples.allSatisfy { $0.difference.meanChannelDifference == 0 })
            }
            let largest = samples.map(\.difference.meanChannelDifference).max() ?? 0
            print("Adjacent 30fps \(mode.rawValue), fixed signal: maximum mean channel difference=\(largest) (diagnostic only)")
        }
    }

    @Test func controlledSignalIncludesSilenceDistinctBandsAndAbruptStop() {
        let silence = TemporalDesignFixture.signal(at: 1), bass = TemporalDesignFixture.signal(at: 2.04)
        let high = TemporalDesignFixture.signal(at: 6.8), crescendo = TemporalDesignFixture.signal(at: 9.9), stop = TemporalDesignFixture.signal(at: 10)
        #expect(silence.available && silence.energy == 0 && silence.spectrum.allSatisfy { $0 == 0 })
        #expect(silence.waveform.count == 1_024 && silence.waveform.allSatisfy { $0 == 0 })
        let bassPeak = bass.spectrum.indices.max { bass.spectrum[$0] < bass.spectrum[$1] } ?? 0
        let highPeak = high.spectrum.indices.max { high.spectrum[$0] < high.spectrum[$1] } ?? 0
        #expect(bass.beat > 0.5 && Double(bassPeak) * bass.spectrumBinWidth < 250)
        #expect(bass.bass > bass.treble && bass.amplitude > 0)
        #expect(bass.waveform.contains { $0 > 0 } && bass.waveform.contains { $0 < 0 })
        #expect(abs(bass.waveformDuration - 1_023.0 / 44_100) < 0.000_001 && bass.waveform.count == 1_024)
        #expect(Double(highPeak) * high.spectrumBinWidth > 4_000)
        #expect(high.treble > high.bass)
        #expect(crescendo.energy > 0.9)
        #expect(stop.available && stop.energy == 0 && stop.beat == 0)
        #expect(stop.waveform.allSatisfy { $0 == 0 } && stop.amplitude == 0)
        #expect(stop.bassWaveform.allSatisfy { $0 == 0 } && stop.midWaveform.allSatisfy { $0 == 0 } && stop.trebleWaveform.allSatisfy { $0 == 0 })
        #expect(!VisualizationAudio().available)
    }

    @Test func signalDisplaysStayStationaryForSilenceAndDistinguishActualToneBands() throws {
        let probeSize = CGSize(width: 640, height: 360)
        let silence = TemporalDesignFixture.tone(frequencies: [])
        let tones = [80.0, 1_000, 8_000].map { TemporalDesignFixture.tone(frequencies: [$0]) }
        for (frequency, tone) in zip([80.0, 1_000, 8_000], tones) {
            let peak = tone.spectrum.indices.max { tone.spectrum[$0] < tone.spectrum[$1] } ?? 0
            #expect(abs(Double(peak) * tone.spectrumBinWidth - frequency) <= tone.spectrumBinWidth)
            #expect(tone.sampleRate == 44_100 && tone.spectrum.count == 1_024)
            #expect([tone.bassWaveform, tone.midWaveform, tone.trebleWaveform].allSatisfy { $0.count == 1_024 })
        }
        for mode in TemporalDesignFixture.signalModes {
            let still = try TemporalDesignExport.rgba(TemporalDesignExport.visualization(mode: mode, time: 0, audio: silence, size: probeSize))
            let later = try TemporalDesignExport.rgba(TemporalDesignExport.visualization(mode: mode, time: 30, audio: silence, size: probeSize))
            #expect(still == later)
            let pixels = try tones.map { try TemporalDesignExport.rgba(TemporalDesignExport.visualization(mode: mode, time: 0, audio: $0, size: probeSize)) }
            #expect(pixels[0] != pixels[1] && pixels[1] != pixels[2] && pixels[0] != pixels[2])
        }
    }

    @Test func orbitalFieldUsesMeasuredBandTracesWhilePreservingItsAmbientMotion() throws {
        let probeSize = CGSize(width: 640, height: 360)
        let noAudio = try TemporalDesignExport.rgba(TemporalDesignExport.visualization(mode: .spectrumRing, time: 3, size: probeSize))
        let scalarsWithoutTraces = AudioLevels(energy: 0.9, beat: 1, available: true,
                                             amplitude: 0.8, bass: 1, mid: 1, treble: 1)
        let scalarFrame = try TemporalDesignExport.rgba(TemporalDesignExport.visualization(
            mode: .spectrumRing, time: 3, audio: scalarsWithoutTraces, size: probeSize))
        // The orbital appearance has its own gentle motion. A beat or a band
        // scalar alone must not be presented as an invented oscilloscope trace.
        #expect(noAudio == scalarFrame)
        let laterAmbient = try TemporalDesignExport.rgba(TemporalDesignExport.visualization(mode: .spectrumRing, time: 4, size: probeSize))
        #expect(noAudio != laterAmbient)
        let tones = [80.0, 1_000, 8_000].map { TemporalDesignFixture.tone(frequencies: [$0]) }
        let pixels = try tones.map { try TemporalDesignExport.rgba(TemporalDesignExport.visualization(
            mode: .spectrumRing, time: 3, audio: $0, size: probeSize)) }
        #expect(pixels.allSatisfy { $0 != noAudio })
        #expect(pixels[0] != pixels[1] && pixels[1] != pixels[2] && pixels[0] != pixels[2])
    }

    /// Focused production-Metal orbit and Canvas bar evidence. Inputs are
    /// original deterministic PCM, analysed by the same production DSP helper.
    @Test func exportBandScopeEvidence() async throws {
        guard let directoryPath = ProcessInfo.processInfo.environment["ALPACA_EXPORT_BAND_SCOPES"] else { return }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cases: [(String, AudioLevels)] = [
            ("无实时音频 / WAITING", AudioLevels()),
            ("合成音频 / SILENCE", TemporalDesignFixture.tone(frequencies: [])),
            ("合成音频 / LOW 80 Hz", TemporalDesignFixture.tone(frequencies: [80])),
            ("合成音频 / MID 1 kHz", TemporalDesignFixture.tone(frequencies: [1_000])),
            ("合成音频 / HIGH 8 kHz", TemporalDesignFixture.tone(frequencies: [8_000])),
            ("合成音频 / 80 Hz + 1 kHz + 8 kHz", TemporalDesignFixture.tone(frequencies: [80, 1_000, 8_000]))
        ]
        var contact: [(String, CGImage)] = []
        for (index, item) in cases.enumerated() {
            for mode in [VisualizationMode.spectrumRing, .spectrumBars] {
                let frame = try TemporalDesignExport.visualization(mode: mode, time: 0, audio: item.1, size: size)
                let name = "\(mode.title) / \(item.0)"
                contact.append((name, frame))
                try TemporalDesignExport.png(frame, to: directory.appending(path: "\(mode.rawValue)-case-\(index).png"))
            }
        }
        try TemporalDesignExport.contactSheet(contact, columns: 2, to: directory.appending(path: "band-scopes-contact-sheet.png"))
        let readme = """
        Original production 3D orbital particle field and Canvas vertical bars receive original synthetic QA PCM.
        8,192 signed samples at 44.1 kHz pass through AudioBandAnalysis.analyze.
        All three orbital band traces and FFT bins come from that production DSP helper.
        Tone checks: silence; 80 Hz; 1 kHz; 8 kHz; equally weighted mixed tones.
        Production orbit rendering has no LOW/MID/HIGH labels; only export captions identify QA input cases.
        With no band PCM, the original orbital ambience remains, without manufactured audio modulation.
        Still images use raw analysis values. Orbit movies use ParticleFieldMotionClock; bars use VisualizationClock.
        Movies are intentionally silent and labelled as synthetic test inputs.
        They do not establish Apple Music capture support or native frame rate.
        """
        try Data(readme.utf8).write(to: directory.appending(path: "README.txt"), options: .atomic)
        if ProcessInfo.processInfo.environment["ALPACA_BAND_SCOPES_VIDEO"] == "1" {
            for mode in [VisualizationMode.spectrumRing, .spectrumBars] {
                let signalClock = VisualizationClock()
                var particleClock = ParticleFieldMotionClock()
                try await TemporalDesignExport.movie(to: directory.appending(path: "\(mode.rawValue)-preview.mp4"), duration: 12) { time in
                    let levels = TemporalDesignFixture.signal(at: time)
                    let image: CGImage
                    if mode.isSignalDisplay {
                        let frame = signalClock.frame(at: Date(timeIntervalSinceReferenceDate: time), animated: true,
                                                      levels: levels, playing: true)
                        image = try TemporalDesignExport.signal(mode: mode, time: frame.time, audio: frame.audio, size: size)
                    } else {
                        let frame = particleClock.frame(at: time, animated: true, levels: levels)
                        image = try TemporalDesignExport.visualization(mode: mode, time: Double(frame.time), audio: frame.audio, size: size)
                    }
                    return try TemporalDesignExport.labelled(image,
                        text: "合成测试音频 / \(TemporalDesignFixture.phase(at: time)) / \(String(format: "%.2f", time))s", size: size)
                }
            }
        }
        print("Band scope evidence: \(directory.path(percentEncoded: false))")
    }

    /// Run only when requested: ALPACA_TEMPORAL_QA_OUTPUT=/absolute/temp/path.
    /// Add ALPACA_TEMPORAL_QA_VIDEO=1 for silent 30fps clips (no GUI/audio/network).
    @Test func exportProductionTemporalEvidence() async throws {
        guard let directoryPath = ProcessInfo.processInfo.environment["ALPACA_TEMPORAL_QA_OUTPUT"] else { return }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true).appending(path: "run-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var contact: [(String, CGImage)] = []
        var signalContact: [(String, CGImage)] = []
        var changes: [String: TemporalDesignExport.Difference] = [:]
        var adjacent: [String: [TemporalDesignExport.ContinuitySample]] = [:]
        for mode in TemporalDesignFixture.modes {
            var previous: [UInt8]?
            for time in [0.0, 1, 3] {
                let image = try TemporalDesignExport.visualization(mode: mode, time: time, size: size)
                try TemporalDesignExport.png(image, to: directory.appending(path: "\(mode.rawValue)-ambience-t\(Int(time)).png"))
                contact.append(("\(mode.rawValue) / \(mode.isSignalDisplay ? "waiting" : "ambience") / \(Int(time))s", image))
                let pixels = try TemporalDesignExport.rgba(image)
                if let previous { changes["\(mode.rawValue)-through-\(Int(time))s"] = TemporalDesignExport.difference(previous, pixels) }
                previous = pixels
            }
            for time in [1.0, 2.04, 5.8, 6.8, 9.9, 10.04] {
                let image = try TemporalDesignExport.visualization(mode: mode, time: time, audio: TemporalDesignFixture.signal(at: time), size: size)
                let label = "\(mode.rawValue) / QA \(TemporalDesignFixture.phase(at: time))"
                signalContact.append((label, image))
                try TemporalDesignExport.png(image, to: directory.appending(path: "\(mode.rawValue)-synthetic-t\(String(format: "%.2f", time)).png"))
            }
            let heldAudio = TemporalDesignFixture.signal(at: 3.25)
            adjacent["\(mode.rawValue)-held-input"] = try TemporalDesignExport.continuity(
                mode: mode, times: (0..<16).map { 3.25 + Double($0) / 30 }, size: size
            ) { _ in heldAudio }
            adjacent["\(mode.rawValue)-synthetic-stop"] = try TemporalDesignExport.continuity(
                mode: mode, times: (0..<10).map { 9.85 + Double($0) / 30 }, size: size,
                signal: TemporalDesignFixture.signal(at:)
            )
        }
        try TemporalDesignExport.contactSheet(contact, columns: 3, to: directory.appending(path: "visualization-contact-sheet.png"))
        try TemporalDesignExport.contactSheet(signalContact, columns: 3, to: directory.appending(path: "visualization-synthetic-phases.png"))
        try JSONEncoder().encode(changes).write(to: directory.appending(path: "frame-differences.json"), options: .atomic)
        try JSONEncoder().encode(adjacent).write(to: directory.appending(path: "adjacent-frame-diagnostics.json"), options: .atomic)
        var lyricContact: [(String, CGImage)] = []
        for line in TemporalDesignFixture.document.lines {
            for offset in [0.3, 1.75, 2.7] {
                let time = (line.start ?? 0) + offset
                let image = try TemporalDesignExport.image(KineticLyricFrameView(document: TemporalDesignFixture.document, position: time, reduceMotion: false), size: size)
                lyricContact.append(("scene \(line.id) / \(String(format: "%.2f", time))s", image))
            }
        }
        try TemporalDesignExport.contactSheet(lyricContact, columns: 3, to: directory.appending(path: "lyric-storyboard.png"))
        let instructions = """
        Engineering exports only; no visual-quality acceptance is implied.
        Production particle renderer: native Metal pipeline into a shared sRGB texture, fixed seed.
        Original 3D orbital field: native Metal preserves the particle-tube composition while actual band-filtered PCM modulates its three tubes.
        Production signal renderers: waveform and vertical bars use Canvas receiving analysed signed QA PCM.
        Static snapshots and adjacent-frame diagnostics use raw fixture inputs to isolate renderer behavior.
        Videos advance the production ParticleFieldMotionClock or VisualizationClock sequentially at 30fps before drawing.
        The available source supplies zeros at the stop, so the production clocks perform their normal release rather than discarding the signal.
        Unavailable-audio captures at 0/1/3 seconds: particles show ambience; signal displays remain stationary.
        Production kinetic view: original line-timed text (no invented word timing).
        Optional videos are silent, 960x540 at 30fps. Watch them at normal speed, not just their contact sheets.
        Synthetic QA signal: silence 0–2s, 80Hz impulses 2–5s, 80Hz-to-12kHz sweep 5–7s, mixed-band crescendo 7–10s, silence 10–12s.
        Original signed 8,192-sample PCM passes through production AudioBandAnalysis; 1,024-sample output traces represent approximately 23.2ms at 44.1kHz.
        Every FFT bin and filtered trace comes from PCM. Fixture energy/beat markers explicitly describe the test envelope, not audio-tap verification.
        Adjacent 30fps diagnostics include both held input and the labelled abrupt stop; they are not aesthetic scores or native-frame-rate measurements.
        Native pause/resume, reduced motion, real PCM delivery and live playback still require separate observation.
        """
        try Data(instructions.utf8).write(to: directory.appending(path: "README.txt"), options: .atomic)
        if ProcessInfo.processInfo.environment["ALPACA_TEMPORAL_QA_VIDEO"] == "1" {
            for mode in TemporalDesignFixture.modes {
                var particleClock = ParticleFieldMotionClock()
                let waveformClock = VisualizationClock()
                try await TemporalDesignExport.movie(to: directory.appending(path: "\(mode.rawValue)-signal-study.mp4"), duration: 12) { time in
                    let levels = TemporalDesignFixture.signal(at: time)
                    let frame: CGImage
                    if mode.isSignalDisplay {
                        let smoothed = waveformClock.frame(at: Date(timeIntervalSinceReferenceDate: time), animated: true,
                                                           levels: levels, playing: true)
                        frame = try TemporalDesignExport.signal(mode: mode, time: smoothed.time, audio: smoothed.audio, size: size)
                    } else {
                        let smoothed = particleClock.frame(at: time, animated: true, levels: levels)
                        frame = try TemporalDesignExport.visualization(mode: mode, time: Double(smoothed.time), audio: smoothed.audio, size: size)
                    }
                    return try TemporalDesignExport.labelled(frame,
                        text: "SYNTHETIC QA / \(TemporalDesignFixture.phase(at: time)) / \(String(format: "%.2f", time))s", size: size)
                }
            }
            try await TemporalDesignExport.movie(to: directory.appending(path: "lyrics-continuous-original.mp4"), duration: 30) { time in
                try TemporalDesignExport.image(KineticLyricFrameView(document: TemporalDesignFixture.document, position: time, reduceMotion: false), size: size)
            }
        }
        print("Temporal design evidence: \(directory.path(percentEncoded: false))")
    }
}
