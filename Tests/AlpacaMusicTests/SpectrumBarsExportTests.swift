import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import AlpacaMusic

/// Clean captures use the production scene and its production envelope clock.
/// Review captions belong to export chrome, never to the spectrum design.
private struct SpectrumBarsExportScene: View {
    let frame: VisualizationFrame

    var body: some View {
        Canvas(opaque: true, rendersAsynchronously: false) { context, size in
            SpectrumBarsRenderer.draw(in: &context, size: size, audio: frame.audio,
                                      time: frame.time, glow: true,
                                      presentation: frame.spectrumBars)
        }
    }
}

/// This opt-in export never accesses accounts, a music library, an audio device,
/// or system capture. Its only source is the existing original PCM rhythm study.
@Suite(.serialized) @MainActor struct SpectrumBarsExportTests {
    @Test func exportSpectrumBarsRedesignEvidence() async throws {
        guard let path = ProcessInfo.processInfo.environment["ALPACA_EXPORT_SPECTRUM_BARS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let immersiveSize = CGSize(width: 960, height: 540)
        let compactSize = CGSize(width: 320, height: 180)
        let moments: [(String, Double)] = [
            ("留白 / 0.967 s", 29.0 / 30),
            ("独立起音 ① / 1.100 s", 1.1),
            ("自然回落 / 1.333 s", 40.0 / 30),
            ("起音之前 / 2.967 s", 89.0 / 30),
            ("独立起音 ② / 3.100 s", 3.1),
            ("起音之前 / 4.967 s", 149.0 / 30),
            ("独立起音 ③ / 5.067 s", 152.0 / 30),
            ("组合节奏 / 7.067 s", 212.0 / 30),
            ("组合节奏 / 7.567 s", 227.0 / 30),
            ("节奏间隙 / 12.733 s", 382.0 / 30),
            ("密集加重 / 14.533 s", 436.0 / 30),
            ("收尾留白 / 15.767 s", 473.0 / 30)
        ]
        let clock = VisualizationClock()
        let epoch = Date(timeIntervalSince1970: 0)
        var immersiveCaptures: [(String, CGImage)] = []
        var compactCaptures: [(String, CGImage)] = []
        var nextMoment = 0
        var rows = ["time,phase,input_energy,input_bass,input_mid,input_treble,smoothed_fft_max"]
        // Continuous 30 fps advancement makes the clean stills share the same
        // release / peak-retention history as the video and native scene.
        for index in 0..<Int(OrbitRhythmFixture.duration * 30) {
            let time = Double(index) / 30
            let levels = OrbitRhythmFixture.levels(at: time)
            let frame = clock.frame(at: epoch.addingTimeInterval(time), animated: true,
                                    levels: levels, playing: true, spectrumBarsActive: true)
            rows.append(String(format: "%.6f,%@,%.6f,%.6f,%.6f,%.6f,%.6f", time,
                               OrbitRhythmFixture.phase(at: time), levels.energy,
                               levels.bass, levels.mid, levels.treble,
                               frame.audio.spectrum.max() ?? 0))
            if nextMoment < moments.count, time + 0.00001 >= moments[nextMoment].1 {
                let immersive = try TemporalDesignExport.image(SpectrumBarsExportScene(frame: frame), size: immersiveSize)
                let compact = try TemporalDesignExport.image(SpectrumBarsExportScene(frame: frame), size: compactSize)
                try TemporalDesignExport.png(immersive,
                    to: directory.appending(path: "spectrum-bars-immersive-case-\(nextMoment).png"))
                try TemporalDesignExport.png(compact,
                    to: directory.appending(path: "spectrum-bars-compact-case-\(nextMoment).png"))
                immersiveCaptures.append((moments[nextMoment].0, immersive))
                compactCaptures.append((moments[nextMoment].0, compact))
                nextMoment += 1
            }
        }
        try TemporalDesignExport.contactSheet(immersiveCaptures, columns: 3,
            to: directory.appending(path: "spectrum-bars-immersive-contact-sheet.png"))
        try TemporalDesignExport.contactSheet(compactCaptures, columns: 3,
            to: directory.appending(path: "spectrum-bars-compact-contact-sheet.png"))
        try Data(rows.joined(separator: "\n").utf8).write(
            to: directory.appending(path: "actual-analysis.csv"), options: .atomic)
        try OrbitRhythmFixture.writePCM(to: directory.appending(path: "original-rhythm.wav"))
        let movieClock = VisualizationClock()
        try await TemporalDesignExport.movie(to: directory.appending(path: "spectrum-bars-silent.mp4"),
                                            duration: OrbitRhythmFixture.duration) { time in
            let frame = movieClock.frame(at: epoch.addingTimeInterval(time), animated: true,
                                         levels: OrbitRhythmFixture.levels(at: time), playing: true, spectrumBarsActive: true)
            let image = try TemporalDesignExport.image(SpectrumBarsExportScene(frame: frame), size: immersiveSize)
            return try TemporalDesignExport.labelled(image,
                text: "原创合成节奏 / \(OrbitRhythmFixture.phase(at: time)) / \(String(format: "%.2f", time))s",
                size: immersiveSize)
        }
        let readme = """
        Retro segmented LED spectrum redesign: original synthetic 16-second rhythm, 44.1 kHz, mono.
        No music, account, library, microphone, or system-audio source was accessed.
        The existing OrbitRhythmFixture supplies 8,192 consecutive PCM samples to production AudioBandAnalysis.
        Every FFT bin and scalar measurement comes from actual fixture PCM, without invented beat markers.
        Stills and movie advance the production VisualizationClock at 30 fps and pass frame.spectrumBars to production SpectrumBarsRenderer.
        Clean immersive stills are 960 x 540; compact stills are 320 x 180. Production pillars use stepped LED cells, sparse glow, and retained peak caps.
        Their scene contains no axes, numeric grid, reflections, or low / mid / high labels.
        Contact-sheet captions and the small movie caption identify synthetic review moments outside the production scene design.
        0-1 s: silence. 1 / 1.5 s: isolated percussive attacks. 3 / 3.5 s and 5-5.75 s: other isolated voices.
        7-12 s: 120 BPM mixed groove. 12-13 s: rest. 13-15 s: denser fill with rising actual gain. 15-16 s: ending silence.
        original-rhythm.wav contains the exact original PCM. spectrum-bars-silent.mp4 may be muxed with it for audible review.
        This export is visual evidence, not proof of Apple Music audio capture, native frame rate, or user aesthetic approval.
        """
        try Data(readme.utf8).write(to: directory.appending(path: "README.txt"), options: .atomic)
        print("Spectrum bars redesign evidence: \(directory.path(percentEncoded: false))")
    }
}
