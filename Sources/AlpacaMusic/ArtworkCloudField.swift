import Foundation
import simd

/// An image-derived pigment field, not an estimate of semantic scene depth.
/// Area integration supplies the faithful endpoint. The abstract endpoint uses
/// broad pigment regions and a spatially coherent sampling field; it does not
/// ask a face/text detector to manufacture a different picture.
struct ArtworkCloudField: Sendable {
    struct Cell: Sendable {
        var linearColor: SIMD3<Float> = .zero
        var alpha: Float = 0
        var perceptualLuminance: Float = 0
        var detailProtection: Float = 0
        var depth: Float = 0.5
        var regionPhase: Float = 0
        var densityWeight: Float = 1
        var footprintScale: Float = 1
        var flow: SIMD2<Float> = .zero
    }

    var cells: [Cell]

    static func make(_ image: ArtworkPixels, grid: Int, abstraction: Float = 0, seed: UInt64 = 0) async throws -> ArtworkCloudField {
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
        let amount = abstraction.isFinite ? min(1, max(0, abstraction)) : 0
        if amount > 0 {
            try abstractPigments(&cells, coverage: coverage, grid: grid, amount: amount, seed: seed)
        }
        return ArtworkCloudField(cells: cells)
    }

    /// Filtering and palette extraction are performed once, off the main thread.
    /// All filters are separable O(grid²); the palette has six entries and only
    /// 4096 training samples, independent of the selected quality tier.
    private static func abstractPigments(_ cells: inout [Cell], coverage: [Float], grid: Int, amount: Float, seed: UInt64) throws {
        let fineRadius = max(1, Int((Float(grid) * (0.008 + 0.020 * amount)).rounded()))
        let broadRadius = max(1, Int((Float(grid) * (0.024 + 0.035 * amount)).rounded()))
        var fine = [SIMD3<Float>](repeating: .zero, count: cells.count)
        var broad = fine
        for component in 0..<3 {
            let values = cells.map { $0.linearColor[component] }
            let fineValues = try boxBlur(values, coverage: coverage, grid: grid, radius: fineRadius)
            let broadValues = try boxBlur(
                try boxBlur(values, coverage: coverage, grid: grid, radius: broadRadius),
                coverage: coverage, grid: grid, radius: broadRadius)
            for index in cells.indices {
                fine[index][component] = fineValues[index]
                broad[index][component] = broadValues[index]
            }
        }
        let palette = try pigmentPalette(broad, coverage: coverage)
        let paletteLab = palette.map(okLab)
        var borderColor = SIMD3<Float>.zero, borderWeight: Float = 0
        let borderWidth = max(1, grid / 10)
        for y in 0..<grid { for x in 0..<grid where x < borderWidth || x >= grid - borderWidth || y < borderWidth || y >= grid - borderWidth {
            let index = y * grid + x
            borderColor += broad[index] * coverage[index]
            borderWeight += coverage[index]
        } }
        let borderLab = okLab(borderWeight > 0 ? borderColor / borderWeight : .zero)
        let phaseOffset = Float(seed & 0xFFFF) / 65535 * 13.7
        let fineBlend = 0.30 + 0.18 * (1 - amount)
        let retainedDetail = (1 - amount) * (1 - amount)
        let pigmentStrength = 0.72 * amount
        let spatialStrength = amount * (2 - amount)
        for y in 0..<grid {
            for x in 0..<grid {
                let index = y * grid + x
                guard coverage[index] > 0 else { continue }
                let uv = SIMD2((Float(x) + 0.5) / Float(grid), (Float(y) + 0.5) / Float(grid))
                let region = smoothNoise(uv * 3.6 + SIMD2(phaseOffset, phaseOffset * 0.37), seed: seed)
                let grainRegion = smoothNoise(uv * 7.2 + SIMD2(4.7, -2.3), seed: seed ^ 0xA0761D6478BD642F)
                let phase = min(1, max(0, region * 0.78 + grainRegion * 0.22))
                let base = simd_mix(broad[index], fine[index], SIMD3(repeating: fineBlend))
                let smoothColor = simd_mix(base, cells[index].linearColor, SIMD3(repeating: retainedDetail))
                let pigment = softPigment(smoothColor, palette: palette, paletteLab: paletteLab)
                cells[index].linearColor = simd_mix(smoothColor, pigment, SIMD3(repeating: pigmentStrength))
                cells[index].perceptualLuminance = simd_dot(perceptual(cells[index].linearColor), SIMD3(0.2126, 0.7152, 0.0722))

                let left = broad[y * grid + max(0, x - broadRadius)]
                let right = broad[y * grid + min(grid - 1, x + broadRadius)]
                let top = broad[max(0, y - broadRadius) * grid + x]
                let bottom = broad[min(grid - 1, y + broadRadius) * grid + x]
                let macroContrast = min(1, max(simd_length(right - left), simd_length(bottom - top)) / 0.52)
                let salience = smoothstep(0.045, 0.23, simd_length(okLab(broad[index]) - borderLab))
                let absolutePosition = abs(uv * 2 - 1)
                let edge = pow(pow(absolutePosition.x, 4) + pow(absolutePosition.y, 4), 0.25)
                // Correlated vacancies read as pigment islands and breathing
                // spaces, rather than an independently diluted pixel lattice.
                let island = smoothstep(0.30, 0.73, phase)
                let rim = smoothstep(0.72, 1.08, edge)
                // Similarity to the outer pigment field identifies broad empty
                // backgrounds without classifying a face or preserving type.
                // Both salience and islands act at a scale wider than lettering.
                let occupancy = min(0.98, max(0.015, 0.018 + 0.82 * island * (0.28 + 0.72 * salience) +
                                             macroContrast * (0.22 + 0.10 * island)))
                cells[index].densityWeight = (1 - spatialStrength * (1 - occupancy)) * (1 - spatialStrength * rim * 0.88)
                cells[index].regionPhase = phase
                let dustScale = 0.48 + phase * 0.36
                let pigmentScale = 1.28 + 0.98 * island
                let contourScale = 0.68 + 0.40 * island
                let bodyScale = dustScale * (1 - salience) + pigmentScale * salience
                let layeredScale = bodyScale * (1 - macroContrast * 0.72) + contourScale * macroContrast * 0.72
                cells[index].footprintScale = 1 + spatialStrength * (layeredScale - 1)
                cells[index].detailProtection = cells[index].detailProtection * retainedDetail + macroContrast * amount * 0.40
                // A curl of the coarse field yields coherent drifting ribbons.
                // Its displacement is bounded in the sampler, not accumulated.
                let epsilon: Float = 0.025
                let noisePosition = uv * 3.6 + SIMD2(phaseOffset, phaseOffset * 0.37)
                let dx = smoothNoise(noisePosition + SIMD2(epsilon, 0), seed: seed) - smoothNoise(noisePosition - SIMD2(epsilon, 0), seed: seed)
                let dy = smoothNoise(noisePosition + SIMD2(0, epsilon), seed: seed) - smoothNoise(noisePosition - SIMD2(0, epsilon), seed: seed)
                let curl = SIMD2(dy, -dx) / (epsilon * 2)
                cells[index].flow = curl / max(1, simd_length(curl))
                let relief = (phase - 0.5) * amount * 0.14
                cells[index].depth = min(0.72, max(0.28, cells[index].depth + relief))
            }
            if y.isMultiple(of: 12) { try Task.checkCancellation() }
        }
    }

    private static func pigmentPalette(_ colors: [SIMD3<Float>], coverage: [Float]) throws -> [SIMD3<Float>] {
        let stride = max(1, (colors.count + 4095) / 4096)
        var samples: [(color: SIMD3<Float>, lab: SIMD3<Float>, weight: Float)] = []
        for index in Swift.stride(from: 0, to: colors.count, by: stride) where coverage[index] > 0 {
            samples.append((colors[index], okLab(colors[index]), coverage[index]))
        }
        guard let first = samples.first else { return [.zero] }
        var palette = [first.color]
        // Farthest-point initialization covers the artwork's hues instead of
        // seeding the palette with arbitrary colors or the first six pixels.
        while palette.count < 6, palette.count < samples.count {
            let centers = palette.map(okLab)
            var next = first, farthest: Float = 0
            for sample in samples {
                var distance = Float.infinity
                for center in centers { distance = min(distance, simd_length_squared(sample.lab - center)) }
                if distance * sample.weight > farthest { farthest = distance * sample.weight; next = sample }
            }
            guard farthest > 0.000001 else { break }
            palette.append(next.color)
        }
        for _ in 0..<4 {
            try Task.checkCancellation()
            let centers = palette.map(okLab)
            var sum = [SIMD3<Float>](repeating: .zero, count: palette.count)
            var weights = [Float](repeating: 0, count: palette.count)
            for sample in samples {
                var best = 0, bestDistance = Float.infinity
                for index in centers.indices {
                    let distance = simd_length_squared(sample.lab - centers[index])
                    if distance < bestDistance { bestDistance = distance; best = index }
                }
                sum[best] += sample.color * sample.weight
                weights[best] += sample.weight
            }
            for index in palette.indices where weights[index] > 0 { palette[index] = sum[index] / weights[index] }
        }
        return palette
    }

    private static func softPigment(_ color: SIMD3<Float>, palette: [SIMD3<Float>], paletteLab: [SIMD3<Float>]) -> SIMD3<Float> {
        let lab = okLab(color)
        var first = 0, second = 0, firstDistance = Float.infinity, secondDistance = Float.infinity
        for index in paletteLab.indices {
            let distance = simd_length_squared(lab - paletteLab[index])
            if distance < firstDistance {
                second = first; secondDistance = firstDistance
                first = index; firstDistance = distance
            } else if distance < secondDistance { second = index; secondDistance = distance }
        }
        guard palette.count > 1 else { return palette[first] }
        let secondWeight = 0.5 * exp(-max(0, secondDistance - firstDistance) * 110)
        return simd_mix(palette[first], palette[second], SIMD3(repeating: secondWeight))
    }

    private static func okLab(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let l = cbrtf(max(0, simd_dot(color, SIMD3(0.41222147, 0.53633254, 0.05144599))))
        let m = cbrtf(max(0, simd_dot(color, SIMD3(0.2119035, 0.6806995, 0.10739696))))
        let s = cbrtf(max(0, simd_dot(color, SIMD3(0.08830246, 0.28171884, 0.6299787))))
        return SIMD3(0.21045426 * l + 0.7936178 * m - 0.004072047 * s,
                     1.9779985 * l - 2.4285922 * m + 0.4505937 * s,
                     0.025904037 * l + 0.78277177 * m - 0.80867577 * s)
    }

    private static func smoothstep(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = min(1, max(0, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }

    private static func smoothNoise(_ position: SIMD2<Float>, seed: UInt64) -> Float {
        let x = Int(floor(position.x)), y = Int(floor(position.y))
        let fx = smoothstep(0, 1, position.x - Float(x)), fy = smoothstep(0, 1, position.y - Float(y))
        func value(_ ix: Int, _ iy: Int) -> Float {
            var bits = seed ^ (UInt64(bitPattern: Int64(ix)) &* 0x9E3779B185EBCA87) ^ (UInt64(bitPattern: Int64(iy)) &* 0xC2B2AE3D27D4EB4F)
            bits = (bits ^ (bits >> 30)) &* 0xBF58476D1CE4E5B9
            bits = (bits ^ (bits >> 27)) &* 0x94D049BB133111EB
            bits ^= bits >> 31
            return Float(bits >> 40) / Float(1 << 24)
        }
        let top = value(x, y) * (1 - fx) + value(x + 1, y) * fx
        let bottom = value(x, y + 1) * (1 - fx) + value(x + 1, y + 1) * fx
        return top * (1 - fy) + bottom * fy
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
