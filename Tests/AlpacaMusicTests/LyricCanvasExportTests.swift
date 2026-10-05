import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AlpacaMusic

/// Opt-in visual evidence uses the production renderer and original fixture text.
/// The montage samples different cues; the beat envelope is explicitly synthetic.
@Test @MainActor func lyricCanvasExportMontage() throws {
    guard let output = ProcessInfo.processInfo.environment["ALPACA_LYRIC_CANVAS_EXPORT"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fps = 24, framesPerCue = 72
    let texts = ["把夜色折成一封信", "沿着光的边缘，慢慢靠近", "Let the quiet find its own rhythm", "向前！再向前！", "让每一次停顿，都有呼吸的空间", "You leave a little light in the room", "风经过空白的页", "我们为明天留下一点光"]
    let durations = [3.2, 8.0, 5.5, 2.2, 11.0, 6.0, 4.0, 7.0]
    for cue in texts.indices {
        let document = LyricDocument(lines: [.init(id: cue, text: texts[cue], start: 0, end: durations[cue])], timing: .line, sourceDescription: "原创排版测试")
        for frame in 0..<framesPerCue {
            let elapsed = Double(frame) / Double(fps)
            let position = elapsed / 3 * min(3, durations[cue] - 0.02)
            let pulse = exp(-((elapsed * 2).truncatingRemainder(dividingBy: 1)) * 7)
            let audio = VisualizationAudio(AudioLevels(energy: Float(0.18 + pulse * 0.42), beat: Float(pulse), available: true, bass: Float(pulse * 0.7), treble: 0.12))
            let view = KineticLyricFrameView(document: document, position: position, audio: audio)
                .frame(width: 960, height: 540).background(Color(red: 0.035, green: 0.045, blue: 0.045))
                .overlay(alignment: .topLeading) {
                    Text("ALPACA / LYRIC CANVAS  ·  原创测试文本 · 合成节奏预览")
                        .font(.system(size: 11, design: .monospaced)).tracking(1).foregroundStyle(.white.opacity(0.5)).padding(20)
                }
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: 960, height: 540)
            renderer.scale = 1
            let rendered = try #require(renderer.nsImage)
            let data = try #require(rendered.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(String(format: "frame-%04d.png", cue * framesPerCue + frame)))
        }
    }
}
