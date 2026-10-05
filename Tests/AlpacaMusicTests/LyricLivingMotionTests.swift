import Foundation
import Testing
@testable import AlpacaMusic

@Test @MainActor func livingWordsArriveIndividuallyAndSettleIntoReadingRows() throws {
    let line = LyricLine(id: 0, text: "Keep a little light beside the window", start: 0, end: 7)
    let size = CGSize(width: 1000, height: 600)
    let arriving = LyricTypography.layout(line: line, index: LyricScene.editorial.rawValue, in: size, position: 0.24, reduceMotion: false)
    let resting = LyricTypography.layout(line: line, index: LyricScene.editorial.rawValue, in: size, position: 7, reduceMotion: false)
    let lexical = arriving.filter { !$0.text.allSatisfy(\.isWhitespace) }
    let movingPair = lexical.indices.dropLast().first { index in
        let next = index + 1
        return lexical[index].group == lexical[next].group
            && abs(lexical[index].rotation - lexical[next].rotation) > 0.01
    }
    #expect(movingPair != nil)
    #expect(resting.allSatisfy { $0.accent == nil })
    #expect(arriving.map(\.text).joined() == line.text)
    #expect(resting.map(\.text).joined() == line.text)
    for index in resting.indices.dropLast() where resting[index].group == resting[index + 1].group {
        #expect(abs(resting[index].rotation - resting[index + 1].rotation) < 0.001)
    }
    let reduced = LyricTypography.layout(line: line, index: LyricScene.editorial.rawValue, in: size, position: 0.24, reduceMotion: true)
    #expect(reduced.allSatisfy { $0.accent == nil && $0.opacity == 1 && $0.timedStart == nil })
}

@Test @MainActor func livingGestureTrajectoryKeepsGlyphsAndStrokesOnStage() {
    let lines = [LyricLine(id: 0, text: "让每一次停顿，都有呼吸的空间", start: 0, end: 6),
                 LyricLine(id: 0, text: "Keep a little light beside the window", start: 0, end: 6)]
    let audio = VisualizationAudio(AudioLevels(energy: 1, beat: 1, available: true, bass: 1, treble: 1))
    var sawAxisGesture = false
    for line in lines {
        for size in [CGSize(width: 300, height: 240), CGSize(width: 1000, height: 600)] {
            for scene in LyricScene.allCases {
                for tick in 0...144 {
                    let pieces = LyricTypography.layout(line: line, index: scene.rawValue, in: size, position: Double(tick) / 24, reduceMotion: false, audio: audio)
                    #expect(pieces.map(\.text).joined() == line.text)
                    for piece in pieces {
                        var envelope = piece.bounds
                        if let accent = piece.accent {
                            sawAxisGesture = sawAxisGesture || abs(accent.scaleX - accent.scaleY) > 0.01
                            envelope = envelope.union(LyricAccentRenderer.maximumWorldBounds(for: piece))
                        }
                        #expect(envelope.minX >= -0.5 && envelope.maxX <= size.width + 0.5)
                        #expect(envelope.minY >= -0.5 && envelope.maxY <= size.height + 0.5)
                    }
                }
            }
        }
    }
    #expect(sawAxisGesture)
}

@Test @MainActor func livingFocalWordsDoNotTouchNeighborsDuringRecovery() {
    let line = LyricLine(id: 0, text: "A softer morning waits beside the quiet river", start: 0, end: 7)
    for tick in 0...168 {
        let pieces = LyricTypography.layout(line: line, index: LyricScene.editorial.rawValue,
                                            in: CGSize(width: 1000, height: 600), position: Double(tick) / 24, reduceMotion: false)
        for first in pieces.indices {
            for second in pieces.indices where second > first {
                #expect(!pieces[first].bounds.intersects(pieces[second].bounds))
            }
        }
    }
}
