import Foundation
import simd

/// An image-plane field for cover artwork, not an estimate of semantic scene depth.
/// Color is integrated over each point's source footprint before restrained relief
/// and detail anchors are derived, so small type and color boundaries stay legible.
struct ArtworkCloudField: Sendable {
    struct Cell: Sendable {
        var linearColor: SIMD3<Float> = .zero
        var alpha: Float = 0
        var perceptualLuminance: Float = 0
        var detailProtection: Float = 0
        var depth: Float = 0.5
    }

    var cells: [Cell]

    static func make(_ image: ArtworkPixels, grid: Int) async throws -> ArtworkCloudField {
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0, image.width <= 8192, image.height <= 8192,
              image.rgba.count == image.width * image.height * 4 else { throw DepthError.invalidImage }
        guard (1...512).contains(grid) else { throw DepthError.invalidGrid }

        let width = image.width, height = image.height
        let footprintWidth = Float(width) / Float(grid), footprintHeight = Float(height) / Float(grid)
        let footprintArea = footprintWidth * footprintHeight
        var cells = [Cell](repeating: Cell(), count: grid * grid)
        var withinCellDetail = [Float](repeating: 0, count: cells.count)
        var sourcePixelsProcessed = 0

        for y in 0..<grid {
            let top = Float(y) * footprintHeight, bottom = Float(y + 1) * footprintHeight
            let firstY = max(0, Int(floor(top))), lastY = min(height - 1, Int(ceil(bottom)) - 1)
            for x in 0..<grid {
                let left = Float(x) * footprintWidth, right = Float(x + 1) * footprintWidth
                let firstX = max(0, Int(floor(left))), lastX = min(width - 1, Int(ceil(right)) - 1)
                var linearSum = SIMD3<Double>.zero
                var perceptualSum = SIMD3<Double>.zero, perceptualSquareSum = SIMD3<Double>.zero
                var alphaWeight: Double = 0

                for sy in firstY...lastY {
                    let verticalWeight = min(bottom, Float(sy + 1)) - max(top, Float(sy))
                    for sx in firstX...lastX {
                        let offset = (sy * width + sx) * 4, alphaByte = Int(image.rgba[offset + 3])
                        guard alphaByte > 0 else { continue }
                        let area = verticalWeight * (min(right, Float(sx + 1)) - max(left, Float(sx)))
                        let weight = Double(area) * Double(alphaByte) / 255
                        let red = Int(image.rgba[offset]), green = Int(image.rgba[offset + 1]), blue = Int(image.rgba[offset + 2])
                        let linear = SIMD3(
                            Double(linearPremultipliedLookup[alphaByte * 256 + red]),
                            Double(linearPremultipliedLookup[alphaByte * 256 + green]),
                            Double(linearPremultipliedLookup[alphaByte * 256 + blue]))
                        let inverseAlpha = 1 / Double(alphaByte)
                        let perceptual = SIMD3(Double(min(red, alphaByte)), Double(min(green, alphaByte)), Double(min(blue, alphaByte))) * inverseAlpha
                        linearSum += linear * weight
                        perceptualSum += perceptual * weight
                        perceptualSquareSum += perceptual * perceptual * weight
                        alphaWeight += weight
                    }
                    sourcePixelsProcessed += lastX - firstX + 1
                    if sourcePixelsProcessed >= 65_536 { try Task.checkCancellation(); await Task.yield(); sourcePixelsProcessed = 0 }
                }

                let index = y * grid + x
                guard alphaWeight > 0 else { continue }
                let integratedColor = linearSum / alphaWeight
                let linearColor = SIMD3(Float(integratedColor.x), Float(integratedColor.y), Float(integratedColor.z))
                let perceptualMean = perceptualSum / alphaWeight
                let variance = simd_max(.zero, perceptualSquareSum / alphaWeight - perceptualMean * perceptualMean)
                cells[index].linearColor = linearColor
                cells[index].alpha = min(1, Float(alphaWeight / Double(footprintArea)))
                cells[index].perceptualLuminance = simd_dot(perceptual(linearColor), SIMD3(0.2126, 0.7152, 0.0722))
                withinCellDetail[index] = Float(sqrt((variance.x + variance.y + variance.z) / 3))
            }
            if y.isMultiple(of: 12) { try Task.checkCancellation(); await Task.yield() }
        }

        let coverage = cells.map(\.alpha)
        let luminance = cells.map { simd_dot($0.linearColor, SIMD3<Float>(0.2126, 0.7152, 0.0722)) }
        let totalCoverage = coverage.reduce(Double(0)) { $0 + Double($1) }
        guard totalCoverage > 0 else { return ArtworkCloudField(cells: cells) }
        let mean = Float(zip(luminance, coverage).reduce(Double(0)) { $0 + Double($1.0) * Double($1.1) } / totalCoverage)
        let visibleLuminance = zip(luminance, coverage).compactMap { $0.1 > 0 ? $0.0 : nil }
        let hasTonalRelief = (visibleLuminance.max() ?? 0) - (visibleLuminance.min() ?? 0) > Float.ulpOfOne * 8
        let local = try boxBlur(luminance, coverage: coverage, grid: grid, radius: max(1, grid / 100))
        let broad = try boxBlur(
            try boxBlur(luminance, coverage: coverage, grid: grid, radius: max(1, grid / 24)),
            coverage: coverage, grid: grid, radius: max(1, grid / 24))
        let colors = cells.map { perceptual($0.linearColor) }

        for y in 0..<grid {
            for x in 0..<grid {
                let index = y * grid + x
                guard coverage[index] > 0 else { continue }
                var colorContrast: Float = 0, alphaContrast: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < grid, ny >= 0, ny < grid else { continue }
                        let neighbor = ny * grid + nx
                        alphaContrast = max(alphaContrast, abs(coverage[index] - coverage[neighbor]))
                        if coverage[neighbor] >= 10 / 255 {
                            colorContrast = max(colorContrast, simd_length(colors[index] - colors[neighbor]) / sqrt(3))
                        }
                    }
                }
                // RGB contrast catches equal-luminance colored outlines, and
                // within-footprint variance protects detail below the grid size.
                let protection = min(1, max(colorContrast / 0.20, max(withinCellDetail[index] / 0.12, alphaContrast / 0.35)))
                cells[index].detailProtection = protection
                let relief = (0.24 * (broad[index] - mean) + 0.06 * (local[index] - broad[index])) * (1 - 0.75 * protection)
                // An absolute bound avoids stretching nearly flat artwork or
                // compression noise into the entire available depth range.
                cells[index].depth = hasTonalRelief ? 0.5 + min(0.18, max(-0.18, relief)) : 0.5
            }
            if y.isMultiple(of: 16) { try Task.checkCancellation(); await Task.yield() }
        }
        try Task.checkCancellation()
        return ArtworkCloudField(cells: cells)
    }

    /// CoreGraphics bytes are premultiplied in sRGB. Decode straight color first
    /// and then integrate it in linear light with alpha coverage as its weight.
    private static let linearPremultipliedLookup: [Float] = {
        var values = [Float](repeating: 0, count: 256 * 256)
        for alpha in 1...255 {
            for component in 0...255 {
                let encoded = Float(min(alpha, component)) / Float(alpha)
                values[alpha * 256 + component] = encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
            }
        }
        return values
    }()

    private static func perceptual(_ color: SIMD3<Float>) -> SIMD3<Float> {
        func encode(_ value: Float) -> Float { value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055 }
        return SIMD3(encode(color.x), encode(color.y), encode(color.z))
    }

    /// Separable area-weighted box filtering has cost proportional to grid size,
    /// independent of radius, and never blends transparent RGB into the artwork.
    private static func boxBlur(_ values: [Float], coverage: [Float], grid: Int, radius: Int) throws -> [Float] {
        var horizontalValues = [Float](repeating: 0, count: values.count)
        var horizontalWeights = [Float](repeating: 0, count: values.count)
        for y in 0..<grid {
            var sum: Float = 0, weight: Float = 0
            for x in 0...min(radius, grid - 1) {
                let index = y * grid + x
                sum += values[index] * coverage[index]; weight += coverage[index]
            }
            for x in 0..<grid {
                let index = y * grid + x
                horizontalValues[index] = sum; horizontalWeights[index] = weight
                let leaving = x - radius, entering = x + radius + 1
                if leaving >= 0 { sum -= values[y * grid + leaving] * coverage[y * grid + leaving]; weight -= coverage[y * grid + leaving] }
                if entering < grid { sum += values[y * grid + entering] * coverage[y * grid + entering]; weight += coverage[y * grid + entering] }
            }
            if y.isMultiple(of: 32) { try Task.checkCancellation() }
        }
        var result = [Float](repeating: 0, count: values.count)
        for x in 0..<grid {
            var sum: Float = 0, weight: Float = 0
            for y in 0...min(radius, grid - 1) { sum += horizontalValues[y * grid + x]; weight += horizontalWeights[y * grid + x] }
            for y in 0..<grid {
                let index = y * grid + x
                result[index] = weight > 0 ? min(1, max(0, sum / weight)) : values[index]
                let leaving = y - radius, entering = y + radius + 1
                if leaving >= 0 { sum -= horizontalValues[leaving * grid + x]; weight -= horizontalWeights[leaving * grid + x] }
                if entering < grid { sum += horizontalValues[entering * grid + x]; weight += horizontalWeights[entering * grid + x] }
            }
            if x.isMultiple(of: 32) { try Task.checkCancellation() }
        }
        return result
    }
}
