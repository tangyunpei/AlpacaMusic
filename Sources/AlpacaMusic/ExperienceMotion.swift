import SwiftUI

/// Short, interruptible transitions used for navigation and custom panels.
/// The root transaction also respects both system and app reduced motion.
enum ExperienceMotion {
    static let navigation = Animation.smooth(duration: 0.22)
    static let control = Animation.easeOut(duration: 0.16)
    static let visualization = Animation.easeInOut(duration: 0.72)
    static let panel = Animation.smooth(duration: 0.26)
}

struct PanelEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduced
    var appReduced = false
    @State private var visible = false
    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0).offset(y: visible || reduced || appReduced ? 0 : 7)
            .transaction { if reduced || appReduced { $0.animation = nil; $0.disablesAnimations = true } }
            .onAppear { withAnimation(reduced || appReduced ? nil : ExperienceMotion.panel) { visible = true } }
    }
}
