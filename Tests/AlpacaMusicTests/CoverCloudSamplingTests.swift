import Foundation
import Testing
@testable import AlpacaMusic

private func coverPixels(_ width: Int, _ height: Int, pixel: (Int, Int) -> [UInt8]) -> ArtworkPixels {
    var rgba: [UInt8] = []
    rgba.reserveCapacity(width * height * 4)
    for y in 0..<height { for x in 0..<width { rgba.append(contentsOf: pixel(x, y)) } }
    return ArtworkPixels(width: width, height: height, rgba: rgba)
}

@Test func coverCloudAreaSamplingKeepsSubpixelStripesInsteadOfAliasing() async throws {
    let image = coverPixels(96, 96) { x, _ in
        let value: UInt8 = x.isMultiple(of: 2) ? 0 : 255
        return [value, value, value, 255]
    }
    let samples = try await CloudSampler.sample(image, density: 8, seed: 12)
    #expect(samples.points.count == 64)
    // Each cell covers twelve alternating black / white pixels. Linear-light
    // integration must preserve their energy, rather than select one stripe.
    #expect(samples.points.allSatisfy {
        abs($0.colorLuminance.x - 0.5) < 0.0001 &&
        abs($0.colorLuminance.y - 0.5) < 0.0001 &&
        abs($0.colorLuminance.z - 0.5) < 0.0001
    })
}

@Test func coverCloudAreaSamplingPreservesAlphaWithoutTransparentColorBleeding() async throws {
    let image = coverPixels(4, 4) { x, _ in x.isMultiple(of: 2) ? [128, 0, 0, 128] : [0, 255, 0, 0] }
    let samples = try await CloudSampler.sample(image, density: 2, seed: 12)
    #expect(samples.points.count == 4)
    #expect(samples.points.allSatisfy {
        abs($0.colorLuminance.x - 1) < 0.0001 && $0.colorLuminance.y == 0 &&
        abs($0.scatter.w - Float(64) / 255) < 0.0001
    })
}

@Test func coverCloudLowContrastTextureDoesNotBecomeFullDepthRelief() async throws {
    let image = coverPixels(32, 32) { x, y in
        let value: UInt8 = (x + y).isMultiple(of: 2) ? 127 : 128
        return [value, value, value, 255]
    }
    let samples = try await CloudSampler.sample(image, density: 32, seed: 12)
    let values = samples.points.map(\.positionDepthSeed.z)
    #expect(try #require(values.max()) - #require(values.min()) < 0.03)
    #expect(values.allSatisfy { abs($0 - 0.5) < 0.03 })
}

@Test func coverCloudProtectsLetteringAndIsoluminantColorOutlines() async throws {
    let text = coverPixels(32, 32) { x, y in
        (15...17).contains(x) && (7...24).contains(y) ? [0, 0, 0, 255] : [255, 255, 255, 255]
    }
    let letters = try await CloudSampler.sample(text, density: 32, seed: 12)
    let lineDetail = letters.points[16 * 32 + 15].geometryFeatures.x
    let backgroundDetail = letters.points[16 * 32 + 4].geometryFeatures.x
    #expect(lineDetail > backgroundDetail + 0.2)
    // Red and green have almost identical Rec.709 luminance in linear light.
    // A luminance-only edge detector would miss this album-design boundary.
    let color = coverPixels(32, 32) { x, _ in x < 16 ? [255, 0, 0, 255] : [0, 148, 0, 255] }
    let boundary = try await CloudSampler.sample(color, density: 32, seed: 12)
    #expect(boundary.points[16 * 32 + 15].geometryFeatures.x > boundary.points[16 * 32 + 4].geometryFeatures.x + 0.2)
}

@Test func coverCloudQualityLevelsPreserveColorAndFullOpaqueCoverage() async throws {
    let image = coverPixels(48, 48) { x, y in [UInt8(x * 5), UInt8(y * 5), 90, 255] }
    var means: [SIMD3<Float>] = []
    for density in [96, 160, 224] {
        let samples = try await CloudSampler.sample(image, density: density, seed: 12)
        #expect(samples.points.count == density * density)
        #expect(samples.points.allSatisfy { (0.32...0.68).contains($0.positionDepthSeed.z) && $0.geometryFeatures.y == 1 })
        let sum = samples.points.reduce(SIMD3<Float>.zero) { $0 + SIMD3($1.colorLuminance.x, $1.colorLuminance.y, $1.colorLuminance.z) }
        means.append(sum / Float(samples.points.count))
    }
    #expect(abs(means[0].x - means[2].x) < 0.003 && abs(means[0].y - means[2].y) < 0.003)
    #expect(abs(means[0].z - means[2].z) < 0.003)
}

@Test func coverCloudGeometryIsDeterministicAndTransitionsRemainLocal() async throws {
    let image = coverPixels(32, 32) { x, y in [UInt8(x * 8), UInt8(y * 8), 90, 255] }
    let first = try await CloudSampler.sample(image, density: 16, seed: 12)
    let same = try await CloudSampler.sample(image, density: 16, seed: 12)
    let other = try await CloudSampler.sample(image, density: 16, seed: 13)
    #expect(first.points.map(\.positionDepthSeed) == same.points.map(\.positionDepthSeed))
    #expect(first.points.map(\.colorLuminance) == same.points.map(\.colorLuminance))
    #expect(first.points.map(\.geometryFeatures) == same.points.map(\.geometryFeatures))
    #expect(first.points.map(\.scatter) == same.points.map(\.scatter))
    #expect(first.points.map(\.scatter) != other.points.map(\.scatter))
    #expect(first.points.allSatisfy {
        let dx = $0.scatter.x - $0.positionDepthSeed.x, dy = $0.scatter.y - $0.positionDepthSeed.y
        return sqrt(dx * dx + dy * dy) <= 0.14001 && abs($0.scatter.z) <= 0.13001
    })
}

private struct UnsafeDepthFixture: DepthProvider {
    func compute(_ image: ArtworkPixels, grid: Int) async throws -> [Float] {
        (0..<grid * grid).map { [.nan, -.infinity, -1, 2][$0 % 4] }
    }
}

@Test func coverCloudInjectedDepthIsFiniteClampedAndMalformedInputIsRejected() async throws {
    let image = coverPixels(4, 4) { _, _ in [100, 120, 140, 255] }
    let samples = try await CloudSampler.sample(image, density: 2, seed: 12, provider: UnsafeDepthFixture())
    #expect(samples.points.map(\.positionDepthSeed.z) == [0.5, 0.5, 0, 1])
    await #expect(throws: DepthError.self) {
        try await CloudSampler.sample(ArtworkPixels(width: 4, height: 4, rgba: []), density: 4, seed: 12, provider: UnsafeDepthFixture())
    }
    await #expect(throws: DepthError.self) { try await CloudSampler.sample(image, density: 1, seed: 12) }
    await #expect(throws: DepthError.self) { try await CloudSampler.sample(image, density: 513, seed: 12) }
    await #expect(throws: DepthError.self) {
        try await CloudSampler.sample(coverPixels(4, 4) { _, _ in [0, 0, 0, 0] }, density: 4, seed: 12)
    }
}

@Test func coverCloudDedicatedSamplingCanBeCancelled() async {
    let image = coverPixels(256, 256) { _, _ in [100, 120, 80, 255] }
    let task = Task { try await CloudSampler.sample(image, density: 224, seed: 12) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func abstractCoverCloudFormsDeterministicIrregularPigmentIslands() async throws {
    let image = coverPixels(64, 64) { x, y in [UInt8(x * 4), UInt8(y * 4), 90, 255] }
    let first = try await CloudSampler.sample(image, density: 64, seed: 12, abstraction: 0.55)
    let again = try await CloudSampler.sample(image, density: 64, seed: 12, abstraction: 0.55)
    #expect(first.points.map(\.positionDepthSeed) == again.points.map(\.positionDepthSeed))
    #expect(first.points.map(\.colorLuminance) == again.points.map(\.colorLuminance))
    #expect(first.points.map(\.geometryFeatures) == again.points.map(\.geometryFeatures))
    #expect(first.points.count > 64 * 64 / 4 && first.points.count < 64 * 64 * 7 / 10)
    // Breaking only the renderer's point size would still leave aligned rows.
    // The immutable source geometry itself must have many distinct coordinates.
    let xPositions = Set(first.points.map { Int(($0.positionDepthSeed.x * 10_000).rounded()) })
    #expect(xPositions.count > 64 * 8)
    #expect(first.points.allSatisfy {
        abs($0.positionDepthSeed.x) <= 1.061 && abs($0.positionDepthSeed.y) <= 1.061 &&
        (0.20...0.80).contains($0.positionDepthSeed.z) &&
        (0.4...2.6).contains($0.geometryFeatures.y) && $0.geometryFeatures.w == 0.55
    })
    #expect(first.points.allSatisfy {
        let displacement = SIMD2($0.scatter.x - $0.positionDepthSeed.x, $0.scatter.y - $0.positionDepthSeed.y)
        return sqrt(displacement.x * displacement.x + displacement.y * displacement.y) <= 0.14001 && abs($0.scatter.z) <= 0.13001
    })
}

@Test func abstractCoverCloudSuppressesFineLetterTextureButRetainsLargeColorComposition() async throws {
    let stripes = coverPixels(128, 128) { x, _ in
        let value: UInt8 = (x / 3).isMultiple(of: 2) ? 0 : 255
        return [value, value, value, 255]
    }
    let faithful = try await ArtworkCloudField.make(stripes, grid: 64)
    let abstract = try await ArtworkCloudField.make(stripes, grid: 64, abstraction: 0.55, seed: 12)
    func contrast(_ cells: [ArtworkCloudField.Cell]) -> Float {
        // Exclude the outer filter boundary, where its footprint is truncated.
        let values = (8..<56).map { cells[32 * 64 + $0].linearColor.x }
        return (values.max() ?? 0) - (values.min() ?? 0)
    }
    #expect(contrast(abstract.cells) < contrast(faithful.cells) * 0.40)
    let blocks = coverPixels(128, 128) { x, _ in x < 64 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
    let pigments = try await ArtworkCloudField.make(blocks, grid: 64, abstraction: 0.55, seed: 12)
    let left = pigments.cells[32 * 64 + 10].linearColor
    let right = pigments.cells[32 * 64 + 53].linearColor
    #expect(left.x > 0.85 && left.z < 0.15)
    #expect(right.z > 0.85 && right.x < 0.15)
}

@Test func abstractCoverCloudDensityAndParticleScaleAreSpatiallyCoherent() async throws {
    let image = coverPixels(64, 64) { _, _ in [160, 100, 60, 255] }
    let field = try await ArtworkCloudField.make(image, grid: 64, abstraction: 0.8, seed: 12)
    let weights = field.cells.map(\.densityWeight)
    #expect(try #require(weights.max()) - #require(weights.min()) > 0.25)
    var neighboringDifferences: [Float] = []
    for y in 8..<56 { for x in 8..<55 {
        neighboringDifferences.append(abs(weights[y * 64 + x] - weights[y * 64 + x + 1]))
    } }
    #expect(neighboringDifferences.reduce(0, +) / Float(neighboringDifferences.count) < 0.035)
    let scales = field.cells.map(\.footprintScale)
    #expect(try #require(scales.max()) - #require(scales.min()) > 0.25)
    #expect(field.cells.allSatisfy { $0.flow.x.isFinite && $0.flow.y.isFinite && $0.depth.isFinite })
}

@Test func abstractCoverCloudKeepsTransparentColorIsolationAndSparseCoverage() async throws {
    let transparent = coverPixels(32, 32) { x, _ in x.isMultiple(of: 2) ? [128, 0, 0, 128] : [0, 255, 0, 0] }
    let samples = try await CloudSampler.sample(transparent, density: 32, seed: 12, abstraction: 0.8)
    #expect(samples.points.allSatisfy {
        abs($0.colorLuminance.x - 1) < 0.0001 && $0.colorLuminance.y == 0 && $0.colorLuminance.z == 0 &&
        $0.scatter.w > 0 && $0.scatter.w <= Float(128) / 255
    })
    let sparse = coverPixels(8, 8) { x, y in x == 3 && y == 3 ? [255, 0, 0, 255] : [0, 255, 0, 0] }
    let single = try await CloudSampler.sample(sparse, density: 8, seed: 12, abstraction: 1)
    #expect(single.points.count == 1)
    #expect(single.points[0].colorLuminance.x > 0.99 && single.points[0].colorLuminance.y == 0)
}

@Test func abstractCoverCloudClampsParametersWithoutCorruptingSamples() async throws {
    let image = coverPixels(16, 16) { _, _ in [160, 100, 60, 255] }
    let maximum = try await CloudSampler.sample(image, density: 16, seed: 12, abstraction: 1)
    let clamped = try await CloudSampler.sample(image, density: 16, seed: 12, abstraction: 2)
    let faithful = try await CloudSampler.sample(image, density: 16, seed: 12)
    let nonfinite = try await CloudSampler.sample(image, density: 16, seed: 12, abstraction: .nan)
    #expect(maximum.points.map(\.positionDepthSeed) == clamped.points.map(\.positionDepthSeed))
    #expect(faithful.points.map(\.positionDepthSeed) == nonfinite.points.map(\.positionDepthSeed))
    #expect(MemoryLayout<CloudPoint>.stride == 64)
}

@Test func abstractCoverCloudQualityTiersKeepTheSamePigmentComposition() async throws {
    let image = coverPixels(48, 48) { x, y in [UInt8(x * 5), UInt8(y * 5), 90, 255] }
    var means: [SIMD3<Float>] = [], retention: [Float] = []
    for density in [96, 160, 224] {
        let cloud = try await CloudSampler.sample(image, density: density, seed: 12, abstraction: 0.55)
        let sum = cloud.points.reduce(SIMD3<Float>.zero) { $0 + SIMD3($1.colorLuminance.x, $1.colorLuminance.y, $1.colorLuminance.z) }
        means.append(sum / Float(cloud.points.count))
        retention.append(Float(cloud.points.count) / Float(density * density))
        #expect(cloud.points.allSatisfy { point in
            [point.colorLuminance.x, point.colorLuminance.y, point.colorLuminance.z, point.scatter.w].allSatisfy { $0.isFinite && (0...1).contains($0) }
        })
    }
    #expect(abs(means[0].x - means[2].x) < 0.025 && abs(means[0].y - means[2].y) < 0.025)
    #expect(abs(means[0].z - means[2].z) < 0.01)
    #expect(try #require(retention.max()) - #require(retention.min()) < 0.035)
}
