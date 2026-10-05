import AppKit
import MetalKit
import SwiftUI

struct ParticleFieldView: View {
    let mode: VisualizationMode
    let settings: VisualSettings
    let isPlaying: Bool
    let isActive: Bool
    let reduceMotion: Bool
    let seed: UInt64
    let signal: @MainActor () -> AudioLevels
    @State private var notice: String?

    var body: some View {
        ZStack {
            Color(red: 0.022, green: 0.031, blue: 0.046)
            ParticleFieldSurface(mode: mode, settings: settings, isPlaying: isPlaying, isActive: isActive,
                                 reduceMotion: reduceMotion, seed: seed, signal: signal, onNotice: { notice = $0 })
            if let notice {
                Text(notice).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 20)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode.title)
        .accessibilityValue(!isPlaying ? "已暂停" : reduceMotion ? "减少动态，画面已静止" : "氛围粒子，随可用音频变化")
    }
}

private struct ParticleFieldSurface: NSViewRepresentable {
    var mode: VisualizationMode
    var settings: VisualSettings
    var isPlaying: Bool
    var isActive: Bool
    var reduceMotion: Bool
    var seed: UInt64
    var signal: @MainActor () -> AudioLevels
    var onNotice: @MainActor (String) -> Void

    final class Coordinator { var renderer: ParticleFieldRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ParticleFieldMetalView {
        let device = MTLCreateSystemDefaultDevice()
        let view = ParticleFieldMetalView(frame: .zero, device: device)
        view.wantsLayer = true
        guard let device else {
            Task { @MainActor in onNotice("这台设备暂时无法显示粒子视效，音乐可继续播放。") }
            return view
        }
        do {
            let renderer = try ParticleFieldRenderer(view: view, device: device, signal: signal)
            context.coordinator.renderer = renderer; view.renderer = renderer
            renderer.onNotice = onNotice
            renderer.update(mode: mode, settings: settings, isPlaying: isPlaying, isActive: isActive,
                            reduceMotion: reduceMotion, seed: seed, signal: signal)
        } catch {
            Task { @MainActor in onNotice("粒子视效暂时无法加载，音乐可继续播放。") }
        }
        return view
    }

    func updateNSView(_ view: ParticleFieldMetalView, context: Context) {
        context.coordinator.renderer?.onNotice = onNotice
        context.coordinator.renderer?.update(mode: mode, settings: settings, isPlaying: isPlaying, isActive: isActive,
                                            reduceMotion: reduceMotion, seed: seed, signal: signal)
    }

    static func dismantleNSView(_ view: ParticleFieldMetalView, coordinator: Coordinator) {
        coordinator.renderer?.stop(); coordinator.renderer = nil; view.renderer = nil
    }
}

@MainActor
final class ParticleFieldMetalView: MTKView {
    weak var renderer: ParticleFieldRenderer?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); renderer?.attachWindow(); renderer?.resizeDrawable()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); renderer?.resizeDrawable()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties(); renderer?.resizeDrawable()
    }
}
