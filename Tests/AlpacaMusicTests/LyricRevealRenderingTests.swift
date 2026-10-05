import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import AlpacaMusic

/// Original review text, not lyrics copied from a song or a user's library.
private enum LyricRevealRenderFixture {
    static let chinese = LyricLine(id: 0, text: "让此刻慢慢靠近", start: 0, end: 6,
        words: [.init(id: 0, text: "让", start: 0, end: 0.7),
                .init(id: 1, text: "此刻", start: 0.7, end: 2.3),
                .init(id: 2, text: "慢慢", start: 2.3, end: 4.2),
                .init(id: 3, text: "靠近", start: 4.2, end: 6)])
    static let english = LyricLine(id: 0, text: "We leave a little light beside the rain", start: 0, end: 6)
    static let spanish = LyricLine(id: 0, text: "La música ilumina mi corazón", start: 0, end: 6)
    static let size = CGSize(width: 560, height: 315)

    @MainActor static func reading(_ line: LyricLine, position: Double,
                                   appearance: LyricProgressText.Appearance = .reveal) throws -> CGImage {
        try TemporalDesignExport.image(
            LyricProgressText(line: line, text: line.text, position: position,
                              appearance: appearance, reduceMotion: true)
                .font(.system(size: 30, weight: .medium))
                .lineSpacing(10).frame(width: 280, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(30).appTheme(.listeningRoom), size: size)
    }

    static func inkMask(_ pixels: [UInt8]) -> [Bool] {
        stride(from: 0, to: pixels.count, by: 4).map { index in
            max(pixels[index], pixels[index + 1], pixels[index + 2]) > 16
        }
    }
}

/// This checks actual SwiftUI text ink, not a duplicate of the timing formula.
/// Complete text owns the layout, so partial text must occupy the same pixels
/// when the line wraps. It does not assert a font-specific screenshot golden.
@Test @MainActor func progressiveReadingInkKeepsItsLayoutAndReconstructsAfterSeeking() throws {
    for line in [LyricRevealRenderFixture.chinese, LyricRevealRenderFixture.english, LyricRevealRenderFixture.spanish] {
        let before = try TemporalDesignExport.rgba(LyricRevealRenderFixture.reading(line, position: -0.1))
        let early = try TemporalDesignExport.rgba(LyricRevealRenderFixture.reading(line, position: 0.65))
        let middle = try TemporalDesignExport.rgba(LyricRevealRenderFixture.reading(line, position: 2.8))
        let complete = try TemporalDesignExport.rgba(LyricRevealRenderFixture.reading(line, position: 7))
        let revisited = try TemporalDesignExport.rgba(LyricRevealRenderFixture.reading(line, position: 2.8))
        let beforeMask = LyricRevealRenderFixture.inkMask(before)
        let earlyMask = LyricRevealRenderFixture.inkMask(early)
        let completeMask = LyricRevealRenderFixture.inkMask(complete)
        #expect(!beforeMask.contains(true))
        #expect(earlyMask.contains(true))
        #expect(earlyMask.filter { $0 }.count < completeMask.filter { $0 }.count)
        #expect(middle == revisited, "Frozen time and a backward seek must reconstruct the same static ink.")
        #expect(zip(earlyMask, completeMask).allSatisfy { !$0.0 || $0.1 },
                "Revealing later letters must not move the already visible letters or change wrapping.")
        let readingAhead = try TemporalDesignExport.rgba(
            LyricRevealRenderFixture.reading(line, position: -0.1, appearance: .highlight))
        #expect(LyricRevealRenderFixture.inkMask(readingAhead).contains(true),
                "The scroll reading style keeps upcoming words dim but readable.")
    }
}

/// Opt-in visual review samples the real row and kinetic Canvas at equal sizes.
/// No user account, audio device, music file, library, or native window is used.
@Test @MainActor func exportProgressiveLyricReadingAndKineticEvidence() throws {
    guard let path = ProcessInfo.processInfo.environment["ALPACA_LYRIC_REVEAL_EXPORT"], !path.isEmpty else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixtures: [(name: String, line: LyricLine, timing: LyricTiming)] = [
        ("Chinese supplied words", LyricRevealRenderFixture.chinese, .word),
        ("English line estimate", LyricRevealRenderFixture.english, .line),
        ("Spanish line estimate", LyricRevealRenderFixture.spanish, .line)
    ]
    let positions = [0.45, 2.8, 5.65]
    var captures: [(String, CGImage)] = []
    for (sample, position) in positions.enumerated() {
        for (fixture, item) in fixtures.enumerated() {
            let document = LyricDocument(lines: [item.line], timing: item.timing, sourceDescription: "Original review fixture")
            let scroll = LyricRowView(line: item.line, active: true, plain: false,
                                     width: LyricRevealRenderFixture.size.width, reduceMotion: true,
                                     position: position, isPlaying: false, onSeek: { _ in })
                .padding(.horizontal, 34)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .appTheme(.listeningRoom)
            let rowImage = try TemporalDesignExport.image(scroll, size: LyricRevealRenderFixture.size)
            let kineticImage = try TemporalDesignExport.image(
                KineticLyricFrameView(document: document, position: position).appTheme(.listeningRoom), size: LyricRevealRenderFixture.size)
            let prefix = "fixture-\(fixture)-sample-\(sample)"
            try TemporalDesignExport.png(rowImage, to: directory.appendingPathComponent(prefix + "-scroll.png"))
            try TemporalDesignExport.png(kineticImage, to: directory.appendingPathComponent(prefix + "-kinetic.png"))
            captures.append(("\(item.name) / scroll / \(position)s", rowImage))
            captures.append(("\(item.name) / kinetic / \(position)s", kineticImage))
        }
    }
    try TemporalDesignExport.contactSheet(captures, columns: 6,
        to: directory.appendingPathComponent("progressive-lyrics-contact-sheet.png"))

    // The live long-line path embeds this same production component in a native
    // ScrollView. Capturing the component does not claim to test that scrolling.
    let longText = "我们沿着缓缓展开的地平线走向远处仍然亮着灯的一扇小小窗户，给尚未抵达的清晨留下一点温柔的光。"
    let longLine = LyricLine(id: 0, text: longText, start: 0, end: 18)
    var longCaptures: [(String, CGImage)] = []
    for position in [1.0, 8.0, 17.0] {
        let image = try TemporalDesignExport.image(
            LyricProgressText(line: longLine,
                              text: LyricTypography.readingText(longText, width: 480, fontSize: 28),
                              position: position, appearance: .reveal, reduceMotion: true)
                .font(.system(size: 28, weight: .medium)).lineSpacing(12)
                .frame(width: 480, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(40).appTheme(.listeningRoom),
            size: CGSize(width: 560, height: 420))
        try TemporalDesignExport.png(image, to: directory.appendingPathComponent("long-reading-\(Int(position)).png"))
        longCaptures.append(("Long reading component / \(position)s", image))
    }
    try TemporalDesignExport.contactSheet(longCaptures, columns: 3,
        to: directory.appendingPathComponent("long-reading-component-contact-sheet.png"))
    let notes = """
    Progressive lyric reveal: static production-renderer evidence.
    Each main cell uses the same 560 x 315 viewport; samples are 0.45, 2.8, and 5.65 seconds of a 6-second original cue.
    Columns: Chinese scroll row / kinetic frame, English scroll row / kinetic frame, Spanish scroll row / kinetic frame.
    Chinese fixture supplies word times. Character subdivision inside multi-character words is estimated within each supplied word interval.
    English and Spanish fixtures only supply line intervals, so word onsets are estimates, not measured vocal alignment or beat analysis.
    Scroll rows retain unsung text dimly for reading and progressively highlight whole alphabetic words or CJK characters.
    Kinetic text hides future words or CJK characters, retains the full layout, and applies the existing stage movement and local accents.
    The long-reading captures use the exact shared production text component, including production line wrapping, without a native ScrollView.
    Reduced motion is enabled on reading rows/components; kinetic cells keep their production motion pose at each sampled time.
    No audio or synthetic beat envelope is supplied. These images do not prove native scrolling, live pause/seek behavior, audio synchronization, frame rate, or aesthetic approval.
    The default rendering regression separately verifies future reading-reveal ink is absent, visible ink keeps its eventual positions, and revisiting a time reconstructs identical pixels.
    """
    try Data(notes.utf8).write(to: directory.appendingPathComponent("README.txt"), options: .atomic)
}
