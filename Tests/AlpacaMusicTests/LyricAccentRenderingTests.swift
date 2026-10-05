import AppKit
import SwiftUI
import Testing
@testable import AlpacaMusic

@Test @MainActor func localLyricAccentsPreserveUntimedTextAndFitEveryComposition() {
    let samples = ["让每一次停顿，都有呼吸的空间", "Keep a little light beside the window", "夜色里的 quiet light，慢慢靠近 🌙"]
    let sizes = [CGSize(width: 300, height: 240), CGSize(width: 430, height: 500), CGSize(width: 1000, height: 600)]
    let audio = VisualizationAudio(AudioLevels(energy: 1, beat: 1, available: true, bass: 1, treble: 1))
    for text in samples {
        let line = LyricLine(id: 11, text: text, start: 2, end: 9)
        for size in sizes {
            for scene in LyricScene.allCases {
                for time in [2.0, 2.15, 2.4, 3, 5, 8.8] {
                    let fragments = LyricTypography.layout(line: line, index: scene.rawValue, in: size, position: time, reduceMotion: false, audio: audio)
                    #expect(fragments.map(\.text).joined() == text)
                    #expect(fragments.allSatisfy { $0.timedStart == nil && $0.timedEnd == nil })
                    #expect(fragments.filter { $0.accent != nil }.count <= 2)
                    for fragment in fragments {
                        #expect(fragment.bounds.minX >= -0.5 && fragment.bounds.maxX <= size.width + 0.5)
                        #expect(fragment.bounds.minY >= -0.5 && fragment.bounds.maxY <= size.height + 0.5)
                        if fragment.accent != nil {
                            let mark = LyricAccentRenderer.maximumWorldBounds(for: fragment)
                            #expect(mark.minX >= -0.5 && mark.maxX <= size.width + 0.5)
                            #expect(mark.minY >= -0.5 && mark.maxY <= size.height + 0.5)
                        }
                    }
                    for a in fragments.indices {
                        for b in fragments.indices where b > a && fragments[a].group != fragments[b].group {
                            #expect(!fragments[a].bounds.intersects(fragments[b].bounds))
                        }
                    }
                }
            }
        }
    }
}

@Test @MainActor func localLyricAccentsStayOnTheirOwnerAndReconstructAfterSeeking() {
    let lines = [LyricLine(id: 0, text: "Let a little light return", start: 0, end: 4),
                 LyricLine(id: 1, text: "Give every pause a quiet room", start: 4, end: 9)]
    let document = LyricDocument(lines: lines, timing: .line, sourceDescription: "Original fixture")
    let size = CGSize(width: 1000, height: 600)
    let initial = LyricTypography.frame(document: document, position: 4.2, in: size, reduceMotion: false)
    _ = LyricTypography.frame(document: document, position: 8.8, in: size, reduceMotion: false)
    let revisited = LyricTypography.frame(document: document, position: 4.2, in: size, reduceMotion: false)
    #expect(initial.fragments.map(\.accent) == revisited.fragments.map(\.accent))
    #expect(initial.fragments.map(\.center) == revisited.fragments.map(\.center))
    #expect(initial.fragments.filter { $0.role == .echo || $0.role == .outgoing }.allSatisfy { $0.accent == nil })
    let reducedA = LyricTypography.frame(document: document, position: 4.1, in: size, reduceMotion: true)
    let reducedB = LyricTypography.frame(document: document, position: 8.8, in: size, reduceMotion: true)
    #expect(reducedA.fragments.allSatisfy { $0.accent == nil && $0.opacity == 1 })
    #expect(reducedA.fragments.map(\.center) == reducedB.fragments.map(\.center))
}

@Test @MainActor func localLyricAccentsKeepSuppliedWordOrderAndTimes() {
    let words = [LyricWord(id: 7, text: "留", start: 2, end: 2.3),
                 LyricWord(id: 8, text: "一点", start: 2.3, end: 2.7),
                 LyricWord(id: 9, text: "光", start: 3.2, end: 6)]
    let line = LyricLine(id: 3, text: words.map(\.text).joined(), start: 2, end: 7, words: words)
    let fragments = LyricTypography.layout(line: line, index: 3, in: CGSize(width: 900, height: 540), position: 3.35, reduceMotion: false)
    #expect(fragments.map(\.text) == words.map(\.text))
    #expect(fragments.map(\.timedStart) == words.map { Optional($0.start) })
    #expect(fragments.map(\.timedEnd) == words.map(\.end))
    #expect(fragments.contains { $0.accent != nil })
}


@Test @MainActor func localLyricAccentsPreserveEnhancedLRCSimultaneousOnsets() throws {
    let document = try LyricsParser.parse("[00:01.00]<00:01.00>light <00:01.00>returns\n[00:04.00]next")
    let line = try #require(document.lines.first)
    #expect(line.words.count == 2)
    #expect(line.words[0].end == line.words[0].start)
    let pieces = LyricTypography.layout(line: line, index: 0, in: CGSize(width: 900, height: 540), position: 1.2, reduceMotion: false)
    #expect(pieces.map(\.text) == line.words.map(\.text))
    #expect(pieces.map(\.timedStart) == line.words.map { Optional($0.start) })
    #expect(pieces.map(\.timedEnd) == line.words.map(\.end))
}

/// Opt-in stills use original words and artificial fixture timestamps. The
/// production renderer receives these timestamps exactly; no account is read.
@Test @MainActor func localLyricAccentExportStills() throws {
    guard let output = ProcessInfo.processInfo.environment["ALPACA_LYRIC_ACCENT_EXPORT"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixtures = [
        LyricLine(id: 0, text: "留一点光，给下一次相逢", start: 0, end: 6,
                  words: [.init(id: 0, text: "留", start: 0, end: 0.3), .init(id: 1, text: "一点", start: 0.3, end: 0.6), .init(id: 2, text: "光，", start: 0.6, end: 1.1), .init(id: 3, text: "给", start: 1.7, end: 1.9), .init(id: 4, text: "下一次", start: 1.9, end: 2.5), .init(id: 5, text: "相逢", start: 2.5, end: 5.8)]),
        LyricLine(id: 1, text: "Keep the light beside the window", start: 0, end: 6),
        LyricLine(id: 2, text: "让每一次停顿，都有呼吸的空间", start: 0, end: 8)
    ]
    for (index, line) in fixtures.enumerated() {
        for width in [430, 1000] {
            let document = LyricDocument(lines: [line], timing: line.words.isEmpty ? .line : .word, sourceDescription: "原创测试文本与人工时间戳")
            let view = KineticLyricFrameView(document: document, position: index == 0 ? 0.9 : 0.4)
                .frame(width: CGFloat(width), height: 600).background(Color.black)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: CGFloat(width), height: 600)
            renderer.scale = 1
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("accent-\(index)-\(width).png"))
        }
    }
}

@Test @MainActor func localLyricAccentExportMotion() throws {
    guard let output = ProcessInfo.processInfo.environment["ALPACA_LYRIC_ACCENT_MOTION"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let originals = ["让每一次停顿，都有呼吸的空间", "Keep a little light beside the window", "把夜色折成一封信", "沿着光的边缘，慢慢靠近", "让风带走昨日的回声", "We make room for a quiet beginning", "明天的光，留在窗前", "Let the quiet find its own rhythm",
                     "把星光藏进明天的口袋", "窗外的风，经过温柔的长夜", "有一束光，正在慢慢醒来", "沿着雨后的路，走向远方", "让这一刻，留在心里", "轻轻放下昨日的行李", "夜色与灯火，在这里相遇", "等一阵风，把故事吹远",
                     "Every little moment leaves a quiet trace", "Stay beside the open door", "We carry the morning in our hands", "A silver river wanders through the night"]
    let labels = ["圈画", "方框", "短暂闪现", "字重变化", "缓慢扩张", "三角笔画"]
    var selected: [(LyricLine, String)] = []
    for kind in LyricAccentKind.allCases {
        let line = try #require(originals.map { LyricLine(id: 0, text: $0, start: 0, end: 4) }.first { line in
            let document = LyricDocument(lines: [line], timing: .line, sourceDescription: "Original fixture")
            return stride(from: 0.05, to: 4.0, by: 0.05).contains { time in
                LyricTypography.frame(document: document, position: time, in: CGSize(width: 960, height: 540), reduceMotion: false)
                    .fragments.contains { $0.role == .primary && $0.accent?.kind == kind }
            }
        })
        selected.append((line, labels[kind.rawValue] + " · 整句时间 · 词间位置估算"))
    }
    selected.append((LyricLine(id: 0, text: "留一点光，给下一次相逢", start: 0, end: 4,
                               words: [.init(id: 0, text: "留", start: 0, end: 0.2), .init(id: 1, text: "一点", start: 0.2, end: 0.5),
                                       .init(id: 2, text: "光，", start: 0.5, end: 0.9), .init(id: 3, text: "给", start: 1.4, end: 1.6),
                                       .init(id: 4, text: "下一次", start: 1.6, end: 2), .init(id: 5, text: "相逢", start: 2, end: 3.9)]),
                     "真实逐词时间 · 对应词起点触发与延长词强调"))
    let fps = 24, count = 96
    var previewIndex: [[String: String]] = []
    for (cue, sample) in selected.enumerated() {
        let document = LyricDocument(lines: [sample.0], timing: sample.0.words.isEmpty ? .line : .word, sourceDescription: "Original fixture")
        if cue < LyricAccentKind.allCases.count {
            let kind = LyricAccentKind.allCases[cue]
            let strengths = (0..<count).map { frame in
                LyricTypography.frame(document: document, position: Double(frame) / Double(fps), in: CGSize(width: 960, height: 540), reduceMotion: false)
                    .fragments.filter { $0.role == .primary && $0.accent?.kind == kind }.map { $0.accent?.intensity ?? 0 }.max() ?? 0
            }
            let peak = strengths.indices.max { strengths[$0] < strengths[$1] } ?? 0
            previewIndex.append(["label": sample.1, "text": sample.0.text, "peak_frame": String(cue * count + peak)])
        }
        for frame in 0..<count {
            let view = KineticLyricFrameView(document: document, position: Double(frame) / Double(fps))
                .frame(width: 960, height: 540).background(Color(red: 0.035, green: 0.045, blue: 0.045))
                .overlay(alignment: .topLeading) {
                    Text("ALPACA / BOLD WORD ACCENTS  ·  " + sample.1)
                        .font(.system(size: 11, design: .monospaced)).tracking(0.7).foregroundStyle(.white.opacity(0.55)).padding(20)
                }
                .overlay(alignment: .bottomLeading) {
                    Text("原创演示文本 · 人工整句 / 逐词时间戳 · 音频输入关闭")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).padding(20)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(String(format: "%.2f / 4.00 s", Double(frame) / Double(fps)))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.45)).padding(20)
                }
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: 960, height: 540); renderer.scale = 1
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(String(format: "frame-%04d.png", cue * count + frame)))
        }
    }
    try JSONSerialization.data(withJSONObject: previewIndex, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("montage.json"))
}

@Test @MainActor func completeLyricCycleExportAcrossCueChanges() throws {
    guard let output = ProcessInfo.processInfo.environment["ALPACA_LYRIC_COMPLETE_CYCLE_EXPORT"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let words = ["light", "window", "morning", "quiet", "river", "letters", "beginning", "night", "glow", "memory", "shelter", "promise", "sky", "breeze", "tomorrow", "wonder", "gentle", "silver", "回声", "星光", "远方", "月光", "温柔", "暮色", "雨后", "微光", "长夜", "晨间"]
    let kinds: [LyricAccentKind] = [.ring, .box, .triangle]
    let labels = ["圈画", "方框", "三角"]
    let size = CGSize(width: 960, height: 540)
    let fps = 24, count = 96
    var metadata: [[String: String]] = []
    for (cue, kind) in kinds.enumerated() {
        let line = try #require(words.map { word in
            LyricLine(id: 100, text: word, start: 0, end: 0.40,
                      words: [.init(id: 0, text: word, start: 0.32, end: 0.40)])
        }.first { line in
            LyricTypography.layout(line: line, index: 0, in: size, position: 0.38, reduceMotion: false).first?.accent?.kind == kind
        })
        let document = LyricDocument(lines: [line, .init(id: 101, text: "we", start: 0.40, end: 0.50),
                                             .init(id: 102, text: "are", start: 0.50, end: 0.60),
                                             .init(id: 103, text: "on our way", start: 0.60, end: 4)],
                                     timing: .word, sourceDescription: "Original artificial timestamps")
        metadata.append(["kind": labels[cue], "text": line.text, "first_frame": String(cue * count),
                         "trigger": "0.32", "original_cue_end": "0.40", "drawn_frame": String(cue * count + 17)])
        for frame in 0..<count {
            let time = Double(frame) / Double(fps)
            let view = KineticLyricFrameView(document: document, position: time)
                .frame(width: size.width, height: size.height - 90).padding(.top, 50).padding(.bottom, 40)
                .frame(width: size.width, height: size.height).background(Color(red: 0.035, green: 0.045, blue: 0.045))
                .overlay(alignment: .topLeading) {
                    Text("ALPACA / COMPLETE ONCE  ·  " + labels[cue] + "  ·  0.32 触发 / 0.40 换句")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.6)).padding(20)
                }
                .overlay(alignment: .bottomLeading) {
                    Text("原创测试文字 · 人工短词时间 · 下一句正常显示，原强调继续完成 · 无声音")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).padding(20)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(String(format: "%.2f / 4.00 s", time)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5)).padding(20)
                }
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height); renderer.scale = 1
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(String(format: "frame-%04d.png", cue * count + frame)))
        }
    }
    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("montage.json"))
}
