import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import AlpacaMusic

@Test @MainActor func lyricCompositionsContainChineseLatinAndEmojiAtEveryEntrancePhase() {
    let texts = ["把夜色折成一封信", "There is room for every quiet beginning beside the river", "我们沿着缓缓展开的地平线走向远处仍然亮着灯的一扇小小窗户", "Supercalifragilisticexpialidocious", "🌙 Night / 夜色 ✨ continues"]
    let sizes = [CGSize(width: 430, height: 500), CGSize(width: 1000, height: 600), CGSize(width: 300, height: 240)]
    for text in texts {
        for size in sizes {
            for scene in LyricScene.allCases {
                let line = LyricLine(id: 0, text: text, start: 2, end: 9)
                for time in [2.0, 2.1, 2.3, 2.65, 5.0, 8.8] {
                    let pieces = LyricTypography.layout(line: line, index: scene.rawValue, in: size, position: time, reduceMotion: false)
                    #expect(!pieces.isEmpty)
                    for piece in pieces {
                        #expect(piece.bounds.minX >= -0.5 && piece.bounds.maxX <= size.width + 0.5)
                        #expect(piece.bounds.minY >= -0.5 && piece.bounds.maxY <= size.height + 0.5)
                        #expect(piece.fontSize > 0 && piece.fontSize.isFinite)
                        #expect(piece.opacity.isFinite && (0...1).contains(piece.opacity))
                    }
                    #expect(pieces.map(\.text).joined().filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })
                }
            }
        }
    }
}

@Test @MainActor func lyricSeekReconstructsExactlyTheSameFrame() {
    let line = LyricsQAFixture.document.lines[4]
    let frame = LyricTypography.layout(line: line, index: 4, in: CGSize(width: 800, height: 500), position: 30.3, reduceMotion: false)
    _ = LyricTypography.layout(line: line, index: 4, in: CGSize(width: 800, height: 500), position: 35, reduceMotion: false)
    let revisited = LyricTypography.layout(line: line, index: 4, in: CGSize(width: 800, height: 500), position: 30.3, reduceMotion: false)
    #expect(frame.map(\.center) == revisited.map(\.center))
    #expect(frame.map(\.opacity) == revisited.map(\.opacity))
    #expect(frame.map(\.fontSize) == revisited.map(\.fontSize))
    #expect(frame.map(\.timedStart) == line.words.map { Optional($0.start) })
}

@Test @MainActor func reducedMotionKeepsTypographyStationaryAndFullyLegible() {
    for scene in LyricScene.allCases {
        let line = LyricLine(id: 0, text: "Every quiet beginning has a place", start: 2, end: 9)
        let first = LyricTypography.layout(line: line, index: scene.rawValue, in: CGSize(width: 900, height: 540), position: 2, reduceMotion: true)
        let last = LyricTypography.layout(line: line, index: scene.rawValue, in: CGSize(width: 900, height: 540), position: 8.95, reduceMotion: true)
        #expect(first.map(\.center) == last.map(\.center))
        #expect(first.allSatisfy { $0.opacity == 1 && $0.scale == 1 })
        #expect(last.allSatisfy { $0.opacity == 1 && $0.scale == 1 })
        #expect(first.allSatisfy { $0.timedStart == nil && $0.timedEnd == nil })
    }
}

@Test @MainActor func timestampedWordsAreNeverCreatedFromOrdinaryLineTiming() {
    let line = LyricLine(id: 0, text: "让文字安静地留在这里", start: 2, end: 8)
    let pieces = LyricTypography.layout(line: line, index: 4, in: CGSize(width: 800, height: 500), position: 3, reduceMotion: false)
    #expect(pieces.allSatisfy { $0.timedStart == nil && $0.timedEnd == nil })
    #expect(LyricsQAFixture.document.activeIndex(at: 0) == nil)
    #expect(LyricsQAFixture.document.activeIndex(at: 39) == nil)
}

/// Opt-in, isolated visual artifacts. No windows, audio, credentials, or user
/// library are opened. Set ALPACA_LYRIC_QA_OUTPUT to a temporary output folder.
@Test @MainActor func lyricQAExportScreenshots() throws {
    guard let output = ProcessInfo.processInfo.environment["ALPACA_LYRIC_QA_OUTPUT"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for mode in [LyricPresentationMode.kinetic] {
        for index in LyricsQAFixture.document.lines.indices {
            let line = LyricsQAFixture.document.lines[index]
            let time = (line.start ?? 0) + 1.2
            let width: CGFloat = mode == .scroll ? 430 : 1000
            let view = LyricsQAPreview(mode: mode, position: time, isPlaying: false, reduceMotion: false)
                .frame(width: width, height: 600).background(AppPalette.listeningRoom.background).appTheme(.listeningRoom)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: width, height: 600)
            renderer.scale = 2
            let rendered = try #require(renderer.nsImage)
            let data = try #require(rendered.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(mode.rawValue)-\(index).png"))
        }
    }
    // ImageRenderer cannot instantiate the native lazy scroll viewport. Render
    // the exact production row component separately and label that evidence.
    let selected = 1
    let style = VStack(alignment: .leading, spacing: 25) {
        ForEach(Array(LyricsQAFixture.document.lines.prefix(3))) { line in
            LyricRowView(line: line, active: line.id == selected, plain: false, width: 430, reduceMotion: true, onSeek: { _ in })
        }
    }.padding(.horizontal, 28).frame(width: 430, height: 600).background(AppPalette.listeningRoom.background).appTheme(.listeningRoom)
    let styleRenderer = ImageRenderer(content: style)
    styleRenderer.proposedSize = ProposedViewSize(width: 430, height: 600); styleRenderer.scale = 2
    let styleImage = try #require(styleRenderer.nsImage)
    let styleData = try #require(styleImage.tiffRepresentation)
    let styleBitmap = try #require(NSBitmapImageRep(data: styleData))
    let stylePNG = try #require(styleBitmap.representation(using: .png, properties: [:]))
    try stylePNG.write(to: directory.appendingPathComponent("scroll-row-style.png"))
}

@Test @MainActor func lyricEditorialRowsLeaveSpaceForEnlargedFirstLine() {
    let line = LyricLine(id: 0, text: "A softer morning waits beside the quiet river", start: 2, end: 9)
    for size in [CGSize(width: 430, height: 500), CGSize(width: 1000, height: 600)] {
        let pieces = LyricTypography.layout(line: line, index: LyricScene.editorial.rawValue, in: size, position: 4, reduceMotion: false)
        for first in pieces.indices {
            for second in pieces.indices where second > first {
                #expect(!pieces[first].bounds.intersects(pieces[second].bounds))
            }
        }
    }
}

@Test func lyricScrollAnchorStaysNearCurrentTimeDuringSRTGapsAndBackwardSeeks() {
    let document = LyricsQAFixture.document
    #expect(LyricsScrollAnchor.id(document: document, position: 0) == 0)
    #expect(LyricsScrollAnchor.id(document: document, position: 36) == 4)
    #expect(document.activeIndex(at: 39) == nil)
    #expect(LyricsScrollAnchor.id(document: document, position: 39) == 4)
    #expect(LyricsScrollAnchor.id(document: document, position: 42) == 5)
    #expect(LyricsScrollAnchor.id(document: document, position: 12) == 1)
}

@Test @MainActor func lyricChineseWrappingRetainsNaturalWordsAndAllCharacters() {
    let text = "把夜色折成一封信"
    let rows = LyricTypography.phrases(text, targetCount: 3)
    #expect(rows.joined() == text)
    #expect(rows.allSatisfy { !$0.hasSuffix("折") && !$0.hasPrefix("成") })
    for text in ["风经过空白的页", "让此刻慢慢靠近", "🌙✨夜色，轻轻地落在窗前。"] {
        #expect(LyricTypography.phrases(text, targetCount: 3).joined() == text)
    }
}

@Test @MainActor func lyricChinesePunctuationStaysWithItsPrecedingPhrase() {
    let closingPunctuation: Set<Character> = Set("，。！？；：、）》」』】〉〕］｝’”.,!?;:%％…")
    for text in ["让每一次停顿，都有呼吸的空间", "向前走。把风留在身后！", "听见回声，看见远方，停留片刻。", "把这一句「轻轻的话」，留给明天。"] {
        let phrases = LyricTypography.phrases(text, targetCount: 3)
        #expect(phrases.joined() == text)
        for phrase in phrases.dropFirst() {
            #expect(phrase.first.map { !closingPunctuation.contains($0) } ?? true)
        }
    }
}

@Test @MainActor func lyricDirectorCombinesIndependentCompositionsAndMotionDeterministically() {
    var compositions = Set<Int>(), motions = Set<Int>(), decorations = Set<Int>(), combinations = Set<String>()
    for index in 0..<40 {
        let line = LyricLine(id: index, text: "给每一阵经过窗边的风留一点空间 \(index)", start: 2, end: 9)
        let first = LyricTypography.director(line: line, index: index)
        let again = LyricTypography.director(line: line, index: index)
        #expect(first == again)
        compositions.insert(first.scene.rawValue); motions.insert(first.motion.rawValue); decorations.insert(first.decoration.rawValue)
        combinations.insert("\(first.scene.rawValue)/\(first.motion.rawValue)/\(first.decoration.rawValue)")
    }
    #expect(compositions.count >= 4)
    #expect(motions.count >= 2)
    #expect(decorations.count >= 3)
    #expect(combinations.count >= 10)
    // Different text is allowed to keep the same scene but should not be bound
    // to an eight-line counter independent of the actual cue.
    let samples = (0..<20).map { index in
        LyricTypography.director(line: .init(id: index, text: "A different quiet beginning \(index)", start: 0, end: 8.5), index: index)
    }
    #expect(samples.enumerated().contains { $0.element.scene != LyricTypography.scene(for: $0.offset) })
}

@Test @MainActor func lyricDirectorUsesCueDurationAndReadingPressure() {
    let text = "让每一次停顿都留有呼吸的空间"
    let fast = LyricTypography.director(line: .init(id: 0, text: text, start: 2, end: 3.8), index: 0)
    let slow = LyricTypography.director(line: .init(id: 0, text: text, start: 2, end: 14), index: 0)
    #expect([LyricMotionProfile.brisk, .gather].contains(fast.motion))
    #expect([LyricMotionProfile.breathe, .drift].contains(slow.motion))
    #expect(fast.motion != slow.motion)
    #expect([LyricScene.steps, .diagonal, .editorial, .monument].contains(fast.scene))
    #expect([LyricScene.hush, .orbit, .constellation, .echo, .monument].contains(slow.scene))
}

@Test @MainActor func lyricArrivalRemainsCompleteAndHasAReadableSettledPose() {
    let line = LyricLine(id: 0, text: "把每一个安静的念头留在风中", start: 2, end: 11)
    let size = CGSize(width: 1000, height: 600)
    let entrance = LyricTypography.layout(line: line, index: LyricScene.editorial.rawValue, in: size, position: 2, reduceMotion: false)
    let settled = LyricTypography.layout(line: line, index: LyricScene.editorial.rawValue, in: size, position: 3.5, reduceMotion: false)
    #expect(entrance.map(\.text).joined() == line.text)
    #expect(entrance.allSatisfy { $0.opacity >= 0.72 })
    #expect(settled.allSatisfy { $0.opacity == 1 })
    #expect(Set(settled.map(\.group)).count > 1)
    #expect(entrance.map(\.center) != settled.map(\.center))
    #expect(entrance.allSatisfy { $0.timedStart == nil && $0.timedEnd == nil })
}

@Test @MainActor func lyricPrimaryTrajectoryContainsTheMaximumAudioAccent() {
    var loud = VisualizationAudio()
    loud.available = true; loud.energy = 1; loud.beat = 1; loud.bass = 1; loud.treble = 1
    let texts = ["把夜色折成一封信", "There is room for every quiet beginning beside the river", "🌙 Night / 夜色 ✨ continues"]
    for text in texts {
        for size in [CGSize(width: 300, height: 240), CGSize(width: 430, height: 500), CGSize(width: 1000, height: 600)] {
            for duration in [0.7, 2.3, 9.5] {
                let line = LyricLine(id: 0, text: text, start: 2, end: 2 + duration)
                for scene in LyricScene.allCases {
                    for step in 0...12 {
                        let pieces = LyricTypography.layout(line: line, index: scene.rawValue, in: size,
                                                           position: 2 + duration * Double(step) / 12, reduceMotion: false, audio: loud)
                        for piece in pieces {
                            #expect(piece.bounds.minX >= -0.5 && piece.bounds.maxX <= size.width + 0.5)
                            #expect(piece.bounds.minY >= -0.5 && piece.bounds.maxY <= size.height + 0.5)
                            #expect(piece.fontSize.isFinite && piece.opacity.isFinite)
                        }
                    }
                }
            }
        }
    }
}

@Test @MainActor func lyricAudioAccentsRequireRealInputAndDoNotChangeTheDirector() {
    let line = LyricsQAFixture.document.lines[2]
    let size = CGSize(width: 900, height: 540)
    let quiet = LyricTypography.layout(line: line, index: 2, in: size, position: 18, reduceMotion: false)
    var unavailable = VisualizationAudio()
    unavailable.energy = 1; unavailable.beat = 1; unavailable.bass = 1; unavailable.treble = 1
    let ignored = LyricTypography.layout(line: line, index: 2, in: size, position: 18, reduceMotion: false, audio: unavailable)
    #expect(quiet.map(\.center) == ignored.map(\.center))
    #expect(quiet.map(\.fontSize) == ignored.map(\.fontSize))
    unavailable.available = true
    let reactive = LyricTypography.layout(line: line, index: 2, in: size, position: 18, reduceMotion: false, audio: unavailable)
    #expect(reactive.map(\.text) == quiet.map(\.text))
    #expect(reactive.map(\.center) != quiet.map(\.center))
    for (first, last) in zip(quiet, reactive) {
        #expect(last.fontSize / first.fontSize <= 1.037)
        #expect(abs(last.center.x - first.center.x) <= 12)
        #expect(abs(last.center.y - first.center.y) <= 12)
    }
    let reduced = LyricTypography.layout(line: line, index: 2, in: size, position: 18, reduceMotion: true, audio: unavailable)
    let reducedQuiet = LyricTypography.layout(line: line, index: 2, in: size, position: 18, reduceMotion: true)
    #expect(reduced.map(\.center) == reducedQuiet.map(\.center))
    #expect(reduced.map(\.fontSize) == reducedQuiet.map(\.fontSize))
}

@Test @MainActor func lyricDecorativeLayersAreBoundedSeparateAndNeverAnnouncedAsSungWords() {
    let size = CGSize(width: 1000, height: 600)
    var foundOutline = false, foundEcho = false
    for index in 0..<24 {
        let text = "Fold the quiet night into a letter \(index)"
        let line = LyricLine(id: 0, text: text, start: 2, end: 10)
        let document = LyricDocument(lines: [line], timing: .line, sourceDescription: "原创排版测试")
        let frame = LyricTypography.frame(document: document, position: 4, in: size, reduceMotion: false)
        let primary = frame.fragments.filter { $0.role == .primary }
        let decorative = frame.fragments.filter { $0.role == .echo }
        #expect(!primary.isEmpty)
        #expect(decorative.count <= primary.count * 2)
        #expect(decorative.allSatisfy { $0.opacity <= 0.19 && $0.timedStart == nil && $0.timedEnd == nil })
        #expect(Set(frame.fragments.map(\.id)).count == frame.fragments.count)
        foundOutline = foundOutline || decorative.contains { $0.ink == .outline }
        foundEcho = foundEcho || decorative.contains { $0.ink == .solid }
        let reduced = LyricTypography.frame(document: document, position: 4, in: size, reduceMotion: true)
        #expect(reduced.fragments.allSatisfy { $0.role == .primary && $0.ink == .solid && $0.opacity == 1 })
        #expect(primary.map(\.text).joined().filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })
    }
    #expect(foundOutline && foundEcho)
}

@Test @MainActor func lyricMismatchedWordMetadataPreservesTheActualSentence() {
    let line = LyricLine(id: 0, text: "The actual complete sentence", start: 2, end: 8,
                         words: [.init(id: 0, text: "unrelated", start: 2, end: 3)])
    let pieces = LyricTypography.layout(line: line, index: 4, in: CGSize(width: 800, height: 500), position: 3, reduceMotion: false)
    #expect(pieces.map(\.text).joined().filter { !$0.isWhitespace } == line.text.filter { !$0.isWhitespace })
    #expect(pieces.allSatisfy { $0.timedStart == nil && $0.timedEnd == nil })
}

@Test @MainActor func lyricLongPhrasesUseSeparateReadableRowsAcrossAllMotionAndAudioPhases() {
    let text = "我们沿着缓缓展开的地平线，走向远处仍然亮着灯的一扇小小窗户"
    let line = LyricLine(id: 0, text: text, start: 2, end: 10)
    let loud = VisualizationAudio(AudioLevels(energy: 1, beat: 1, available: true, bass: 1, treble: 1))
    for size in [CGSize(width: 1000, height: 600), CGSize(width: 430, height: 500), CGSize(width: 620, height: 320)] {
        for scene in LyricScene.allCases {
            for time in [2.0, 2.08, 2.2, 2.7, 5.0, 9.99] {
                let pieces = LyricTypography.layout(line: line, index: scene.rawValue, in: size, position: time, reduceMotion: false, audio: loud)
                #expect(Set(pieces.map(\.group)).count >= 4)
                #expect(pieces.map(\.text).joined() == text)
                for piece in pieces {
                    #expect(piece.bounds.minX >= -0.5 && piece.bounds.maxX <= size.width + 0.5)
                    #expect(piece.bounds.minY >= -0.5 && piece.bounds.maxY <= size.height + 0.5)
                }
                for first in pieces.indices {
                    for second in pieces.indices where second > first && pieces[first].group != pieces[second].group {
                        #expect(!pieces[first].bounds.intersects(pieces[second].bounds))
                    }
                }
            }
        }
    }
}

@Test @MainActor func lyricAdditionalRowsKeepOriginalTimedWordsAndCueTiming() {
    let texts = ["我们", "沿着", "缓缓展开", "的地平线，", "走向", "远处", "仍然亮着灯", "的一扇", "小小窗户"]
    let words = texts.enumerated().map { index, text in
        LyricWord(id: index, text: text, start: 2 + Double(index) * 0.8, end: 2.8 + Double(index) * 0.8)
    }
    let line = LyricLine(id: 7, text: texts.joined(), start: 2, end: 10, words: words)
    let pieces = LyricTypography.layout(line: line, index: 0, in: CGSize(width: 430, height: 500), position: 5, reduceMotion: false)
    #expect(Set(pieces.map(\.group)).count >= 4)
    #expect(pieces.map(\.text) == texts)
    #expect(pieces.map(\.timedStart) == words.map { Optional($0.start) })
    #expect(pieces.map(\.timedEnd) == words.map(\.end))
    #expect(pieces.allSatisfy { $0.lineID == line.id })
    #expect(line.start == 2 && line.end == 10)
}

@Test @MainActor func lyricThreePhrasesDoNotShareAnchorsInFormerTwoGroupCompositions() {
    let line = LyricLine(id: 0, text: "We keep a light, near the window, for every morning.", start: 2, end: 10)
    let loud = VisualizationAudio(AudioLevels(energy: 1, beat: 1, available: true, bass: 1, treble: 1))
    for scene in [LyricScene.monument, .hush, .echo] {
        for size in [CGSize(width: 1000, height: 600), CGSize(width: 430, height: 500)] {
            for time in [2.0, 2.08, 2.2, 2.7, 5.0, 9.99] {
                let pieces = LyricTypography.layout(line: line, index: scene.rawValue, in: size, position: time, reduceMotion: false, audio: loud)
                #expect(Set(pieces.map(\.group)).count == 3)
                #expect(pieces.map(\.text).joined() == line.text)
                for first in pieces.indices {
                    for second in pieces.indices where second > first && pieces[first].group != pieces[second].group {
                        #expect(!pieces[first].bounds.intersects(pieces[second].bounds))
                    }
                }
            }
        }
    }
}

@Test @MainActor func lyricReadingWrapsWithoutChangingAccessibleCueContent() {
    let text = "我们沿着缓缓展开的地平线，走向远处仍然亮着灯的一扇小小窗户"
    let narrow = LyricTypography.readingText(text, width: 340, fontSize: 28)
    let wide = LyricTypography.readingText(text, width: 740, fontSize: 28)
    #expect(narrow.contains("\n"))
    #expect(narrow.filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })
    #expect(narrow.split(separator: "\n").count >= wide.split(separator: "\n").count)
    let suppliedNewline = "把风留在身后\n听见回声"
    #expect(LyricTypography.readingText(suppliedNewline, width: 740, fontSize: 28) == suppliedNewline)
}

/// Original long-line fixtures rendered through the production canvas.
@Test @MainActor func lyricPhraseLayoutExportScreenshots() throws {
    guard let output = ProcessInfo.processInfo.environment["ALPACA_LYRIC_PHRASE_EXPORT"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let examples = ["我们沿着缓缓展开的地平线，走向远处仍然亮着灯的一扇小小窗户", "Before the morning reaches our window, leave a little room for the quiet light"]
    for (index, text) in examples.enumerated() {
        let document = LyricDocument(lines: [.init(id: 0, text: text, start: 0, end: 8)], timing: .line, sourceDescription: "原创断句测试")
        for (width, height) in [(1000, 600), (430, 500)] {
            let view = KineticLyricFrameView(document: document, position: 2, reduceMotion: true)
                .frame(width: CGFloat(width), height: CGFloat(height)).background(Color.black)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = .init(width: CGFloat(width), height: CGFloat(height)); renderer.scale = 1
            let rendered = try #require(renderer.nsImage)
            let data = try #require(rendered.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("phrase-\(index)-\(width).png"))
        }
    }
}
