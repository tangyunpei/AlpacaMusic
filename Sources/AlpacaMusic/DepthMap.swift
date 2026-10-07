import Foundation
import simd

protocol DepthProvider: Sendable {
    func compute(_ image: ArtworkPixels, grid: Int) async throws -> [Float]
}

enum DepthError: Error { case invalidImage, invalidGrid, invalidGamma, emptyArtwork }

struct LuminanceDepthProvider: DepthProvider {
    var gamma: Float = 1

    func compute(_ image: ArtworkPixels, grid: Int) async throws -> [Float] {
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0, image.width <= 8192, image.height <= 8192,
              image.rgba.count == image.width * image.height * 4 else { throw DepthError.invalidImage }
        guard (1...512).contains(grid) else { throw DepthError.invalidGrid }
        guard gamma.isFinite, gamma > 0 else { throw DepthError.invalidGamma }
        let width = image.width, height = image.height, count = width * height
        var luminance = [Float](repeating: 0, count: count), visible = [Float](repeating: 0, count: count)
        var horizontal = [Float](repeating: 0, count: count), weights = [Float](repeating: 0, count: count)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x, p = i * 4
                let alpha = Float(image.rgba[p + 3]) / 255
                visible[i] = image.rgba[p + 3] >= 10 ? 1 : 0
                // CoreGraphics stores premultiplied color. Unpremultiply before
                // computing luminance so soft edges do not become deep trenches.
                luminance[i] = alpha > 0 ? min(1, (0.2126 * Float(image.rgba[p]) + 0.7152 * Float(image.rgba[p + 1]) + 0.0722 * Float(image.rgba[p + 2])) / (255 * alpha)) : 0
            }
            if y.isMultiple(of: 32) { try Task.checkCancellation(); await Task.yield() }
        }
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                for dx in -1...1 {
                    let n = y * width + min(width - 1, max(0, x + dx)), weight = Float(dx == 0 ? 2 : 1) * visible[n]
                    horizontal[i] += luminance[n] * weight
                    weights[i] += weight
                }
            }
            if y.isMultiple(of: 32) { try Task.checkCancellation(); await Task.yield() }
        }
        var result = [Float](repeating: 0.5, count: grid * grid), valid = [Bool](repeating: false, count: grid * grid)
        var histogram = [Int](repeating: 0, count: 4096), total = 0, minimum: Float = 1, maximum: Float = 0
        for y in 0..<grid {
            let sy = min(height - 1, Int((Float(y) + 0.5) * Float(height) / Float(grid)))
            for x in 0..<grid {
                let sx = min(width - 1, Int((Float(x) + 0.5) * Float(width) / Float(grid))), i = y * grid + x
                guard visible[sy * width + sx] > 0 else { continue }
                var sum: Float = 0, weight: Float = 0
                for dy in -1...1 {
                    let n = min(height - 1, max(0, sy + dy)) * width + sx, factor = Float(dy == 0 ? 2 : 1)
                    sum += horizontal[n] * factor; weight += weights[n] * factor
                }
                let value = weight > 0 ? sum / weight : 0.5
                result[i] = value; valid[i] = true; total += 1
                minimum = min(minimum, value); maximum = max(maximum, value)
                histogram[min(4095, max(0, Int((value * 4095).rounded())))] += 1
            }
            if y.isMultiple(of: 16) { try Task.checkCancellation(); await Task.yield() }
        }
        guard total > 0, maximum - minimum >= 1 / 4095 else { return [Float](repeating: 0.5, count: grid * grid) }
        let lowerRank = Int(Float(total - 1) * 0.02), upperRank = Int(ceil(Float(total - 1) * 0.98))
        var accumulated = 0, low = -1, high = 4095
        for i in histogram.indices {
            accumulated += histogram[i]
            if low == -1 && accumulated > lowerRank { low = i }
            if accumulated > upperRank { high = i; break }
        }
        let lo = high > low ? Float(low) / 4095 : minimum, hi = high > low ? Float(high) / 4095 : maximum
        let span = max(1 / 4095, hi - lo)
        for i in result.indices where valid[i] { result[i] = pow(min(1, max(0, (result[i] - lo) / span)), gamma) }
        try Task.checkCancellation()
        return result
    }
}

/// Four float4 values match the 64-byte Metal vertex layout without padding ambiguity.
struct CloudPoint: Sendable {
    var positionDepthSeed: SIMD4<Float>
    var colorLuminance: SIMD4<Float>
    var scatter: SIMD4<Float>
    var geometryFeatures: SIMD4<Float> = SIMD4(0, 1, 0, 0)
}
struct CloudSamples: Sendable { var points: [CloudPoint]; var density: Int }

enum CloudSampler {
    static func sample(_ image: ArtworkPixels, density: Int, seed: UInt64, provider: (any DepthProvider)? = nil) async throws -> CloudSamples {
        try Task.checkCancellation()
        guard (2...512).contains(density) else { throw DepthError.invalidGrid }
        let field = try await ArtworkCloudField.make(image, grid: density)
        let depth: [Float]
        if let provider {
            depth = try await provider.compute(image, grid: density)
            guard depth.count == density * density else { throw DepthError.invalidGrid }
        } else {
            depth = field.cells.map(\.depth)
        }
        var points: [CloudPoint] = []; points.reserveCapacity(density * density)
        var random = ArtworkRandom(seed: seed)
        let half = Float(density - 1) / 2
        for y in 0..<density {
            for x in 0..<density {
                let cell = field.cells[y * density + x]
                guard cell.alpha >= 10 / 255 else { continue }
                let pointSeed = random.next(), angle = random.next() * .pi * 2, z = random.next() * 2 - 1
                let radius = 0.04 + random.next() * 0.10, ring = sqrt(max(0, 1 - z * z))
                let d = depth[y * density + x]
                let baseX = (Float(x) - half) / half, baseY = -(Float(y) - half) / half
                points.append(CloudPoint(
                    positionDepthSeed: SIMD4(baseX, baseY, d.isFinite ? min(1, max(0, d)) : 0.5, pointSeed),
                    colorLuminance: SIMD4(cell.linearColor, cell.perceptualLuminance),
                    scatter: SIMD4(baseX + cos(angle) * ring * radius, baseY + sin(angle) * ring * radius, z * 0.13, cell.alpha),
                    geometryFeatures: SIMD4(cell.detailProtection, 1, 0, 0)))
            }
            if y.isMultiple(of: 12) { try Task.checkCancellation(); await Task.yield() }
        }
        guard !points.isEmpty else { throw DepthError.emptyArtwork }
        return CloudSamples(points: points, density: density)
    }
}
