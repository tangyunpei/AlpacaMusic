import Foundation
import Metal
import simd

struct ParticleFieldMotionFrame: Sendable {
    var time: Float
    var audio: AudioLevels
    var orbitRhythm: OrbitRhythmFrame = .zero
}

/// A time-integrated pose, independent of display rate. Audio envelopes change
/// displacement and light, never the phase or speed of an already-moving field.
struct ParticleFieldMotionClock: Sendable {
    private var previousTime: TimeInterval?
    private var elapsed: Double = 0
    private var smoothed = AudioLevels()
    private var hasSignalSnapshot = false
    private var rhythmClock = OrbitRhythmClock()
    private var rhythmFrame = OrbitRhythmFrame.zero

    mutating func resetTimestamp() { previousTime = nil }
    mutating func reset() { previousTime = nil; elapsed = 0; smoothed = AudioLevels(); hasSignalSnapshot = false; rhythmClock.reset(); rhythmFrame = .zero }

    mutating func frame(at date: TimeInterval, animated: Bool, levels: AudioLevels,
                        captureStaticSignal: Bool = false) -> ParticleFieldMotionFrame {
        guard animated, date.isFinite else {
            previousTime = nil
            // A view opened while Reduce Motion is already enabled may capture
            // one genuine signal pose. Existing paused/reduced poses stay put.
            if date.isFinite, captureStaticSignal {
                if !levels.available {
                    clearMeasuredSignal()
                    smoothed.available = false
                    hasSignalSnapshot = false
                    rhythmClock.reset(); rhythmFrame = .zero
                } else {
                    let clean = Self.cleaned(levels)
                    if !hasSignalSnapshot || formatChanged(to: clean) {
                        smoothed = clean
                        rhythmFrame = rhythmClock.step(dt: 0, levels: clean, resetInput: true)
                        hasSignalSnapshot = true
                    }
                }
            }
            return ParticleFieldMotionFrame(time: Float(elapsed), audio: smoothed, orbitRhythm: rhythmFrame)
        }
        let dt = previousTime.map { min(0.15, max(0, date - $0)) } ?? 0
        previousTime = date
        elapsed += dt
        func value(_ value: Float) -> Float { levels.available && value.isFinite ? min(1, max(0, value)) : 0 }
        func follow(_ current: Float, _ target: Float, attack: Double, release: Double) -> Float {
            current + (target - current) * Float(1 - exp(-dt / (target > current ? attack : release)))
        }
        smoothed.energy = follow(smoothed.energy, value(levels.energy), attack: 0.12, release: 0.42)
        smoothed.beat = follow(smoothed.beat, value(levels.beat), attack: 0.07, release: 0.32)
        smoothed.amplitude = follow(smoothed.amplitude, value(levels.amplitude), attack: 0.10, release: 0.38)
        smoothed.bass = follow(smoothed.bass, value(levels.bass), attack: 0.13, release: 0.46)
        smoothed.mid = follow(smoothed.mid, value(levels.mid), attack: 0.10, release: 0.34)
        smoothed.treble = follow(smoothed.treble, value(levels.treble), attack: 0.09, release: 0.27)
        if levels.available {
            let clean = Self.cleaned(levels)
            let formatChanged = formatChanged(to: clean)
            if dt > 0 || !hasSignalSnapshot || formatChanged {
                rhythmFrame = rhythmClock.step(dt: dt, levels: clean)
            }
            let blend = Float(1 - exp(-dt * 36))
            func trace(_ current: [Float], _ target: [Float]) -> [Float] {
                guard !formatChanged, current.count == target.count else { return target }
                return zip(current, target).map { $0 + ($1 - $0) * blend }
            }
            smoothed.bassWaveform = trace(smoothed.bassWaveform, clean.bassWaveform)
            smoothed.midWaveform = trace(smoothed.midWaveform, clean.midWaveform)
            smoothed.trebleWaveform = trace(smoothed.trebleWaveform, clean.trebleWaveform)
            smoothed.waveform = trace(smoothed.waveform, clean.waveform)
            smoothed.spectrum = trace(smoothed.spectrum, clean.spectrum)
            smoothed.sampleRate = clean.sampleRate
            smoothed.spectrumBinWidth = clean.spectrumBinWidth
            smoothed.waveformDuration = clean.waveformDuration
            hasSignalSnapshot = true
        } else {
            // Render envelopes may decay, but measured PCM must disappear at
            // once when a playing source no longer supplies audio analysis.
            clearMeasuredSignal()
            if dt > 0 { rhythmFrame = rhythmClock.step(dt: dt, levels: levels) }
            hasSignalSnapshot = false
        }
        // These are render envelopes, not a claimed input signal. On source loss
        // only the last genuine response decays; an unavailable initial source
        // stays at zero. UI availability always comes from the raw audio reader.
        let remaining = max(max(smoothed.energy, smoothed.beat), max(smoothed.amplitude,
                            max(smoothed.bass, max(smoothed.mid, smoothed.treble))))
        smoothed.available = levels.available || remaining > 0.0001
        if !smoothed.available { smoothed = AudioLevels() }
        return ParticleFieldMotionFrame(time: Float(elapsed), audio: smoothed, orbitRhythm: rhythmFrame)
    }

    private func formatChanged(to clean: AudioLevels) -> Bool {
        smoothed.sampleRate != clean.sampleRate || smoothed.spectrumBinWidth != clean.spectrumBinWidth
            || smoothed.waveformDuration != clean.waveformDuration
            || smoothed.bassWaveform.count != clean.bassWaveform.count
            || smoothed.midWaveform.count != clean.midWaveform.count
            || smoothed.trebleWaveform.count != clean.trebleWaveform.count
    }

    private mutating func clearMeasuredSignal() {
        smoothed.bassWaveform = []; smoothed.midWaveform = []; smoothed.trebleWaveform = []
        smoothed.waveform = []; smoothed.spectrum = []
        smoothed.sampleRate = 0; smoothed.spectrumBinWidth = 0; smoothed.waveformDuration = 0
    }

    private static func cleaned(_ levels: AudioLevels) -> AudioLevels {
        guard levels.available else { return AudioLevels() }
        func unit(_ value: Float) -> Float { value.isFinite ? min(1, max(0, value)) : 0 }
        func signed(_ samples: [Float]) -> [Float] { samples.map { $0.isFinite ? min(1, max(-1, $0)) : 0 } }
        var result = levels
        result.energy = unit(levels.energy); result.beat = unit(levels.beat); result.amplitude = unit(levels.amplitude)
        result.bass = unit(levels.bass); result.mid = unit(levels.mid); result.treble = unit(levels.treble)
        result.bassWaveform = signed(levels.bassWaveform); result.midWaveform = signed(levels.midWaveform)
        result.trebleWaveform = signed(levels.trebleWaveform); result.waveform = signed(levels.waveform)
        result.spectrum = levels.spectrum.map(unit)
        result.sampleRate = levels.sampleRate.isFinite ? max(0, levels.sampleRate) : 0
        result.spectrumBinWidth = levels.spectrumBinWidth.isFinite ? max(0, levels.spectrumBinWidth) : 0
        result.waveformDuration = levels.waveformDuration.isFinite ? max(0, levels.waveformDuration) : 0
        return result
    }
}

/// This layout is mirrored exactly in Resources/ParticleField.metal.
struct ParticleFieldUniforms {
    var projection: simd_float4x4
    var modelView: simd_float4x4
    var timing: SIMD4<Float>       // time, field kind, grid width, rendering pass
    var viewport: SIMD4<Float>     // drawable width, height, projection scale, low power
    var audio: SIMD4<Float>        // energy, beat, full-range amplitude, available
    var bands: SIMD4<Float>        // bass, mid, treble, reserved
    var orbitEnergy: SIMD4<Float>  // measured per-band envelope for orbit/ribbons, reserved
    var orbitPulse: SIMD4<Float>   // measured onset attack/decay for orbit/ribbons, reserved
    var identity: SIMD4<UInt32>    // artwork seed, base points, PCM samples, fine sections
}

/// Live MTKView and offscreen tests use exactly this encoder and shader. It owns
/// immutable pipeline states only; particle positions are generated on the GPU.
@MainActor
final class ParticleFieldPipeline {
    private struct CacheKey: Hashable { var device: UInt64; var pixelFormat: UInt }
    private struct States {
        var background: any MTLRenderPipelineState
        var core: any MTLRenderPipelineState
        var halo: any MTLRenderPipelineState
    }
    private static var cache: [CacheKey: States] = [:]
    private let states: States
    static let regularPointCount = 14_400
    static let lowPowerPointCount = 8_100
    static let scopeSampleCount = 1_024

    /// Each packet stays at Metal's 4 KiB inline-data limit. setVertexBytes
    /// copies it into encoder-owned storage, so no mutable buffer can be reused
    /// while another command buffer is still reading it.
    static func scopeWaveform(_ samples: [Float], available: Bool) -> [Float] {
        guard available, !samples.isEmpty else { return Array(repeating: 0, count: scopeSampleCount) }
        let source = samples.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
        if source.count == scopeSampleCount { return source }
        if source.count > scopeSampleCount {
            // Keep both extrema of every input bucket in temporal order. The
            // analyzer's usual 1,024 samples never take this reduction path.
            return (0..<(scopeSampleCount / 2)).flatMap { bucket -> [Float] in
                let start = bucket * source.count / (scopeSampleCount / 2)
                let end = (bucket + 1) * source.count / (scopeSampleCount / 2)
                var low = start, high = start
                for index in start..<end {
                    if source[index] < source[low] { low = index }
                    if source[index] > source[high] { high = index }
                }
                return [source[min(low, high)], source[max(low, high)]]
            }
        }
        return (0..<scopeSampleCount).map { index in
            let position = Double(index) * Double(source.count - 1) / Double(scopeSampleCount - 1)
            let lower = Int(position), upper = min(source.count - 1, lower + 1)
            return source[lower] + (source[upper] - source[lower]) * Float(position - Double(lower))
        }
    }

    init(device: any MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb) throws {
        let key = CacheKey(device: device.registryID, pixelFormat: pixelFormat.rawValue)
        if let cached = Self.cache[key] { states = cached; return }
        let library = try device.makeLibrary(source: Self.shaderSource(), options: MTLCompileOptions())
        guard let vertex = library.makeFunction(name: "fieldVertex"), let fragment = library.makeFunction(name: "fieldFragment"),
              let backgroundVertex = library.makeFunction(name: "fieldBackgroundVertex"),
              let backgroundFragment = library.makeFunction(name: "fieldBackgroundFragment") else {
            throw MusicError.message(L10n.string("无法加载粒子视效着色器"))
        }
        func make(vertex: any MTLFunction, fragment: any MTLFunction, blending: Bool, additive: Bool, name: String) throws -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = name; descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = pixelFormat
            attachment.isBlendingEnabled = blending
            attachment.rgbBlendOperation = .add; attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one; attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        let built = try States(
            background: make(vertex: backgroundVertex, fragment: backgroundFragment, blending: false, additive: false, name: "Particle field background"),
            core: make(vertex: vertex, fragment: fragment, blending: true, additive: false, name: "Particle field photographic core"),
            halo: make(vertex: vertex, fragment: fragment, blending: true, additive: true, name: "Particle field sparse halo"))
        Self.cache[key] = built; states = built
    }

    static func shaderSource() throws -> String {
        guard let url = Bundle.module.url(forResource: "ParticleField", withExtension: "metal", subdirectory: "Resources") else {
            throw MusicError.message(L10n.string("缺少粒子视效着色器"))
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func encode(into encoder: any MTLRenderCommandEncoder, size: CGSize, mode: VisualizationMode,
                time: Float, audio: AudioLevels = AudioLevels(), orbitRhythm: OrbitRhythmFrame = .zero, seed: UInt64 = 0,
                glow: Bool = true, lowPower: Bool = false) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let kind: Float
        switch mode {
        case .spectrumRing: kind = 0
        case .ribbons: kind = 1
        case .starfield: kind = 2
        default: return
        }
        let orbit = mode == .spectrumRing
        let bandReactive = orbit || mode == .ribbons
        let baseCount = lowPower ? Self.lowPowerPointCount : Self.regularPointCount
        let fineSections = lowPower ? 4 : 6
        let bassPCM = Self.scopeWaveform(audio.bassWaveform, available: audio.available)
        let midPCM = Self.scopeWaveform(audio.midWaveform, available: audio.available)
        let treblePCM = Self.scopeWaveform(audio.trebleWaveform, available: audio.available)
        for (index, samples) in [bassPCM, midPCM, treblePCM].enumerated() {
            samples.withUnsafeBufferPointer { buffer in
                encoder.setVertexBytes(buffer.baseAddress!, length: buffer.count * MemoryLayout<Float>.stride, index: index + 1)
            }
        }
        let seconds = time.isFinite ? max(0, time) : 0
        let aspect = Float(size.width / size.height), fov: Float = .pi * 42 / 180
        let yScale = 1 / tan(fov / 2), near: Float = 0.05, far: Float = 40
        let projection = simd_float4x4(columns: (SIMD4(yScale / aspect, 0, 0, 0), SIMD4(0, yScale, 0, 0),
            SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)))
        // The same modest orbit serves all fields. Its phase never depends on
        // instantaneous sound, preventing a beat from teleporting the camera.
        let yaw = sin(seconds * 0.105) * 0.11
        let pitch = -0.055 + sin(seconds * 0.083 + 0.7) * 0.065
        let roll = sin(seconds * 0.057) * 0.019
        let rotation = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
            * simd_float4x4(simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)))
            * simd_float4x4(simd_quatf(angle: roll, axis: SIMD3(0, 0, 1)))
        var translation = matrix_identity_float4x4
        translation.columns.3 = SIMD4(sin(seconds * 0.071) * 0.025, cos(seconds * 0.063) * 0.018,
                                     -4.55 * max(1, 1 / aspect), 1)
        // Rhythm accents come from real per-band PCM history, separately from
        // the signed waveform. Generic scalar energy/beat cannot invent onsets.
        func finite(_ value: Float) -> Float { !bandReactive && audio.available && value.isFinite ? min(1, max(0, value)) : 0 }
        func rhythm(_ value: Float) -> Float { bandReactive && value.isFinite ? min(1, max(0, value)) : 0 }
        var uniforms = ParticleFieldUniforms(projection: projection, modelView: translation * rotation,
            timing: SIMD4(seconds, kind, lowPower ? 90 : 120, 0),
            viewport: SIMD4(Float(size.width), Float(size.height), Float(size.height) * yScale / 2, lowPower ? 1 : 0),
            audio: SIMD4(finite(audio.energy), finite(audio.beat), finite(audio.amplitude), audio.available ? 1 : 0),
            bands: SIMD4(finite(audio.bass), finite(audio.mid), finite(audio.treble), 0),
            orbitEnergy: SIMD4(rhythm(orbitRhythm.energy.x), rhythm(orbitRhythm.energy.y), rhythm(orbitRhythm.energy.z), 0),
            orbitPulse: SIMD4(rhythm(orbitRhythm.pulse.x), rhythm(orbitRhythm.pulse.y), rhythm(orbitRhythm.pulse.z), 0),
            identity: SIMD4(UInt32(truncatingIfNeeded: seed ^ (seed >> 32)), UInt32(baseCount),
                            UInt32(Self.scopeSampleCount), UInt32(fineSections)))
        encoder.setCullMode(.none)
        encoder.setRenderPipelineState(states.background)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ParticleFieldUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ParticleFieldUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        let count = baseCount + (orbit ? Self.scopeSampleCount * fineSections * 3 : 0)
        if glow {
            uniforms.timing.w = 1
            encoder.setRenderPipelineState(states.halo)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ParticleFieldUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        }
        uniforms.timing.w = 0
        encoder.setRenderPipelineState(states.core)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ParticleFieldUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
    }
}
