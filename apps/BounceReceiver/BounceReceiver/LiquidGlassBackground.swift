import SwiftUI

/// Capsule liquid-glass background. iOS 26+ uses `.glassEffect`; older
/// systems fall back to a translucent fill that reads close enough to the
/// liquid-glass look without the real-time blur.
struct LiquidGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            content.background(
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.10))
            )
        }
    }
}

/// Fades scrolling content under the status bar. Match `baseColor` to the
/// screen background — `.black` for the player, `Color(.systemBackground)` for lists.
struct ScrollContentTopFade: View {
    let baseColor: Color
    let topInset: CGFloat
    var fadeHeight: CGFloat = 16

    var body: some View {
        LinearGradient(
            colors: [baseColor, baseColor.opacity(0.8), baseColor.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: topInset + fadeHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}
