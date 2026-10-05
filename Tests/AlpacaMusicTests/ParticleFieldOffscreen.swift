import CoreGraphics
import Foundation
import Metal
@testable import AlpacaMusic

/// Executes the same GPU pipeline as the native particle view. A single cached
/// pipeline avoids compiling Metal for every movie frame; the target texture is
/// reused until the requested dimensions change. No window or audio device opens.
@MainActor final class ParticleFieldOffscreen {
    enum Failure: Error {
        case missingDevice, missingQueue, invalidSize, texture, commandBuffer, encoder, image
        case command(String)
    }

    private static var cached: ParticleFieldOffscreen?
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: ParticleFieldPipeline
    private var target: (any MTLTexture)?

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.missingDevice }
        guard let queue = device.makeCommandQueue() else { throw Failure.missingQueue }
        self.device = device
        self.queue = queue
        self.pipeline = try ParticleFieldPipeline(device: device, pixelFormat: .bgra8Unorm_srgb)
    }

    static func image(mode: VisualizationMode, time: Double, audio: AudioLevels, orbitRhythm: OrbitRhythmFrame = .zero,
                      size: CGSize, seed: UInt64, glow: Bool, lowPower: Bool) throws -> CGImage {
        if cached == nil { cached = try ParticleFieldOffscreen() }
        guard let renderer = cached else { throw Failure.missingDevice }
        return try renderer.render(mode: mode, time: time, audio: audio, orbitRhythm: orbitRhythm, size: size,
                                   seed: seed, glow: glow, lowPower: lowPower)
    }

    private func render(mode: VisualizationMode, time: Double, audio: AudioLevels, orbitRhythm: OrbitRhythmFrame = .zero,
                        size: CGSize, seed: UInt64, glow: Bool, lowPower: Bool) throws -> CGImage {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1, size.width <= 8_192, size.height <= 8_192 else { throw Failure.invalidSize }
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        if target?.width != width || target?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                                      width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .renderTarget
            target = device.makeTexture(descriptor: descriptor)
        }
        guard let target else { throw Failure.texture }
        guard let buffer = queue.makeCommandBuffer() else { throw Failure.commandBuffer }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.encoder }
        pipeline.encode(into: encoder, size: CGSize(width: width, height: height), mode: mode,
                        time: Float(time.isFinite ? max(0, time) : 0), audio: audio, orbitRhythm: orbitRhythm, seed: seed,
                        glow: glow, lowPower: lowPower)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.status == .completed else { throw Failure.command(buffer.error?.localizedDescription ?? "GPU command did not complete") }
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                target.getBytes(base, bytesPerRow: rowBytes,
                                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: rowBytes, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.image }
        return image
    }
}
