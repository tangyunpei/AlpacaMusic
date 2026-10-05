import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import AlpacaMusic

/// Deterministic original text and labelled synthetic inputs; never opens a
/// library, account, window or audio device. Exported movies are intentionally silent.
enum TemporalDesignFixture {
    static let particleModes: [VisualizationMode] = [.spectrumRing, .ribbons, .starfield]
    static let signalModes: [VisualizationMode] = [.waveform, .spectrumBars]
    static let modes: [VisualizationMode] = particleModes + signalModes
    static let document = LyricDocument(lines: [
        "把窗外的雨，交给缓慢旋转的夜", "Small rivers of light cross the room", "我们把回声写成一座桥", "Let the horizon open between these words",
        "让每一次停顿，都有呼吸的空间", "A quiet signal gathers into silver", "在风里，找回此刻的方向", "And all the scattered letters find a home"
    ].enumerated().map { index, text in
        LyricLine(id: index, text: text, start: Double(index) * 3.5 + 1, end: Double(index + 1) * 3.5 + 1,
                  translation: index.isMultiple(of: 2) ? "Original motion-study text" : "原创动态研究文本")
    }, timing: .line, sourceDescription: "原创连续动态测试", title: "Light Studies", artist: "AlpacaMusic QA")

    static func signal(at time: Double) -> AudioLevels {
        let time = min(12, max(0, time))
        let sampleRate = 44_100.0
        let inputCount = 8_192
        // The 185.7ms original QA input gives the production filters pre-roll;
        // the renderer receives their actual 1,024-sample signed output window.
        let duration = Double(inputCount - 1) / sampleRate
        let chirpRate = log(12_000.0 / 80) / 2
        func cycles(at seconds: Double) -> Double {
            if seconds < 5 { return (seconds - 2) * 80 }
            let chirpEnd = 240 + 80 / chirpRate * (exp(chirpRate * 2) - 1)
            if seconds < 7 { return 240 + 80 / chirpRate * (exp(chirpRate * (seconds - 5)) - 1) }
            return chirpEnd + (seconds - 7) * 440
        }
        func beat(at seconds: Double) -> Double {
            guard seconds >= 2, seconds < 5 else { return 0 }
            return exp(-((seconds - 2).truncatingRemainder(dividingBy: 0.5)) * 12)
        }
        func energy(at seconds: Double) -> Double {
            if seconds < 2 || seconds >= 10 { return 0 }
            if seconds < 5 { return 0.14 + beat(at: seconds) * 0.68 }
            if seconds < 7 { return 0.55 }
            return 0.2 + (seconds - 7) * (0.8 / 3)
        }
        let samples: [Float] = (0..<inputCount).map { index in
            guard time >= 2, time < 10 else { return 0 }
            let seconds = time - duration + Double(index) / sampleRate
            guard seconds >= 2, seconds < 10 else { return 0 }
            let amplitude = energy(at: seconds)
            if seconds >= 7 {
                let phases = [80.0, 1_000, 8_000].map { sin(2 * .pi * $0 * seconds) }
                return Float(phases.reduce(0, +) / 3 * amplitude)
            }
            return Float(sin(cycles(at: seconds) * .pi * 2) * amplitude)
        }
        var levels = AudioBandAnalysis.analyze(samples: samples, sampleRate: sampleRate)
        // These two controls deliberately describe the fixture's envelope and
        // pulse markers. Every plotted frequency bin and trace comes from PCM.
        levels.energy = Float(energy(at: time))
        levels.beat = Float(beat(at: time))
        return levels
    }
    static func tone(frequencies: [Double], amplitude: Double = 0.65, time: Double = 0) -> AudioLevels {
        let sampleRate = 44_100.0
        let samples: [Float] = (0..<8_192).map { index in
            guard !frequencies.isEmpty else { return 0 }
            let seconds = time + Double(index) / sampleRate
            return Float(frequencies.reduce(0) { $0 + sin(2 * .pi * $1 * seconds) }
                         / Double(frequencies.count) * amplitude)
        }
        return AudioBandAnalysis.analyze(samples: samples, sampleRate: sampleRate)
    }
    static func phase(at time: Double) -> String {
        switch time {
        case ..<2: "SILENCE"
        case ..<5: "LOW IMPULSES"
        case ..<7: "LOW TO HIGH SWEEP"
        case ..<10: "CRESCENDO"
        default: "SILENCE AFTER STOP"
        }
    }
}

/// A deliberately sparse original groove makes response timing reviewable.
/// The analysis input is continuous PCM, with true silence between attacks;
/// it never injects hand-written beat, energy, or per-band controls.
enum OrbitRhythmFixture {
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

private struct TemporalSignalProbe: View {
    let mode: VisualizationMode
    let time: Double
    var audio = VisualizationAudio()
    var body: some View {
        Canvas(opaque: true, rendersAsynchronously: false) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            switch mode {
            case .waveform:
                WaveformRenderer.draw(in: &context, size: size, audio: audio, time: time, glow: true)
            case .spectrumBars:
                SpectrumBarsRenderer.draw(in: &context, size: size, audio: audio, time: time, glow: true)
            default:
                break
            }
        }
    }
}

private enum TemporalExportFailure: Error { case missingImage, pixelContext, destination, writerFailed, unsupportedMode }

@MainActor enum TemporalDesignExport {
    /// All visual captures route to the production renderer, including the
    /// native Metal particle pipeline rather than an obsolete Canvas stand-in.
    static func visualization(mode: VisualizationMode, time: Double, audio: AudioLevels = AudioLevels(),
                              size: CGSize, seed: UInt64 = 0xA17ACA) throws -> CGImage {
        switch mode {
        case .spectrumRing, .ribbons, .starfield:
            return try ParticleFieldOffscreen.image(mode: mode, time: time, audio: audio, size: size,
                                                    seed: seed, glow: true, lowPower: false)
        case .waveform, .spectrumBars:
            return try signal(mode: mode, time: time, audio: VisualizationAudio(audio), size: size)
        default:
            throw TemporalExportFailure.unsupportedMode
        }
    }
    /// Accepts the production clock's already-smoothed signal without converting
    /// it back to raw samples or advancing a second smoothing filter.
    static func waveform(time: Double, audio: VisualizationAudio, size: CGSize) throws -> CGImage {
        try signal(mode: .waveform, time: time, audio: audio, size: size)
    }
    static func signal(mode: VisualizationMode, time: Double, audio: VisualizationAudio, size: CGSize) throws -> CGImage {
        guard mode.isSignalDisplay else { throw TemporalExportFailure.unsupportedMode }
        return try image(TemporalSignalProbe(mode: mode, time: time, audio: audio), size: size)
    }
    static func labelled(_ frame: CGImage, text: String, size: CGSize) throws -> CGImage {
        try image(Image(decorative: frame, scale: 1).resizable().overlay(alignment: .topLeading) {
            Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.9))
                .padding(10).background(.black.opacity(0.68)).padding(10)
        }, size: size)
    }
    static func image<V: View>(_ view: V, size: CGSize) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).background(.black))
        renderer.proposedSize = ProposedViewSize(size); renderer.scale = 1
        guard let image = renderer.cgImage else { throw TemporalExportFailure.missingImage }
        return image
    }
    static func png(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw TemporalExportFailure.destination }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TemporalExportFailure.destination }
    }
    static func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard success else { throw TemporalExportFailure.pixelContext }
        return bytes
    }
    struct Difference: Codable {
        let changedPixelFraction: Double
        let meanChannelDifference: Double
    }
    struct ContinuitySample: Codable {
        let fromTime: Double
        let toTime: Double
        let fromPhase: String
        let toPhase: String
        let difference: Difference
    }
    /// Adjacent frames are evidence for review, not a motion-quality score. A
    /// labelled stop is expected to differ from a steady segment of the signal.
    static func continuity(mode: VisualizationMode, times: [Double], size: CGSize,
                           signal: (Double) -> AudioLevels) throws -> [ContinuitySample] {
        var samples: [ContinuitySample] = []
        var previous: (time: Double, pixels: [UInt8])?
        for time in times {
            let pixels = try rgba(visualization(mode: mode, time: time, audio: signal(time), size: size))
            if let previous {
                samples.append(.init(fromTime: previous.time, toTime: time,
                                     fromPhase: TemporalDesignFixture.phase(at: previous.time),
                                     toPhase: TemporalDesignFixture.phase(at: time),
                                     difference: difference(previous.pixels, pixels)))
            }
            previous = (time, pixels)
        }
        return samples
    }
    static func difference(_ first: [UInt8], _ second: [UInt8]) -> Difference {
        guard first.count == second.count, !first.isEmpty else { return .init(changedPixelFraction: 1, meanChannelDifference: 255) }
        var changed = 0, total = 0
        for pixel in stride(from: 0, to: first.count, by: 4) {
            var maximum = 0
            for channel in 0..<3 {
                let difference = abs(Int(first[pixel + channel]) - Int(second[pixel + channel]))
                maximum = max(maximum, difference); total += difference
            }
            if maximum >= 8 { changed += 1 }
        }
        let count = Double(first.count / 4)
        return .init(changedPixelFraction: Double(changed) / count, meanChannelDifference: Double(total) / (count * 3))
    }
    static func contactSheet(_ images: [(String, CGImage)], columns: Int, to url: URL) throws {
        let cell = CGSize(width: 320, height: 180)
        let rows = (images.count + columns - 1) / columns
        let view = VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        VStack(spacing: 0) {
                            if index < images.count {
                                Text(images[index].0).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white).frame(width: cell.width, height: 26)
                                Image(decorative: images[index].1, scale: 1).resizable().frame(width: cell.width, height: cell.height)
                            } else { Color.black.frame(width: cell.width, height: cell.height + 26) }
                        }
                    }
                }
            }
        }
        try png(image(view, size: CGSize(width: cell.width * Double(columns), height: (cell.height + 26) * Double(rows))), to: url)
    }

    /// Uses the macOS 26 pixel-buffer receiver rather than the SDK-27-deprecated
    /// writer adaptor/add/startWriting APIs. Appends one frame at a time.
    static func movie(to url: URL, duration: Double, frame: (Double) throws -> CGImage) async throws {
        let width = 960, height = 540, fps: Int32 = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                                                                         AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_800_000]])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: .init(rawValue: kCVPixelFormatType_32BGRA), size: .init(width: width, height: height))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        do {
            try writer.start(); writer.startSession(atSourceTime: .zero)
            for index in 0..<Int(duration * Double(fps)) {
                try Task.checkCancellation()
                let image = try autoreleasepool { try frame(Double(index) / Double(fps)) }
                var mutable = try CVMutablePixelBuffer(attributes)
                try mutable.accessUnsafeMutableRawPlaneBytes { planes in
                    guard let plane = planes.first,
                          let context = CGContext(data: plane.bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: plane.properties.bytesPerRow,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw TemporalExportFailure.pixelContext }
                    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
                try await receiver.append(CVReadOnlyPixelBuffer(mutable), with: CMTime(value: Int64(index), timescale: fps))
            }
            receiver.finish()
            writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: fps))
            await writer.finishWriting()
            guard writer.status == .completed else { throw TemporalExportFailure.writerFailed }
        } catch { writer.cancelWriting(); throw error }
    }
}


/// An opt-in original rhythm study, isolated from the existing mode fixtures.
@Suite(.serialized) @MainActor struct OrbitalRhythmExportTests {
    @Test func exportOrbitalRhythmEvidence() async throws {
        guard let path = ProcessInfo.processInfo.environment["ALPACA_EXPORT_ORBIT_RHYTHM"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 960, height: 540)
        let moments: [(String, Double)] = [
            ("留白 / 0.967 s", 29.0 / 30),
            ("起音 ① / 1.100 s", 1.1),
            ("起音之前 / 2.967 s", 89.0 / 30),
            ("起音 ② / 3.100 s", 3.1),
            ("起音之前 / 4.967 s", 149.0 / 30),
            ("起音 ③ / 5.067 s", 152.0 / 30),
            ("组合节奏 / 7.067 s", 212.0 / 30),
            ("组合节奏 / 7.567 s", 227.0 / 30),
            ("节奏间隙 / 12.733 s", 382.0 / 30),
            ("密集加重 / 14.533 s", 436.0 / 30),
            ("收尾留白 / 15.767 s", 473.0 / 30)
        ]
        var clock = ParticleFieldMotionClock()
        var captures: [(String, CGImage)] = []
        var nextMoment = 0
        var responseRows: [String] = ["time,phase,bass,mid,treble,orbit_energy_x,orbit_energy_y,orbit_energy_z,orbit_pulse_x,orbit_pulse_y,orbit_pulse_z"]
        // Advance every frame so stills include the same envelope history as the movie.
        for index in 0..<Int(OrbitRhythmFixture.duration * 30) {
            let time = Double(index) / 30
            let levels = OrbitRhythmFixture.levels(at: time)
            let frame = clock.frame(at: time, animated: true, levels: levels)
            responseRows.append(String(format: "%.6f,%@,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f", time,
                OrbitRhythmFixture.phase(at: time), levels.bass, levels.mid, levels.treble,
                frame.orbitRhythm.energy.x, frame.orbitRhythm.energy.y, frame.orbitRhythm.energy.z,
                frame.orbitRhythm.pulse.x, frame.orbitRhythm.pulse.y, frame.orbitRhythm.pulse.z))
            if nextMoment < moments.count, time + 0.00001 >= moments[nextMoment].1 {
                let image = try ParticleFieldOffscreen.image(mode: .spectrumRing, time: Double(frame.time),
                    audio: frame.audio, orbitRhythm: frame.orbitRhythm, size: size, seed: 0xA17ACA, glow: true, lowPower: false)
                try TemporalDesignExport.png(image, to: directory.appending(path: "orbit-rhythm-case-\(nextMoment).png"))
                captures.append((moments[nextMoment].0, image))
                nextMoment += 1
            }
        }
        try TemporalDesignExport.contactSheet(captures, columns: 2,
            to: directory.appending(path: "orbit-rhythm-contact-sheet.png"))
        try TemporalDesignExport.contactSheet(Array(captures.prefix(6)), columns: 2,
            to: directory.appending(path: "orbit-onset-pairs.png"))
        try Data(responseRows.joined(separator: "\n").utf8).write(
            to: directory.appending(path: "actual-analysis.csv"), options: .atomic)
        try OrbitRhythmFixture.writePCM(to: directory.appending(path: "original-rhythm.wav"))
        var movieClock = ParticleFieldMotionClock()
        try await TemporalDesignExport.movie(to: directory.appending(path: "orbit-rhythm-silent.mp4"),
                                            duration: OrbitRhythmFixture.duration) { time in
            let frame = movieClock.frame(at: time, animated: true, levels: OrbitRhythmFixture.levels(at: time))
            let image = try ParticleFieldOffscreen.image(mode: .spectrumRing, time: Double(frame.time),
                audio: frame.audio, orbitRhythm: frame.orbitRhythm, size: size, seed: 0xA17ACA, glow: true, lowPower: false)
            return try TemporalDesignExport.labelled(image,
                text: "原创合成节奏 / \(OrbitRhythmFixture.phase(at: time)) / \(String(format: "%.2f", time))s", size: size)
        }
        let readme = """
        Original synthetic rhythm study: 16 seconds, 44.1 kHz, mono. No real music or account was accessed.
        Production AudioBandAnalysis receives 8,192 consecutive PCM samples each frame.
        Every signed band trace and per-band level comes from that production DSP, with no invented beat markers.
        Stills and movie advance ParticleFieldMotionClock at 30 fps and pass its orbitRhythm to production Metal.
        0–1 s: silence. 1 s / 1.5 s: isolated 80 + 160 Hz kick attacks.
        3 s / 3.5 s: isolated 880 + 1,350 + 2,150 Hz percussive attacks.
        5–5.75 s: isolated 7,400 + 10,400 + 13,700 Hz eighth-note attacks.
        7–12 s: 120 BPM mixed groove, quarter kicks / backbeats / eighth hats.
        12–13 s: rest. 13–15 s: denser sixteenth-note fill with rising actual PCM gain. 15–16 s: ending silence.
        Production scenes contain no low / mid / high annotations. Contact-sheet captions identify review moments only.
        original-rhythm.wav is exactly the original PCM input. The silent MP4 may be muxed with that WAV for audible review.
        Export is visual evidence, not proof of Apple Music audio capture, native frame rate, or user aesthetic approval.
        """
        try Data(readme.utf8).write(to: directory.appending(path: "README.txt"), options: .atomic)
        print("Orbital rhythm evidence: \(directory.path(percentEncoded: false))")
    }
}
