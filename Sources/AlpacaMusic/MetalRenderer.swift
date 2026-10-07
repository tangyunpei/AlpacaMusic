import AppKit
import MetalKit
import QuartzCore
import simd

struct CloudUniforms {
    var projection: simd_float4x4
    var modelView: simd_float4x4
    var motion: SIMD4<Float>
    var shape: SIMD4<Float>
    var wave: SIMD4<Float>
    var behavior: SIMD4<Float>
    var viewport: SIMD4<Float>
}

private struct RenderQuality: Equatable {
    var density: Int
    var scale: CGFloat
    var glow: Bool
}

@MainActor
final class MetalRenderer: NSObject, MTKViewDelegate {
    private struct Pipelines {
        var normal: any MTLRenderPipelineState
        var glow: any MTLRenderPipelineState
    }
    private struct CloudLayer {
        var samples: CloudSamples
        var buffer: any MTLBuffer
        var created: CFTimeInterval
        var duration: CFTimeInterval
        var assemble: Bool
        var dissolveAt: CFTimeInterval?
        var fadeAt: CFTimeInterval?
        var fadeDuration: CFTimeInterval = 1.05
        var fadeFrom: Float = 1
        var opacity: Float = 0
    }
    private static var pipelineCache: [UInt64: Pipelines] = [:]
    private let device: any MTLDevice
    private var queue: any MTLCommandQueue
    private let pipelines: Pipelines
    private weak var view: MTKView?
    private var layers: [CloudLayer] = []
    private var samplingTask: Task<Void, Never>?
    private var samplingWorker: Task<CloudSamples, any Error>?
    private var generation = 0
    private var builtKey = ""
    private var requestedKey = ""
    private var track: Track?
    private var settings = VisualSettings.standard
    private var isPlaying = true
    private var isActive = true
    private var interactionUntil: CFTimeInterval = 0
    private var signal: @MainActor () -> AudioLevels
    private var qualities: [RenderQuality] = []
    private var qualityIndex = 0
    private var visible = false
    private var isSampling = false
    private var stopped = false
    private var lastFrame = CACurrentMediaTime()
    private var elapsed: Float = 0
    private var energy: Float = 0
    private var beat: Float = 0
    private var yaw: Float = 0.055, pitch: Float = -0.035, zoom: Float = 1
    private var targetYaw: Float = 0.055, targetPitch: Float = -0.035, targetZoom: Float = 1
    private var velocity = SIMD2<Float>.zero
    private var dragging = false
    private var fpsStart = CACurrentMediaTime(), frames = 0
    private var lowSeconds = 0.0, goodSeconds = 0.0
    private var gpuRetryAt: CFTimeInterval?
    private var gpuFailures = 0
    private var lastArtworkNotice = ""
    private let inFlight = DispatchSemaphore(value: 3)
    var onVisibility: @MainActor (Bool) -> Void = { _ in }
    var onNotice: @MainActor (String) -> Void = { _ in }

    // Read-only diagnostics for integration/performance verification.
    private(set) var renderedFrames = 0
    private(set) var sampledGeneration = 0
    private(set) var measuredFPS = 0.0
    var pointCount: Int { layers.last?.samples.points.count ?? 0 }
    var currentDensity: Int { quality.density }
    var orbit: SIMD3<Float> { SIMD3(yaw, pitch, zoom) }

    private var quality: RenderQuality { qualities[min(qualityIndex, qualities.count - 1)] }
    private var reducedMotion: Bool { settings.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(view: MTKView, device: any MTLDevice, signal: @escaping @MainActor () -> AudioLevels) throws {
        self.view = view; self.device = device; self.signal = signal
        guard let queue = device.makeCommandQueue() else { throw MusicError.message(L10n.string("无法建立 Metal 命令队列")) }
        self.queue = queue
        if let cached = Self.pipelineCache[device.registryID] { pipelines = cached }
        else {
            let source = try Self.shaderSource()
            let options = MTLCompileOptions()
            let library = try device.makeLibrary(source: source, options: options)
            guard let vertex = library.makeFunction(name: "cloudVertex"), let fragment = library.makeFunction(name: "cloudFragment") else { throw MusicError.message(L10n.string("无法加载点云着色器")) }
            func pipeline(glow: Bool) throws -> any MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.label = glow ? "Album points / glow" : "Album points / normal"
                descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
                let color = descriptor.colorAttachments[0]!
                color.pixelFormat = .bgra8Unorm_srgb
                color.isBlendingEnabled = true
                color.rgbBlendOperation = .add; color.alphaBlendOperation = .add
                color.sourceRGBBlendFactor = .sourceAlpha
                color.destinationRGBBlendFactor = glow ? .one : .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one; color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            let result = try Pipelines(normal: pipeline(glow: false), glow: pipeline(glow: true))
            Self.pipelineCache[device.registryID] = result; pipelines = result
        }
        super.init()
        qualities = qualityLevels(settings)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.autoResizeDrawable = false
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.delegate = self
        resizeDrawable()
    }

    static func shaderSource() throws -> String {
        guard let url = Bundle.module.url(forResource: "PointCloud", withExtension: "metal", subdirectory: "Resources") else { throw MusicError.message(L10n.string("缺少点云着色器")) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func update(track: Track?, settings: VisualSettings, signal: @escaping @MainActor () -> AudioLevels, isPlaying: Bool = true, isActive: Bool = true) {
        self.track = track; self.signal = signal
        if self.isPlaying != isPlaying || self.isActive != isActive { lastFrame = CACurrentMediaTime() }
        self.isPlaying = isPlaying; self.isActive = isActive
        let previousSettings = self.settings
        self.settings = settings
        let next = qualityLevels(settings)
        if next != qualities {
            let oldDensity = quality.density
            let requestedDensityChanged = previousSettings.density != settings.density
            qualities = next
            qualityIndex = requestedDensityChanged ? 0 : min(qualityIndex, next.count - 1)
            lowSeconds = 0; goodSeconds = 0
            resizeDrawable()
            if oldDensity != quality.density { requestCover() }
        }
        let key = Artwork.key(for: track)
        if key != requestedKey { requestedKey = key; requestCover() }
        updateFrameRate()
        view?.needsDisplay = true
    }

    private func qualityLevels(_ settings: VisualSettings) -> [RenderQuality] {
        let density = [96, 160, 224].contains(settings.density) ? settings.density : 160
        let scale = min(view?.window?.backingScaleFactor ?? 2, 2)
        var result = [RenderQuality(density: density, scale: scale, glow: settings.glow)]
        if density > 160 { result.append(RenderQuality(density: 160, scale: scale, glow: settings.glow)) }
        if density > 96 { result.append(RenderQuality(density: 96, scale: scale, glow: settings.glow)) }
        if scale > 1.5 { result.append(RenderQuality(density: 96, scale: 1.5, glow: settings.glow)) }
        if settings.glow { result.append(RenderQuality(density: 96, scale: min(scale, 1.5), glow: false)) }
        return result
    }

    func resizeDrawable() {
        guard let view, !qualities.isEmpty else { return }
        let next = qualityLevels(settings)
        if next != qualities { qualities = next; qualityIndex = min(qualityIndex, next.count - 1) }
        view.drawableSize = CGSize(width: max(1, view.bounds.width * quality.scale), height: max(1, view.bounds.height * quality.scale))
        view.needsDisplay = true
    }

    private func updateFrameRate() {
        let cap = settings.batterySaver && ProcessInfo.processInfo.isLowPowerModeEnabled
        let desired = cap || reducedMotion || !isPlaying ? 30 : 60
        if view?.preferredFramesPerSecond != desired { view?.preferredFramesPerSecond = desired; lowSeconds = 0; goodSeconds = 0 }
        let now = CACurrentMediaTime()
        let transitioning = layers.contains { now - $0.created < $0.duration || $0.fadeAt != nil }
        let moving = (isPlaying && !reducedMotion) || dragging || now < interactionUntil || transitioning
        let paused = !isActive || view?.window == nil || !moving
        if view?.isPaused != paused { view?.isPaused = paused }
    }

    func refreshVisibility() {
        lastFrame = CACurrentMediaTime()
        updateFrameRate()
        view?.needsDisplay = true
    }

    private func requestCover() {
        guard !stopped else { return }
        samplingTask?.cancel(); samplingWorker?.cancel()
        generation += 1
        let ownGeneration = generation, track = track, density = quality.density
        let key = Artwork.key(for: track), changed = builtKey != key
        isSampling = true
        if changed, !reducedMotion, let index = layers.indices.last, layers[index].dissolveAt == nil { layers[index].dissolveAt = CACurrentMediaTime() }
        samplingTask = Task { [weak self] in
            guard let self else { return }
            let artwork = await Artwork.raster(for: track)
            guard !Task.isCancelled, !stopped, generation == ownGeneration else { return }
            let seed = Artwork.seed(for: track)
            let worker = Task.detached(priority: .userInitiated) { try await CloudSampler.sample(artwork.pixels, density: density, seed: seed) }
            samplingWorker = worker
            do {
                let samples = try await worker.value
                guard !Task.isCancelled, !stopped, generation == ownGeneration else { return }
                let buffer = try makeBuffer(samples)
                let now = CACurrentMediaTime(), duration = reducedMotion || !changed ? 0.2 : 0.75
                for i in layers.indices { layers[i].fadeAt = now; layers[i].fadeFrom = layers[i].opacity; layers[i].fadeDuration = duration }
                layers.append(CloudLayer(samples: samples, buffer: buffer, created: now, duration: duration, assemble: changed))
                while layers.count > 3 {
                    let weakest = layers.dropLast().indices.min { layers[$0].opacity < layers[$1].opacity } ?? 0
                    layers.remove(at: weakest)
                }
                builtKey = key; sampledGeneration = ownGeneration
                if artwork.usedFallback, lastArtworkNotice != key {
                    lastArtworkNotice = key; onNotice(L10n.string("封面读取失败，已使用生成封面。"))
                }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, !stopped else { return }
                if layers.isEmpty { onVisibility(false) }
                onNotice(L10n.string("点云暂时不可用，音乐播放不受影响。"))
            }
            if generation == ownGeneration { isSampling = false; updateFrameRate(); view?.needsDisplay = true }
        }
    }

    private func makeBuffer(_ samples: CloudSamples) throws -> any MTLBuffer {
        let buffer = samples.points.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        guard let buffer else { throw MusicError.message(L10n.string("没有足够的图形内存")) }
        buffer.label = "Album points \(samples.density)"
        return buffer
    }

    func stop() {
        stopped = true; samplingTask?.cancel(); samplingWorker?.cancel()
        samplingTask = nil; samplingWorker = nil; layers.removeAll()
        view?.delegate = nil; view?.isPaused = true
    }

    private func requestInteractionFrame() {
        interactionUntil = CACurrentMediaTime() + 0.8
        updateFrameRate(); view?.needsDisplay = true
    }
    func beginDrag() { dragging = true; velocity = .zero; requestInteractionFrame() }
    func drag(x: CGFloat, y: CGFloat) {
        velocity = SIMD2(Float(x) * 0.0038, Float(y) * 0.0038)
        targetYaw += velocity.x; targetPitch = clampPitch(targetPitch + velocity.y)
        requestInteractionFrame()
    }
    func endDrag() { dragging = false; requestInteractionFrame() }
    func magnify(_ factor: Float) { targetZoom = min(2.5, max(0.6, targetZoom * factor)); requestInteractionFrame() }
    func resetCamera() { targetYaw = 0.055; targetPitch = -0.035; targetZoom = 1; velocity = .zero; requestInteractionFrame() }
    private func clampPitch(_ value: Float) -> Float { min(.pi * 5 / 12, max(-.pi * 5 / 12, value)) }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    func draw(in view: MTKView) {
        guard !stopped, isActive else { return }
        let now = CACurrentMediaTime()
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor, view.window?.occlusionState.contains(.visible) == true else {
            view.preferredFramesPerSecond = 5
            lastFrame = now; fpsStart = now; frames = 0; lowSeconds = 0; goodSeconds = 0; return
        }
        if let retryAt = gpuRetryAt {
            guard now >= retryAt else { return }
            recoverGPU()
        }
        let dt = Float(min(0.1, max(0, now - lastFrame)))
        lastFrame = now
        let reduce = reducedMotion
        if isPlaying && !reduce { elapsed += dt }
        let levels = isPlaying && track?.source.supportsAudioAnalysis != false ? signal() : AudioLevels()
        let wantedEnergy = levels.available && levels.energy.isFinite ? min(1, max(0, levels.energy)) : 0
        let wantedBeat = levels.available && levels.beat.isFinite ? min(1, max(0, levels.beat)) : 0
        energy += (wantedEnergy - energy) * (1 - exp(-dt / (wantedEnergy > energy ? 0.045 : 0.11)))
        beat += (wantedBeat - beat) * (1 - exp(-dt / (wantedBeat > beat ? 0.035 : 0.08)))
        if !dragging {
            if !reduce { targetYaw += velocity.x * dt * 60; targetPitch = clampPitch(targetPitch + velocity.y * dt * 60) }
            velocity *= exp(-dt * 10)
            if settings.autoOrbit, !reduce, isPlaying { targetYaw += (.pi / 75) * dt }
        }
        let follow: Float = reduce ? 1 : 1 - exp(-dt * 14)
        yaw += (targetYaw - yaw) * follow; pitch += (targetPitch - pitch) * follow; zoom += (targetZoom - zoom) * follow
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return }
        command.label = "Album point cloud frame"
        let aspect = Float(max(1, view.drawableSize.width) / max(1, view.drawableSize.height))
        let fov = Float.pi * 42 / 180, tanHalf = tan(fov / 2)
        let distance = (1 / (tanHalf * 0.7)) * max(1, 1 / aspect)
        var translation = matrix_identity_float4x4; translation.columns.3.z = -distance / zoom
        let rotation = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))) * simd_float4x4(simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)))
        let modelView = translation * rotation
        let near: Float = 0.05, far: Float = 60, yScale = 1 / tanHalf
        let projection = simd_float4x4(columns: (SIMD4(yScale / aspect, 0, 0, 0), SIMD4(0, yScale, 0, 0), SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)))
        for i in layers.indices.reversed() {
            let duration = reduce ? 0.2 : layers[i].duration
            let progress = Float(min(1, max(0, (now - layers[i].created) / duration)))
            let dissolve = !reduce ? Float(layers[i].dissolveAt.map { min(1, (now - $0) / 0.4) } ?? 0) : 0
            let fade = Float(layers[i].fadeAt.map { min(1, (now - $0) / (reduce ? 0.2 : layers[i].fadeDuration)) } ?? 0)
            if fade >= 1 { layers.remove(at: i); continue }
            let enteringOpacity = progress * progress * (3 - 2 * progress)
            layers[i].opacity = layers[i].fadeAt == nil ? enteringOpacity * (1 - dissolve * 0.72) : layers[i].fadeFrom * (1 - fade)
            var uniforms = CloudUniforms(projection: projection, modelView: modelView,
                motion: SIMD4(elapsed, energy, beat, reduce || !layers[i].assemble ? 1 : progress),
                shape: SIMD4(settings.depth, settings.bounce, settings.idle, settings.pointSize),
                wave: SIMD4(settings.frequency, settings.speed, settings.invert ? 1 : 0, settings.scheme == 1 ? 1 : 0),
                behavior: SIMD4(settings.beatPop ? 1 : 0, !reduce && isPlaying ? 1 : 0, dissolve, layers[i].opacity),
                viewport: SIMD4(Float(view.drawableSize.height) / (2 * tanHalf), quality.glow ? 1 : 0, 160 / Float(layers[i].samples.density), distance / zoom))
            encoder.setVertexBuffer(layers[i].buffer, offset: 0, index: 0)
            // A restrained additive halo sits beneath an accurate color core.
            // Never render the photographic core itself with additive blending.
            if quality.glow {
                encoder.setRenderPipelineState(pipelines.glow)
                uniforms.viewport.y = 1
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<CloudUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: layers[i].samples.points.count)
            }
            encoder.setRenderPipelineState(pipelines.normal)
            uniforms.viewport.y = 0
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CloudUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: layers[i].samples.points.count)
        }
        encoder.endEncoding()
        let semaphore = inFlight
        command.addCompletedHandler { [weak self] completed in
            semaphore.signal()
            if completed.status == .error {
                Task { @MainActor [weak self] in self?.handleGPUFailure() }
            }
        }
        command.present(drawable); command.commit()
        updateFrameRate()
        renderedFrames += 1
        if !layers.isEmpty, !visible { visible = true; onVisibility(true) }
        frames += 1
        if now - fpsStart >= 1 {
            let seconds = now - fpsStart
            measuredFPS = Double(frames) / seconds
            updateFrameRate()
            if view.preferredFramesPerSecond > 30, !isSampling {
                lowSeconds = measuredFPS < 45 ? lowSeconds + seconds : 0
                goodSeconds = measuredFPS > 55 ? goodSeconds + seconds : 0
                if lowSeconds >= 3, qualityIndex < qualities.count - 1 { changeQuality(qualityIndex + 1) }
                else if goodSeconds >= 10, qualityIndex > 0 { changeQuality(qualityIndex - 1) }
            }
            fpsStart = now; frames = 0
        }
    }

    private func changeQuality(_ index: Int) {
        let oldDensity = quality.density
        qualityIndex = min(qualities.count - 1, max(0, index)); lowSeconds = 0; goodSeconds = 0
        resizeDrawable()
        if quality.density != oldDensity { requestCover() }
    }

    private func handleGPUFailure() {
        guard !stopped, gpuRetryAt == nil else { return }
        visible = false; onVisibility(false)
        gpuFailures += 1
        gpuRetryAt = CACurrentMediaTime() + (gpuFailures < 3 ? 0.35 : 1)
        if qualityIndex < qualities.count - 1 { changeQuality(qualityIndex + 1) }
    }

    private func recoverGPU() {
        gpuRetryAt = nil
        if let replacement = device.makeCommandQueue() { queue = replacement }
        do { for i in layers.indices { layers[i].buffer = try makeBuffer(layers[i].samples) } }
        catch { handleGPUFailure() }
    }
}
