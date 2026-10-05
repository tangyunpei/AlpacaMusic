import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import AlpacaMusic

/// Original fixed-gain PCM, deliberately separated into three registers before
/// combining them. No real music, accounts, audio device, or library is accessed.
private enum RibbonDesignFixture {
    static let duration = 12.0
    static let sampleRate = 44_100.0
    private struct Tone {
        let start: Double
        let end: Double
        let frequency: Double
        let amplitude: Double
        let attack: Double
        let release: Double
    }
    private struct Attack {
        let time: Double
        let frequency: Double
        let amplitude: Double
        let decay: Double
    }
    private static let tones: [Tone] = [
        .init(start: 0.8, end: 2.4, frequency: 80, amplitude: 0.20, attack: 0.35, release: 0.30),
        .init(start: 3.0, end: 4.6, frequency: 1_000, amplitude: 0.20, attack: 0.35, release: 0.30),
        .init(start: 5.2, end: 6.6, frequency: 8_000, amplitude: 0.17, attack: 0.30, release: 0.25)
    ]
    private static let attacks: [Attack] = {
        var result: [Attack] = [
            .init(time: 1.20, frequency: 80, amplitude: 0.48, decay: 0.16),
            .init(time: 1.80, frequency: 80, amplitude: 0.38, decay: 0.13),
            .init(time: 3.40, frequency: 1_000, amplitude: 0.43, decay: 0.12),
            .init(time: 4.00, frequency: 1_000, amplitude: 0.33, decay: 0.10),
            .init(time: 5.55, frequency: 8_000, amplitude: 0.38, decay: 0.08),
            .init(time: 6.05, frequency: 8_000, amplitude: 0.29, decay: 0.07)
        ]
        // Eight quarter-note foundations, four off-beat replies, and sixteen
        // light eighth-note attacks. Their different envelopes come from PCM.
        for index in 0..<8 {
            result.append(.init(time: 7 + Double(index) * 0.5, frequency: 80,
                                amplitude: index.isMultiple(of: 4) ? 0.55 : 0.42, decay: 0.15))
        }
        for index in 0..<4 {
            result.append(.init(time: 7.25 + Double(index), frequency: 1_000,
                                amplitude: 0.34 + Double(index) * 0.02, decay: 0.11))
        }
        for index in 0..<16 {
            result.append(.init(time: 7 + Double(index) * 0.25, frequency: 8_000,
                                amplitude: index.isMultiple(of: 2) ? 0.19 : 0.13, decay: 0.055))
        }
        return result
    }()
    static let pcm: [Float] = {
        var result = [Float](repeating: 0, count: Int(duration * sampleRate))
        for tone in tones {
            let start = Int(tone.start * sampleRate)
            let end = min(result.count, Int(tone.end * sampleRate))
            for index in start..<end {
                let time = Double(index) / sampleRate
                let rise = min(1, max(0, (time - tone.start) / tone.attack))
                let fall = min(1, max(0, (tone.end - time) / tone.release))
                let envelope = smoothstep(rise) * smoothstep(fall)
                let carrier = sin(2 * .pi * tone.frequency * (time - tone.start))
                result[index] += Float(tone.amplitude * envelope * carrier)
            }
        }
        for attack in attacks {
            let length = attack.decay * 6
            let start = Int((attack.time * sampleRate).rounded())
            for offset in 0..<Int(length * sampleRate) {
                guard start + offset < result.count else { break }
                let age = Double(offset) / sampleRate
                let envelope = (1 - exp(-age / 0.003)) * exp(-age / attack.decay)
                    * min(1, max(0, (length - age) / 0.012))
                let carrier = sin(2 * .pi * attack.frequency * age)
                result[start + offset] += Float(attack.amplitude * envelope * carrier)
            }
        }
        // Fixed full-scale safety clipping; never normalize a quiet section.
        return result.map { min(1, max(-1, $0)) }
    }()
    private static func smoothstep(_ value: Double) -> Double { value * value * (3 - 2 * value) }
    static func snapshot(at time: Double) -> [Float] {
        let end = Int((min(duration, max(0, time)) * sampleRate).rounded())
        return (0..<8_192).map { offset in
            let index = end - 8_192 + offset
            return pcm.indices.contains(index) ? pcm[index] : 0
        }
    }
    static func writePCM(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count))!
        buffer.frameLength = AVAudioFrameCount(pcm.count)
        pcm.withUnsafeBufferPointer { samples in
            buffer.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

private enum RibbonExportFailure: Error { case analyzerTimeout, missingTrack, compositionTrack, exportSession }

/// Opt-in native GPU evidence. Ordinary test runs return before allocating PCM,
/// opening a worker, drawing a frame, or creating an asset writer.
@Suite(.serialized) @MainActor struct RibbonDesignExportTests {
    @Test func exportThreeBandRibbonEvidence() async throws {
        guard let path = ProcessInfo.processInfo.environment["ALPACA_EXPORT_BAND_RIBBONS"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 1_280, height: 720)
        let moments: [(String, Int)] = [
            ("静音", 15), ("独立段一：渐入", 33), ("独立段一：起音", 39),
            ("独立段二：渐入", 99), ("独立段二：起音", 105),
            ("独立段三：渐入", 162), ("独立段三：起音", 168),
            ("组合节奏", 214), ("交错起音", 233), ("收尾", 351)
        ]
        let analyzer = AudioAnalyzer()
        var clock = ParticleFieldMotionClock()
        var frames: [ParticleFieldMotionFrame] = []
        var captures: [(String, CGImage)] = []
        var rows = ["time,input_amplitude,bass,mid,treble,envelope_0,envelope_1,envelope_2,pulse_0,pulse_1,pulse_2"]
        var nextMoment = 0
        for index in 0..<Int(RibbonDesignFixture.duration * 30) {
            let time = Double(index) / 30
            // Reset publishes unavailable synchronously, so the subsequent
            // available result cannot accidentally reuse the preceding frame.
            // Each new window includes genuine contiguous PCM filter pre-roll.
            analyzer.reset()
            analyzer.ingest(samples: RibbonDesignFixture.snapshot(at: time), sampleRate: RibbonDesignFixture.sampleRate)
            let levels = try await waitForSnapshot(analyzer)
            let frame = clock.frame(at: time, animated: true, levels: levels)
            frames.append(frame)
            rows.append(String(format: "%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f",
                               time, levels.amplitude, levels.bass, levels.mid, levels.treble,
                               frame.orbitRhythm.energy.x, frame.orbitRhythm.energy.y, frame.orbitRhythm.energy.z,
                               frame.orbitRhythm.pulse.x, frame.orbitRhythm.pulse.y, frame.orbitRhythm.pulse.z))
            if nextMoment < moments.count, index == moments[nextMoment].1 {
                let image = try render(frame, size: size)
                try TemporalDesignExport.png(image, to: directory.appending(path: "ribbons-case-\(nextMoment).png"))
                captures.append(("\(moments[nextMoment].0) / \(String(format: "%.2f", time)) s", image))
                nextMoment += 1
            }
        }
        analyzer.reset()
        try TemporalDesignExport.contactSheet(captures, columns: 2,
                                             to: directory.appending(path: "ribbons-contact-sheet.png"))
        try Data(rows.joined(separator: "\n").utf8).write(to: directory.appending(path: "actual-analysis.csv"), options: .atomic)
        let audioURL = directory.appending(path: "original-three-band-study.wav")
        let silentURL = directory.appending(path: "ribbons-silent.mp4")
        let audibleURL = directory.appending(path: "ribbons-with-audio.mp4")
        for url in [audioURL, silentURL, audibleURL] {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        try RibbonDesignFixture.writePCM(to: audioURL)
        try await TemporalDesignExport.movie(to: silentURL, duration: RibbonDesignFixture.duration) { time in
            let index = min(frames.count - 1, max(0, Int((time * 30).rounded())))
            return try render(frames[index], size: CGSize(width: 960, height: 540))
        }
        try await mux(video: silentURL, audio: audioURL, output: audibleURL)
        let readme = """
        Three-band flowing ribbons: original 12-second mono PCM study, 44.1 kHz.
        No commercial music, accounts, libraries, microphones, or system capture were accessed.
        Production AudioAnalyzer ingests 8,192 contiguous original PCM samples at every frame.
        Each snapshot resets the capture generation and waits for the production worker to publish it.
        No energy, beat, band envelope, or onset is supplied by hand. The real measurements advance
        ParticleFieldMotionClock at 30 fps and its orbitRhythm enters the production Metal pipeline.
        The fixture has separate 80 Hz, 1,000 Hz, and 8,000 Hz sections with smooth gain ramps and attacks.
        0–0.8 s: silence. 0.8–2.4 s: 80 Hz. 3.0–4.6 s: 1,000 Hz. 5.2–6.6 s: 8,000 Hz.
        7–11.1 s: mixed, interlocking 120 BPM attacks followed by silence.
        The three production ribbons represent those registers: peach, purple, and teal.
        Scenes and movies contain no labels or added review subtitles. Contact-sheet captions are outside the scene.
        Clean PNGs are 1,280 x 720; movies are 960 x 540, 30 fps. The audible MP4 includes the exact analyzed PCM.
        actual-analysis.csv records genuine measurements and the production response, not a quality score.
        This export checks GPU appearance and rhythm response; it does not prove Apple Music capture,
        native-window frame rate, or user aesthetic approval.
        """
        try Data(readme.utf8).write(to: directory.appending(path: "README.txt"), options: .atomic)
        print("Three-band ribbon evidence: \(directory.path(percentEncoded: false))")
    }

    private func waitForSnapshot(_ analyzer: AudioAnalyzer) async throws -> AudioLevels {
        for _ in 0..<40 {
            let levels = analyzer.levels()
            if levels.available { return levels }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RibbonExportFailure.analyzerTimeout
    }

    private func render(_ frame: ParticleFieldMotionFrame, size: CGSize) throws -> CGImage {
        try ParticleFieldOffscreen.image(mode: .ribbons, time: Double(frame.time), audio: frame.audio,
                                         orbitRhythm: frame.orbitRhythm, size: size, seed: 0xA17ACA,
                                         glow: true, lowPower: false)
    }

    private func mux(video: URL, audio: URL, output: URL) async throws {
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first else { throw RibbonExportFailure.missingTrack }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RibbonExportFailure.compositionTrack }
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: RibbonDesignFixture.duration, preferredTimescale: 44_100))
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
        try audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw RibbonExportFailure.exportSession }
        try await exporter.export(to: output, as: .mp4)
    }
}
