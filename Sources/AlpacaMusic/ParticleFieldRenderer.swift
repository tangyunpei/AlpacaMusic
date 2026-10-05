import AppKit
import MetalKit
import QuartzCore

@MainActor
final class ParticleFieldRenderer: NSObject, MTKViewDelegate {
    private weak var view: MTKView?
    private let queue: any MTLCommandQueue
    private let pipeline: ParticleFieldPipeline
    private let inFlight = DispatchSemaphore(value: 2)
    private var visibilityObserver: (any NSObjectProtocol)?
    private var signal: @MainActor () -> AudioLevels
    private var settings = VisualSettings.standard
    private var mode: VisualizationMode = .spectrumRing
    private var seed: UInt64 = 0
    private var isPlaying = false
    private var isActive = false
    private var reduceMotion = false
    private var stopped = false
    private var failed = false
    private var clock = ParticleFieldMotionClock()
    private var constrained = false
    private var measurementStart = CACurrentMediaTime()
    private var measurementFrames = 0
    private var slowSeconds = 0.0
    private var recoveryAt = 0.0
    private var previousLowPower: Bool?
    private(set) var measuredFPS = 0.0
    private(set) var renderedFrames = 0
    var onNotice: @MainActor (String) -> Void = { _ in }

    private var lowPower: Bool { settings.batterySaver && ProcessInfo.processInfo.isLowPowerModeEnabled }
    private var visible: Bool {
        guard let view, let window = view.window else { return false }
        return !view.isHiddenOrHasHiddenAncestor && window.occlusionState.contains(.visible)
    }
    private var animated: Bool { isPlaying && isActive && !reduceMotion && visible && !failed && !stopped }

    init(view: MTKView, device: any MTLDevice, signal: @escaping @MainActor () -> AudioLevels) throws {
        self.view = view; self.signal = signal
        guard let queue = device.makeCommandQueue() else { throw MusicError.message("无法建立粒子视效命令队列") }
        self.queue = queue
        pipeline = try ParticleFieldPipeline(device: device)
        super.init()
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.preferredFramesPerSecond = 60
        view.delegate = self
        attachWindow(); resizeDrawable()
    }

    func update(mode: VisualizationMode, settings: VisualSettings, isPlaying: Bool, isActive: Bool,
                reduceMotion: Bool, seed: UInt64, signal: @escaping @MainActor () -> AudioLevels) {
        let wasAnimated = animated
        if self.mode != mode || self.seed != seed { clock.reset() }
        self.mode = mode; self.settings = settings; self.isPlaying = isPlaying; self.isActive = isActive
        self.reduceMotion = reduceMotion; self.seed = seed; self.signal = signal
        if wasAnimated != animated { clock.resetTimestamp(); restartMeasurement() }
        refreshScheduling()
        if isActive && visible { view?.needsDisplay = true }
    }

    func attachWindow() {
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = nil
        if let window = view?.window {
            visibilityObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                         object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.visibilityChanged() }
            }
        }
        visibilityChanged()
    }

    private func visibilityChanged() {
        guard !stopped else { return }
        clock.resetTimestamp(); restartMeasurement(); refreshScheduling()
        if isActive && visible { view?.needsDisplay = true }
    }

    func resizeDrawable() {
        guard let view, !stopped else { return }
        let scale = min(2, view.window?.backingScaleFactor ?? 2)
        let proposed = CGSize(width: max(1, view.bounds.width * scale), height: max(1, view.bounds.height * scale))
        let longest: CGFloat = lowPower ? 1_600 : 1_920
        let fit = min(1, longest / max(proposed.width, proposed.height))
        let size = CGSize(width: max(1, (proposed.width * fit).rounded()), height: max(1, (proposed.height * fit).rounded()))
        if view.drawableSize != size { view.drawableSize = size }
        if isActive && visible { view.needsDisplay = true }
    }

    private func refreshScheduling() {
        guard let view, !stopped else { return }
        if previousLowPower != lowPower {
            previousLowPower = lowPower
            resizeDrawable()
        }
        let target = lowPower ? (constrained ? 15 : 30) : (constrained ? 30 : 60)
        if view.preferredFramesPerSecond != target { view.preferredFramesPerSecond = target; restartMeasurement() }
        view.isPaused = !animated
    }

    private func restartMeasurement() {
        measurementStart = CACurrentMediaTime(); measurementFrames = 0; slowSeconds = 0
    }

    func stop() {
        stopped = true
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = nil
        view?.isPaused = true; view?.delegate = nil
        clock.resetTimestamp()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    func draw(in view: MTKView) {
        guard !stopped, !failed, isActive, visible else {
            clock.resetTimestamp(); refreshScheduling(); return
        }
        let moving = animated
        let canSample = isPlaying && isActive && visible
        let frame = clock.frame(at: CACurrentMediaTime(), animated: moving,
                                levels: canSample ? signal() : AudioLevels(),
                                captureStaticSignal: canSample && reduceMotion)
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal(); return
        }
        command.label = "Native music particle field"
        pipeline.encode(into: encoder, size: view.drawableSize, mode: mode, time: frame.time,
                        audio: frame.audio, orbitRhythm: frame.orbitRhythm, seed: seed, glow: settings.glow && !constrained, lowPower: lowPower || constrained)
        encoder.endEncoding()
        let semaphore = inFlight
        command.addCompletedHandler { [weak self] result in
            semaphore.signal()
            if result.status == .error {
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    self.failed = true; self.refreshScheduling()
                    self.onNotice("粒子视效暂时不可用，音乐可继续播放。")
                }
            }
        }
        command.present(drawable); command.commit()
        renderedFrames += 1
        if moving { measureFrame() }
        refreshScheduling()
    }

    private func measureFrame() {
        let now = CACurrentMediaTime()
        measurementFrames += 1
        let elapsed = now - measurementStart
        guard elapsed >= 1 else { return }
        measuredFPS = Double(measurementFrames) / elapsed
        let floor = lowPower ? 24.0 : 45.0
        if !constrained {
            slowSeconds = measuredFPS < floor ? slowSeconds + elapsed : 0
            if slowSeconds > 2.5 { constrained = true; recoveryAt = now + 24; resizeDrawable() }
        } else if now > recoveryAt, measuredFPS >= (lowPower ? 14 : 28) {
            constrained = false; resizeDrawable()
        }
        measurementStart = now; measurementFrames = 0
    }
}
