import AppKit
import CoreGraphics
import ImageIO

struct ArtworkPixels: Sendable {
    var width: Int
    var height: Int
    var rgba: [UInt8]
}

struct ArtworkResult: Sendable {
    var pixels: ArtworkPixels
    var usedFallback: Bool
}

struct ArtworkRandom: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24)
    }
}

@MainActor
enum Artwork {
    private static var images: [String: NSImage] = [:]
    private static var rasters: [String: ArtworkResult] = [:]
    private static var loads: [String: Task<ArtworkResult, Never>] = [:]

    nonisolated static func seed(for track: Track?) -> UInt64 {
        let text = track.map { "\($0.artist)\u{0}\($0.title)" } ?? "AlpacaMusic\u{0}A little room for sound"
        return text.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    nonisolated static func key(for track: Track?) -> String {
        guard let track else { return "placeholder" }
        // This identity is only used by the in-memory cache. Data's optimized
        // hash avoids a Swift byte-by-byte pass on every SwiftUI update.
        let digest = track.artworkData?.hashValue ?? 0
        return "\(seed(for: track))-\(digest)-\(track.artworkURL?.absoluteString ?? "")"
    }

    static func image(for track: Track?) -> NSImage {
        let key = key(for: track)
        if let image = images[key] { return image }
        let pixels = track?.artworkData.flatMap { decode($0) } ?? placeholder(for: track)
        let image = makeImage(pixels)
        images[key] = image
        trimCaches()
        return image
    }

    // List rows never synchronously rasterize an album or procedural cover.
    // The worker pool below limits both image decoding and network fan-out.
    static func loadThumbnail(for track: Track?) async -> NSImage? {
        let task = Task.detached(priority: .utility) { await ArtworkThumbnailStore.shared.pixels(for: track) }
        let pixels = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, let pixels else { return nil }
        return makeImage(pixels)
    }

    static func loadImage(for track: Track?) async -> NSImage {
        let result = await raster(for: track)
        let image = makeImage(result.pixels)
        images[key(for: track)] = image
        return image
    }

    static func raster(for track: Track?) async -> ArtworkResult {
        let key = key(for: track)
        if let cached = rasters[key] { return cached }
        if let loading = loads[key] { return await loading.value }
        let task = Task.detached(priority: .userInitiated) { () -> ArtworkResult in
            if let data = track?.artworkData, let pixels = decode(data) {
                return ArtworkResult(pixels: pixels, usedFallback: false)
            }
            if let url = track?.artworkURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                do {
                    var request = URLRequest(url: url, timeoutInterval: 12)
                    request.httpShouldHandleCookies = false
                    let (data, response) = try await URLSession.shared.data(for: request)
                    if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count <= 25 * 1024 * 1024, let pixels = decode(data) {
                        return ArtworkResult(pixels: pixels, usedFallback: false)
                    }
                } catch { /* A deterministic cover remains visible when an endpoint fails. */ }
            }
            return ArtworkResult(pixels: placeholder(for: track), usedFallback: track?.artworkData != nil || track?.artworkURL != nil)
        }
        loads[key] = task
        let result = await task.value
        loads[key] = nil
        rasters[key] = result
        images[key] = makeImage(result.pixels)
        trimCaches()
        return result
    }

    private static func trimCaches() {
        while images.count > 48, let key = images.keys.first { images.removeValue(forKey: key) }
        while rasters.count > 24, let key = rasters.keys.first { rasters.removeValue(forKey: key) }
    }

    private static func makeImage(_ pixels: ArtworkPixels) -> NSImage {
        guard let image = cgImage(pixels) else { return NSImage(size: NSSize(width: 512, height: 512)) }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    nonisolated static func cgImage(_ pixels: ArtworkPixels) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels.rgba) as CFData) else { return nil }
        return CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: pixels.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    nonisolated static func decode(_ data: Data, size: Int = 512) -> ArtworkPixels? {
        guard data.count <= 25 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size * 2,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        guard let context = context(size: size) else { return nil }
        let side = CGFloat(size)
        let scale = side / CGFloat(min(image.width, image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
        guard let pixels = readPixels(context) else { return nil }
        guard stride(from: 3, to: pixels.rgba.count, by: 4).contains(where: { pixels.rgba[$0] >= 10 }) else { return nil }
        return pixels
    }

    nonisolated private static func context(size: Int) -> CGContext? {
        CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    nonisolated private static func readPixels(_ context: CGContext) -> ArtworkPixels? {
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return ArtworkPixels(width: context.width, height: context.height,
                             rgba: Array(UnsafeBufferPointer(start: bytes, count: context.height * context.bytesPerRow)))
    }

    nonisolated static func placeholder(for track: Track?, size: Int = 512) -> ArtworkPixels {
        guard let context = context(size: size) else { return ArtworkPixels(width: 1, height: 1, rgba: [70, 90, 70, 255]) }
        context.scaleBy(x: CGFloat(size) / 512, y: CGFloat(size) / 512)
        let seed = seed(for: track)
        var random = ArtworkRandom(seed: seed)
        let palettes: [[UInt32]] = [
            [0x314437, 0xdbe0b5, 0x9ba785, 0x617953, 0x2b4936],
            [0x243b45, 0xd3dcce, 0x91abaa, 0x486d7b, 0x243e4d],
            [0x3d3f31, 0xeac790, 0xc2915a, 0x8d8c62, 0x536143]
        ]
        let palette = palettes[Int(seed % 3)]
        func color(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: alpha)
        }
        context.setFillColor(color(palette[0])); context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        let center = CGPoint(x: 250 + CGFloat(random.next()) * 65, y: 302 + CGFloat(random.next()) * 35)
        let radius = 122 + CGFloat(random.next()) * 27
        context.saveGState()
        context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(palette[1]), color(palette[2])] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: center.x - radius, y: center.y + radius), end: CGPoint(x: center.x + radius, y: center.y - radius), options: [])
        }
        context.restoreGState()
        context.setStrokeColor(color(palette[1], alpha: 0.24)); context.setLineWidth(0.8)
        for i in 0..<4 {
            context.addArc(center: center, radius: radius + 14 + CGFloat(i) * 11, startAngle: .pi * 0.08, endAngle: .pi * 0.8, clockwise: false)
            context.strokePath()
        }
        for i in 0..<3 {
            let y = CGFloat(200 - i * 73)
            context.setFillColor(color(palette[min(i + 2, 4)]))
            context.move(to: CGPoint(x: 0, y: y))
            context.addCurve(to: CGPoint(x: 272, y: y - 7), control1: CGPoint(x: 87, y: y + 102), control2: CGPoint(x: 156, y: y + 45))
            context.addCurve(to: CGPoint(x: 512, y: y + 7), control1: CGPoint(x: 372, y: y - 50), control2: CGPoint(x: 451, y: y + 60))
            context.addLine(to: CGPoint(x: 512, y: 0)); context.addLine(to: .zero); context.closePath(); context.fillPath()
        }
        context.setStrokeColor(color(palette[1], alpha: 0.15)); context.setLineWidth(0.6)
        for i in 0..<8 {
            let y = CGFloat(35 + i * 8)
            context.move(to: CGPoint(x: 0, y: y))
            context.addCurve(to: CGPoint(x: 512, y: y + 20), control1: CGPoint(x: 154, y: y + 104), control2: CGPoint(x: 273, y: y - 65))
            context.strokePath()
        }
        let detail = min(1, Double(size) / 512)
        let grainCount = max(96, Int(7000 * detail * detail))
        for _ in 0..<grainCount {
            context.setFillColor(color(random.next() > 0.5 ? 0xf0e4c4 : 0x0e1e18, alpha: 0.065))
            context.fill(CGRect(x: CGFloat(random.next()) * 512, y: CGFloat(random.next()) * 512, width: 0.7, height: 0.7))
        }
        return readPixels(context) ?? ArtworkPixels(width: 1, height: 1, rgba: [70, 90, 70, 255])
    }
}


/// Cancellation-aware permits bound the work caused by a quick scroll through a
/// large library. Cancelled offscreen rows leave the waiting queue immediately.
actor ArtworkWorkLimiter {
    private let limit: Int
    private var running = 0
    private var waiting: [(UUID, CheckedContinuation<Bool, Never>)] = []
    init(limit: Int = 4) { self.limit = max(1, limit) }
    func acquire() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else if running < limit { running += 1; continuation.resume(returning: true) }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func release() {
        if !waiting.isEmpty { waiting.removeFirst().1.resume(returning: true) }
        else { running = max(0, running - 1) }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(returning: false)
    }
}

private actor ArtworkThumbnailStore {
    static let shared = ArtworkThumbnailStore()
    private let limiter = ArtworkWorkLimiter()
    private var cache: [String: ArtworkPixels] = [:]
    private var recency: [String] = []
    func pixels(for track: Track?) async -> ArtworkPixels? {
        let key = Artwork.key(for: track)
        if let cached = cache[key] { touch(key); return cached }
        guard await limiter.acquire() else { return nil }
        let result = await Self.read(track)
        await limiter.release()
        guard !Task.isCancelled, let result else { return nil }
        cache[key] = result; touch(key)
        while recency.count > 192 { cache.removeValue(forKey: recency.removeFirst()) }
        return result
    }
    private func touch(_ key: String) { recency.removeAll { $0 == key }; recency.append(key) }
    nonisolated private static func read(_ track: Track?) async -> ArtworkPixels? {
        guard !Task.isCancelled else { return nil }
        if let data = track?.artworkData, let image = Artwork.decode(data, size: 128) { return image }
        if let url = track?.artworkURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            do {
                var request = URLRequest(url: url, timeoutInterval: 10)
                request.httpShouldHandleCookies = false
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                   let image = Artwork.decode(data, size: 128) { return image }
            } catch { if Task.isCancelled { return nil } }
        }
        guard !Task.isCancelled else { return nil }
        return Artwork.placeholder(for: track, size: 128)
    }
}
