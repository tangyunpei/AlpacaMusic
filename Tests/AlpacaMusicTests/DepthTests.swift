import Foundation
import MetalKit
import QuartzCore
import simd
import Testing
@testable import AlpacaMusic

private func pixelImage(_ width: Int, _ height: Int, sample: (Int, Int) -> [UInt8]) -> ArtworkPixels {
    var data: [UInt8] = []; data.reserveCapacity(width * height * 4)
    for y in 0..<height { for x in 0..<width { data.append(contentsOf: sample(x, y)) } }
    return ArtworkPixels(width: width, height: height, rgba: data)
}

@Test func depthPreservesTonalOrdering() async throws {
    let image = pixelImage(16, 16) { x, _ in let value = UInt8(x * 17); return [value, value, value, 255] }
    let depth = try await LuminanceDepthProvider().compute(image, grid: 16)
    #expect(depth.count == 256)
    #expect(depth[0] < 0.01 && depth[15] > 0.99)
    for x in 1..<16 { #expect(depth[x] > depth[x - 1]) }
    #expect(depth.allSatisfy { $0.isFinite && (0...1).contains($0) })
}

@Test func rec709WeightsGreenAboveRedAboveBlue() async throws {
    let colors: [[UInt8]] = [[0, 0, 255, 255], [255, 0, 0, 255], [0, 255, 0, 255]]
    let image = pixelImage(30, 10) { x, _ in colors[x / 10] }
    let depth = try await LuminanceDepthProvider().compute(image, grid: 30)
    #expect(depth[5] < depth[15] && depth[15] < depth[25])
}

@Test func transparentPixelsDoNotDistortDepth() async throws {
    let isolated = pixelImage(9, 9) { x, y in x == 4 && y == 4 ? [80, 80, 80, 255] : [255, 255, 255, 0] }
    let depth = try await LuminanceDepthProvider().compute(isolated, grid: 9)
    #expect(depth.allSatisfy { $0 == 0.5 })
    let empty = try await LuminanceDepthProvider().compute(pixelImage(4, 4) { _, _ in [0, 0, 0, 0] }, grid: 4)
    #expect(empty.allSatisfy { $0 == 0.5 })
}

@Test func percentileNormalizationRejectsIsolatedOutliers() async throws {
    let image = pixelImage(40, 40) { x, y in
        let value = x == 0 && y == 0 ? UInt8(255) : UInt8(70 + x * 70 / 39)
        return [value, value, value, 255]
    }
    let depth = try await LuminanceDepthProvider().compute(image, grid: 40)
    #expect(depth[20 * 40] < 0.03)
    #expect(depth[20 * 40 + 39] > 0.97)
}

@Test func gammaControlsReliefWithoutMovingEndpoints() async throws {
    let image = pixelImage(12, 12) { x, _ in let value = UInt8(x * 23); return [value, value, value, 255] }
    let linear = try await LuminanceDepthProvider().compute(image, grid: 12)
    let gamma = try await LuminanceDepthProvider(gamma: 2).compute(image, grid: 12)
    #expect(abs(gamma[6] - linear[6] * linear[6]) < 0.00001)
    #expect(gamma[11] > 0.99)
}

@Test func depthSamplingCanBeCancelled() async {
    let image = pixelImage(256, 256) { _, _ in [100, 120, 80, 255] }
    let task = Task { try await LuminanceDepthProvider().compute(image, grid: 224) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func malformedPixelBuffersAreRejected() async {
    await #expect(throws: DepthError.self) { try await LuminanceDepthProvider().compute(ArtworkPixels(width: 1, height: 1, rgba: []), grid: 1) }
    await #expect(throws: DepthError.self) { try await LuminanceDepthProvider(gamma: 0).compute(pixelImage(1, 1) { _, _ in [0, 0, 0, 255] }, grid: 1) }
}

private struct FlatDepthProvider: DepthProvider {
    func compute(_ image: ArtworkPixels, grid: Int) async throws -> [Float] { [Float](repeating: 0.25, count: grid * grid) }
}

@Test func samplerUsesInjectedDepthSkipsAlphaAndUnpremultipliesColor() async throws {
    let image = pixelImage(3, 3) { x, y in x == 0 && y == 0 ? [128, 0, 0, 128] : [0, 0, 0, 0] }
    let samples = try await CloudSampler.sample(image, density: 3, seed: 42, provider: FlatDepthProvider())
    #expect(samples.points.count == 1)
    let point = try #require(samples.points.first)
    #expect(point.positionDepthSeed.x == -1 && point.positionDepthSeed.y == 1)
    #expect(point.positionDepthSeed.z == 0.25)
    #expect(point.colorLuminance.x > 0.99 && point.colorLuminance.y == 0)
    #expect(abs(point.scatter.w - Float(128) / 255) < 0.00001)
    #expect(MemoryLayout<CloudPoint>.stride == 64)
}

@Test func visualizationAudioDoesNotFabricateUnavailableOrPausedSpectrum() {
    let unavailable = VisualizationAudio(AudioLevels(energy: 1, beat: 1, spectrum: [1, 1], available: false))
    #expect(!unavailable.available && unavailable.energy == 0 && unavailable.beat == 0)
    #expect(unavailable.spectrum.isEmpty && unavailable.band(0.5) == 0)
    let paused = VisualizationAudio(AudioLevels(energy: 0.7, beat: 0.8, spectrum: [0.5], available: true), playing: false)
    #expect(!paused.available && paused.band(0) == 0 && paused.energy == 0)
    let real = VisualizationAudio(AudioLevels(energy: .nan, beat: 3, spectrum: [-1, 0.5, .infinity, 1], available: true))
    #expect(real.available && real.energy == 0 && real.beat == 1)
    #expect(real.spectrum == [0, 0.5, 0, 1])
    #expect(real.band(-1) == 0 && real.band(2) == 1)
    #expect(abs(real.band(1.0 / 6) - 0.25) < 0.00001)
}

@Test func pointCloudTransitionStaysNearItsAlbumAndPreservesAlpha() async throws {
    let image = pixelImage(12, 12) { _, _ in [60, 90, 40, 128] }
    let samples = try await CloudSampler.sample(image, density: 12, seed: 42)
    #expect(samples.points.count == 144)
    #expect(samples.points.allSatisfy {
        abs($0.scatter.x) <= 1.72 && abs($0.scatter.y) <= 1.72 && abs($0.scatter.z) <= 0.85 &&
        abs($0.scatter.w - Float(128) / 255) < 0.00001
    })
}

@Test func proceduralArtworkAndScatterAreDeterministic() async throws {
    let track = Track(id: "test", title: "Morning", artist: "Alpaca", album: "Quiet", duration: 20, source: .demo)
    let first = Artwork.placeholder(for: track), second = Artwork.placeholder(for: track)
    #expect(first.rgba == second.rgba)
    let samplesA = try await CloudSampler.sample(first, density: 8, seed: Artwork.seed(for: track))
    let samplesB = try await CloudSampler.sample(first, density: 8, seed: Artwork.seed(for: track))
    #expect(samplesA.points.map(\.scatter) == samplesB.points.map(\.scatter))
    #expect(Artwork.seed(for: track) != Artwork.seed(for: nil))
}

@Test @MainActor func nativeMetalShaderCompilesIntoBothBlendPipelines() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), device: device)
    let renderer = try MetalRenderer(view: view, device: device, signal: { AudioLevels() })
    #expect(view.colorPixelFormat == .bgra8Unorm_srgb)
    #expect(view.delegate === renderer)
    renderer.stop()
    #expect(view.delegate == nil)
}

@Test @MainActor func gpuMotionKeepsBothNonContinuousAxesBitStable() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let probe = """
    kernel void positionProbe(const device CloudPoint *points [[buffer(0)]],
                              constant CloudUniforms &u [[buffer(1)]],
                              device float4 *output [[buffer(2)]], uint id [[thread_position_in_grid]]) {
        output[id] = float4(cloudPosition(points[id], u), 1.0);
    }
    """
    let library = try device.makeLibrary(source: MetalRenderer.shaderSource() + probe, options: nil)
    let function = try #require(library.makeFunction(name: "positionProbe"))
    let pipeline = try device.makeComputePipelineState(function: function)
    let point = CloudPoint(positionDepthSeed: SIMD4(0.23, -0.31, 0.77, 0.38), colorLuminance: SIMD4(1, 1, 1, 1), scatter: SIMD4(2, 2, -1, 0))
    let buffer = try [point].withUnsafeBytes { try #require(device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)) }
    func position(time: Float, scheme: Float, invert: Float = 0, animated: Bool = true) throws -> SIMD4<Float> {
        let output = try #require(device.makeBuffer(length: 16, options: .storageModeShared))
        var uniforms = CloudUniforms(projection: matrix_identity_float4x4, modelView: matrix_identity_float4x4,
            motion: SIMD4(time, 0.6, 0, 1), shape: SIMD4(0.35, animated ? 0.08 : 0, animated ? 0.012 : 0, 1.8),
            wave: SIMD4(4, 3.5, invert, scheme), behavior: SIMD4(0, 1, 0, 1), viewport: SIMD4(900, 0, 0, 0))
        let command = try #require(queue.makeCommandBuffer()), encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline); encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<CloudUniforms>.stride, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed)
        return output.contents().assumingMemoryBound(to: SIMD4<Float>.self).pointee
    }
    let a0 = try position(time: 0.4, scheme: 0), a1 = try position(time: 1.8, scheme: 0)
    #expect(a0.x.bitPattern == a1.x.bitPattern && a0.z.bitPattern == a1.z.bitPattern)
    #expect(abs(a0.y - a1.y) > 0.001)
    let b0 = try position(time: 0.4, scheme: 1), b1 = try position(time: 1.8, scheme: 1)
    #expect(b0.x.bitPattern == b1.x.bitPattern && b0.y.bitPattern == b1.y.bitPattern)
    #expect(abs(b0.z - b1.z) > 0.001)
    let near = try position(time: 0, scheme: 0, animated: false), inverted = try position(time: 0, scheme: 0, invert: 1, animated: false)
    #expect(abs(near.z + inverted.z) < 0.00001)
    #expect(near.z > 0.15 && inverted.z < -0.15)
    #expect(MemoryLayout<CloudUniforms>.stride == 208)
}

@Test @MainActor func gpuCoverMotionProtectsDetailsAndRemainsBoundedAtMaximumSettings() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let probe = """
    kernel void coverMotionProbe(const device CloudPoint *points [[buffer(0)]],
                                 constant CloudUniforms &u [[buffer(1)]],
                                 device float4 *output [[buffer(2)]], uint id [[thread_position_in_grid]]) {
        output[id] = float4(cloudPosition(points[id], u), 1.0);
    }
    """
    let library = try device.makeLibrary(source: MetalRenderer.shaderSource() + probe, options: nil)
    let pipeline = try device.makeComputePipelineState(function: try #require(library.makeFunction(name: "coverMotionProbe")))
    let points = [-1.0 as Float, 0, 1].flatMap { x in
        [-1.0 as Float, 0, 1].flatMap { y in
            [0.0 as Float, 0.5, 1].flatMap { depth in
                [0.0 as Float, 1].map { detail in
                    CloudPoint(positionDepthSeed: SIMD4(x, y, depth, 0.73),
                               colorLuminance: SIMD4(0.2, 0.5, 0.8, 0.5), scatter: SIMD4(9, 9, 9, 1),
                               geometryFeatures: SIMD4(detail, 1, 0, 0))
                }
            }
        }
    }
    let pointBuffer = try points.withUnsafeBytes { try #require(device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)) }
    let output = try #require(device.makeBuffer(length: points.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
    func positions(time: Float, scheme: Float, bounce: Float, idle: Float, beat: Float, enabled: Float) throws -> [SIMD4<Float>] {
        var uniforms = CloudUniforms(projection: matrix_identity_float4x4, modelView: matrix_identity_float4x4,
            motion: SIMD4(time, 1, beat, 1), shape: SIMD4(1, bounce, idle, 4),
            wave: SIMD4(10, 8, 0, scheme), behavior: SIMD4(1, enabled, 0, 1), viewport: SIMD4(900, 0, 1, 3))
        let command = try #require(queue.makeCommandBuffer()), encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline); encoder.setBuffer(pointBuffer, offset: 0, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<CloudUniforms>.stride, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.dispatchThreads(MTLSize(width: points.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(points.count, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed)
        return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: points.count))
    }
    let staticPositions = try positions(time: 0, scheme: 0, bounce: 0, idle: 0, beat: 0, enabled: 0)
    for settings: (bounce: Float, idle: Float) in [(0.16, 0.012), (0.4, 0.05)] {
        for scheme: Float in [0, 1] {
            for frame in 0..<24 {
                let animated = try positions(time: Float(frame) * 0.31, scheme: scheme, bounce: settings.bounce, idle: settings.idle, beat: 1, enabled: 1)
                var maximum: Float = 0
                for index in points.indices {
                    let difference = animated[index] - staticPositions[index]
                    maximum = max(maximum, simd_length(SIMD3(difference.x, difference.y, difference.z)))
                    #expect(animated[index].x.isFinite && animated[index].y.isFinite && animated[index].z.isFinite)
                }
                // Includes the continuous wave, 0.5% coherent scale pulse and
                // depth accent; this is measured from actual GPU positions.
                #expect(maximum <= 0.051)
            }
        }
    }
    let pulse = try positions(time: 0.4, scheme: 0, bounce: 0.4, idle: 0.05, beat: 1, enabled: 1)
    // The adjacent center samples differ only in their detail-protection flag.
    let centerFlat = 26, centerProtected = 27
    let flatShift = simd_length(pulse[centerFlat] - staticPositions[centerFlat])
    let protectedShift = simd_length(pulse[centerProtected] - staticPositions[centerProtected])
    #expect(flatShift > 0.001 && protectedShift < flatShift * 0.6)
    let reducedA = try positions(time: 0.4, scheme: 0, bounce: 0.4, idle: 0.05, beat: 1, enabled: 0)
    let reducedB = try positions(time: 4.8, scheme: 1, bounce: 0.4, idle: 0.05, beat: 1, enabled: 0)
    #expect(reducedA == staticPositions && reducedB == staticPositions)
}

@MainActor
private final class OffscreenCloud {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let pipeline: any MTLRenderPipelineState
    let glowPipeline: any MTLRenderPipelineState
    let texture: any MTLTexture
    let points: any MTLBuffer
    let pointCount: Int
    var uniforms: CloudUniforms

    init(samples: CloudSamples, width: Int = 1920, height: Int = 1080) throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        let library = try device.makeLibrary(source: MetalRenderer.shaderSource(), options: nil)
        let currentDevice = device
        func makePipeline(additive: Bool) throws -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "cloudVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "cloudFragment")
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm_srgb; attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one; attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try currentDevice.makeRenderPipelineState(descriptor: descriptor)
        }
        pipeline = try makePipeline(additive: false)
        glowPipeline = try makePipeline(additive: true)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        textureDescriptor.usage = [.renderTarget]; textureDescriptor.storageMode = .shared
        texture = try #require(device.makeTexture(descriptor: textureDescriptor))
        points = try samples.points.withUnsafeBytes { try #require(currentDevice.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)) }
        pointCount = samples.points.count
        let tanHalf = tan(Float.pi * 42 / 360), yScale: Float = 1 / tanHalf, aspect = Float(width) / Float(height)
        let near: Float = 0.05, far: Float = 60
        let projection = simd_float4x4(columns: (SIMD4(yScale / aspect, 0, 0, 0), SIMD4(0, yScale, 0, 0), SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)))
        var translation = matrix_identity_float4x4; translation.columns.3.z = -1 / (tanHalf * 0.7)
        uniforms = CloudUniforms(projection: projection, modelView: translation,
            motion: SIMD4(0, 0.6, 0.1, 1), shape: SIMD4(0.35, 0.16, 0.012, 1.8),
            wave: SIMD4(4, 3.5, 0, 0), behavior: SIMD4(1, 1, 0, 1), viewport: SIMD4(Float(height) / (2 * tanHalf), 0, 0, 0))
    }

    func frame(time: Float) throws -> (cpuMS: Double, gpuMS: Double) {
        let start = CACurrentMediaTime()
        uniforms.motion.x = time
        let command = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setVertexBuffer(points, offset: 0, index: 0)
        // Match production: faint additive halo first, unmodified color core last.
        encoder.setRenderPipelineState(glowPipeline); uniforms.viewport.y = 1
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CloudUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCount)
        encoder.setRenderPipelineState(pipeline); uniforms.viewport.y = 0
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CloudUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCount)
        encoder.endEncoding(); command.commit()
        let cpu = (CACurrentMediaTime() - start) * 1000
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        return (cpu, (command.gpuEndTime - command.gpuStartTime) * 1000)
    }

    func nonTransparentPixelCount() -> Int {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
        return stride(from: 3, to: bytes.count, by: 4).count { bytes[$0] > 0 }
    }
}

@Test @MainActor func metalDrawsRealPointGeometryAt1080p() async throws {
    let artwork = Artwork.placeholder(for: nil)
    let samples = try await CloudSampler.sample(artwork, density: 160, seed: 42)
    let renderer = try OffscreenCloud(samples: samples)
    _ = try renderer.frame(time: 1)
    #expect(renderer.pointCount == 25600)
    #expect(renderer.nonTransparentPixelCount() > 50000)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["ALPACA_GPU_BENCHMARK"] == "1"))
@MainActor func oneMinuteOffscreenGPUFrameBudget() async throws {
    let samples = try await CloudSampler.sample(Artwork.placeholder(for: nil), density: 160, seed: 42)
    let renderer = try OffscreenCloud(samples: samples)
    var cpu: [Double] = [], gpu: [Double] = []
    let start = CACurrentMediaTime()
    for frame in 0..<3600 {
        let target = start + Double(frame) / 60
        let wait = target - CACurrentMediaTime()
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        let timing = try renderer.frame(time: Float(frame) / 60)
        cpu.append(timing.cpuMS); gpu.append(timing.gpuMS)
    }
    cpu.sort(); gpu.sort()
    let report: [String: Any] = ["device": renderer.device.name, "mode": "offscreen Metal, 1920x1080, 160x160 points, glow on", "frames": 3600,
        "elapsedSeconds": CACurrentMediaTime() - start, "cpuEncodeP95MS": cpu[Int(Double(cpu.count - 1) * 0.95)],
        "gpuP95MS": gpu[Int(Double(gpu.count - 1) * 0.95)], "gpuMaxMS": gpu.last ?? 0,
        "scope": "Local offscreen GPU budget only; not a three-minute displayed-frame or reference-hardware acceptance claim."]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: "/private/tmp/alpacamusic-native-gpu-report.json"))
    print(String(decoding: data, as: UTF8.self))
    #expect(renderer.nonTransparentPixelCount() > 50000)
}
