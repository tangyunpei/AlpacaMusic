import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Three original synthesized ambient studies. No recordings or third-party music.
enum DemoLibrary {
    static func tracks(in directory: URL) async throws -> [Track] {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let definitions: [(String, String, Double, UInt32, [Int])] = [
                ("quiet-morning", "晨间留白", 130.8128, 731, [0, 5, 9, 7]),
                ("blue-hour", "蓝调时刻", 110, 1729, [0, 3, 8, 5]),
                ("after-rain", "雨后漫步", 146.8324, 2609, [0, 7, 5, 2])
            ]
            return try definitions.enumerated().map { index, item in
                let url = directory.appendingPathComponent("\(item.0)-v1.wav")
                // Exact byte count detects partial writes from a previously interrupted launch.
                let expectedSize = 44 + 22050 * 28 * 2
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size != expectedSize { try synthesize(root: item.2, seed: item.3, progression: item.4).write(to: url, options: .atomic) }
                return Track(id: "demo-\(item.0)", title: item.1, artist: "Alpaca Sessions", album: "原创试听 · Ambient Studies", duration: 28, source: .demo, url: url, artworkData: artwork(index: index), format: "WAV", addedAt: .distantPast)
            }
        }.value
    }
    static func synthesize(root: Double, seed: UInt32, progression: [Int]) -> Data {
        let rate = 22050, length = 28, count = rate * length
        var data = Data(count: 44 + count * 2)
        data.withUnsafeMutableBytes { raw in
            func ascii(_ offset: Int, _ text: String) { for (index, byte) in text.utf8.enumerated() { raw[offset + index] = byte } }
            func uint16(_ offset: Int, _ value: UInt16) { raw.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt16.self) }
            func uint32(_ offset: Int, _ value: UInt32) { raw.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self) }
            ascii(0, "RIFF"); uint32(4, UInt32(36 + count * 2)); ascii(8, "WAVE"); ascii(12, "fmt ")
            uint32(16, 16); uint16(20, 1); uint16(22, 1); uint32(24, UInt32(rate)); uint32(28, UInt32(rate * 2)); uint16(32, 2); uint16(34, 16)
            ascii(36, "data"); uint32(40, UInt32(count * 2))
            var noise = seed
            let notes = [0, 7, 12, 16, 19, 14, 12, 7]
            let ratios = [1.0, pow(2, 7.0 / 12), pow(2, 16.0 / 12)]
            for index in 0..<count {
                let time = Double(index) / Double(rate), section = min(3, Int(time / 7))
                let chord = root * pow(2, Double(progression[section]) / 12)
                let beat = time.truncatingRemainder(dividingBy: 0.875)
                let note = chord * pow(2, Double(notes[Int(time / 0.875) % notes.count]) / 12)
                var pad = 0.0
                for (harmonic, ratio) in ratios.enumerated() {
                    pad += sin(2 * .pi * chord * ratio * time + 0.3 * sin(time * 0.31 + Double(harmonic))) * (0.048 + 0.014 * sin(time * 0.6 + Double(harmonic)))
                }
                let envelope = (1 - exp(-beat * 70)) * exp(-beat * 4.5)
                let bell = (sin(2 * .pi * note * time) + 0.22 * sin(2 * .pi * note * 2.002 * time)) * envelope * 0.12
                let bass = sin(2 * .pi * 58 * beat) * exp(-beat * 14) * 0.1
                noise = noise &* 1664525 &+ 1013904223
                let breath = (Double(noise) / 4294967296 * 2 - 1) * 0.003 * (0.7 + sin(time * 0.24) * 0.3)
                let fade = min(1, time / 1.7, max(0, (Double(length) - time) / 2.8))
                let within = time.truncatingRemainder(dividingBy: 7), chordFade = min(1, within / 0.08, (7 - within) / 0.08)
                let sample = Int16((tanh((pad * chordFade + bell + bass + breath) * fade * 1.5) * 28000).rounded())
                uint16(44 + index * 2, UInt16(bitPattern: sample))
            }
        }
        return data
    }
    private static func artwork(index: Int) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors: [[CGFloat]] = [[0.91, 0.78, 0.61, 1, 0.35, 0.44, 0.36, 1], [0.15, 0.25, 0.47, 1, 0.65, 0.52, 0.63, 1], [0.25, 0.46, 0.46, 1, 0.76, 0.79, 0.60, 1]]
        guard let gradient = CGGradient(colorSpace: colorSpace, colorComponents: colors[index], locations: [0, 1], count: 2) else { return nil }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 512), end: CGPoint(x: 512, y: 0), options: [])
        context.setFillColor(CGColor(red: 0.99, green: 0.94, blue: 0.80, alpha: 0.85))
        context.fillEllipse(in: CGRect(x: index == 1 ? 300 : 75, y: 285, width: index == 1 ? 70 : 120, height: index == 1 ? 70 : 120))
        for row in 0..<7 {
            context.setStrokeColor(CGColor(gray: 0.98, alpha: 0.13 + Double(row) * 0.012)); context.setLineWidth(1.2)
            let path = CGMutablePath(); let y = CGFloat(row * 22 + 120)
            path.move(to: CGPoint(x: -20, y: y)); path.addCurve(to: CGPoint(x: 540, y: y + 65), control1: CGPoint(x: 160, y: y + 140), control2: CGPoint(x: 325, y: y - 95))
            context.addPath(path); context.strokePath()
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
