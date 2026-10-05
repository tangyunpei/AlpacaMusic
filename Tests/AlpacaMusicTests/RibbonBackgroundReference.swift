import CoreGraphics
import Foundation
import Metal
import simd
@testable import AlpacaMusic

/// A test-only capture of the unchanged production background functions. This
/// does not approximate the shader's gradient or alter the production pipeline.
@MainActor enum RibbonBackgroundReference {
    private(set) static var pixels: [UInt8] = []
    static let linear: [Double] = (0...255).map { value in
        let encoded = Double(value) / 255
        return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    static func load(size: CGSize) throws {
        let width = Int(size.width), height = Int(size.height)
        if pixels.count == width * height * 4 { return }
        guard let device = MTLCreateSystemDefaultDevice() else { throw ParticleFieldOffscreen.Failure.missingDevice }
        guard let queue = device.makeCommandQueue() else { throw ParticleFieldOffscreen.Failure.missingQueue }
        let library = try device.makeLibrary(source: ParticleFieldPipeline.shaderSource(), options: MTLCompileOptions())
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fieldBackgroundVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "fieldBackgroundFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
            width: width, height: height, mipmapped: false)
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = .renderTarget
        guard let target = device.makeTexture(descriptor: textureDescriptor) else { throw ParticleFieldOffscreen.Failure.texture }
        guard let command = queue.makeCommandBuffer() else { throw ParticleFieldOffscreen.Failure.commandBuffer }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw ParticleFieldOffscreen.Failure.encoder }
        var uniforms = ParticleFieldUniforms(projection: matrix_identity_float4x4, modelView: matrix_identity_float4x4,
            timing: SIMD4(0, 1, 120, 0), viewport: .zero, audio: .zero, bands: .zero,
            orbitEnergy: .zero, orbitPulse: .zero, identity: .zero)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ParticleFieldUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw ParticleFieldOffscreen.Failure.command(command.error?.localizedDescription ?? "Background command did not complete") }
        var bytes = Array(repeating: UInt8(0), count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                target.getBytes(base, bytesPerRow: width * 4,
                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ParticleFieldOffscreen.Failure.image
        }
        pixels = try TemporalDesignExport.rgba(image)
    }
}
