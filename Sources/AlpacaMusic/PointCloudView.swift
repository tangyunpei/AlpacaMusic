import AppKit
import MetalKit
import SwiftUI

struct PointCloudView: View {
    let track: Track?
    let settings: VisualSettings
    var isPlaying = true
    let signal: @MainActor () -> AudioLevels
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasCloud = false
    @State private var notice: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ArtworkView(track: track, radius: 5, highResolution: true)
                    .frame(width: min(geometry.size.width, geometry.size.height) * 0.7,
                           height: min(geometry.size.width, geometry.size.height) * 0.7)
                    .opacity(hasCloud ? 0 : 1)
                    .animation(.easeOut(duration: 0.2), value: hasCloud)
                MetalSurface(track: track, settings: settings, isPlaying: isPlaying, isActive: scenePhase == .active, signal: signal,
                             onVisibility: { hasCloud = $0 }, onNotice: { notice = $0 })
                if let notice {
                    Text(notice).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 20)
                        .allowsHitTesting(false)
                }
            }
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(track?.title ?? "AlpacaMusic")，封面点云")
        .accessibilityValue(track?.source.supportsAudioAnalysis == false ? "氛围模式，无实时音频频谱" : isPlaying ? "随可用音频变化" : "已暂停")
        .accessibilityHint("拖动旋转，滚动缩放，双击归位")
        .onChange(of: Artwork.key(for: track)) { notice = nil }
    }
}

private struct MetalSurface: NSViewRepresentable {
    var track: Track?
    var settings: VisualSettings
    var isPlaying: Bool
    var isActive: Bool
    var signal: @MainActor () -> AudioLevels
    var onVisibility: @MainActor (Bool) -> Void
    var onNotice: @MainActor (String) -> Void

    final class Coordinator {
        var renderer: MetalRenderer?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> InteractiveMetalView {
        let device = MTLCreateSystemDefaultDevice()
        let view = InteractiveMetalView(frame: .zero, device: device)
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        guard let device else {
            Task { @MainActor in onNotice("这台设备暂时无法显示点云，音乐播放不受影响。") }
            return view
        }
        do {
            let renderer = try MetalRenderer(view: view, device: device, signal: signal)
            renderer.onVisibility = onVisibility; renderer.onNotice = onNotice
            context.coordinator.renderer = renderer; view.renderer = renderer
            renderer.update(track: track, settings: settings, signal: signal, isPlaying: isPlaying, isActive: isActive)
        } catch {
            Task { @MainActor in onNotice("点云暂时无法加载，已显示专辑封面。") }
        }
        return view
    }

    func updateNSView(_ view: InteractiveMetalView, context: Context) {
        context.coordinator.renderer?.onVisibility = onVisibility
        context.coordinator.renderer?.onNotice = onNotice
        context.coordinator.renderer?.update(track: track, settings: settings, signal: signal, isPlaying: isPlaying, isActive: isActive)
    }

    static func dismantleNSView(_ view: InteractiveMetalView, coordinator: Coordinator) {
        coordinator.renderer?.stop(); coordinator.renderer = nil
        view.renderer = nil
    }
}

@MainActor
final class InteractiveMetalView: MTKView {
    weak var renderer: MetalRenderer?
    private var previousPoint = CGPoint.zero
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderer?.resizeDrawable()
        renderer?.refreshVisibility()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); renderer?.resizeDrawable()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties(); renderer?.resizeDrawable()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { renderer?.resetCamera(); return }
        window?.makeFirstResponder(self)
        previousPoint = convert(event.locationInWindow, from: nil)
        renderer?.beginDrag(); NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        renderer?.drag(x: point.x - previousPoint.x, y: previousPoint.y - point.y)
        previousPoint = point
    }

    override func mouseUp(with event: NSEvent) { renderer?.endDrag(); NSCursor.openHand.set() }
    override func scrollWheel(with event: NSEvent) {
        let scale: Float = event.hasPreciseScrollingDeltas ? 0.012 : 0.07
        renderer?.magnify(exp(Float(event.scrollingDeltaY) * scale))
    }
    override func magnify(with event: NSEvent) { renderer?.magnify(exp(Float(event.magnification))) }
    override func smartMagnify(with event: NSEvent) { renderer?.resetCamera() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: renderer?.beginDrag(); renderer?.drag(x: -20, y: 0); renderer?.endDrag()
        case 124: renderer?.beginDrag(); renderer?.drag(x: 20, y: 0); renderer?.endDrag()
        case 125: renderer?.beginDrag(); renderer?.drag(x: 0, y: 20); renderer?.endDrag()
        case 126: renderer?.beginDrag(); renderer?.drag(x: 0, y: -20); renderer?.endDrag()
        default: super.keyDown(with: event)
        }
    }
}
