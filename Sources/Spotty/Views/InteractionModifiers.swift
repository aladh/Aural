import SwiftUI

extension View {
    /// Applies value-driven motion only when the system accessibility setting allows it.
    func animationIfAllowed<Value: Equatable>(
        _ animation: Animation,
        value: Value,
        reduceMotion: Bool
    ) -> some View {
        self.animation(reduceMotion ? nil : animation, value: value)
    }

    /// Owns the recurring hover lifecycle for recyclable cards and rows.
    func hoverSurface(isHovering: Binding<Bool>) -> some View {
        modifier(HoverSurfaceModifier(isHovering: isHovering))
    }
}

func withAnimationIfAllowed(
    _ animation: Animation,
    reduceMotion: Bool,
    _ changes: () -> Void
) {
    if reduceMotion {
        changes()
    } else {
        withAnimation(animation, changes)
    }
}

private struct HoverSurfaceModifier: ViewModifier {
    @Binding var isHovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            // A recycled surface under a resting cursor keeps no stale highlight.
            .onDisappear { isHovering = false }
            .animationIfAllowed(.easeOut(duration: 0.15), value: isHovering, reduceMotion: reduceMotion)
    }
}
