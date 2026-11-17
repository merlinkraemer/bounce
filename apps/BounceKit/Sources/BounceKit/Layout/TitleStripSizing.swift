import CoreGraphics

/// Pure geometry for the catalogue title strip: a square cover beside an
/// information stack (title, metadata, description, Play/Shuffle row).
///
/// Extracted from `TitleStripLayout` in BounceSender so the mutually dependent
/// cover-size / info-height resolution is unit-testable without SwiftUI. The
/// `Layout` conformance there measures the real subviews and delegates the math
/// to this type.
public struct TitleStripSizing: Sendable {
    /// Horizontal gap between the cover and the information stack.
    public var spacing: CGFloat
    /// Minimum cover side, and the seed for the resolution loop.
    public var minSide: CGFloat
    /// Floor for the text column so narrow columns still measure sensibly.
    public var minInfoWidth: CGFloat

    /// Width assumed when a proposal has none.
    public static let fallbackWidth: CGFloat = 600

    public init(spacing: CGFloat = 16, minSide: CGFloat = 72, minInfoWidth: CGFloat = 40) {
        self.spacing = spacing
        self.minSide = minSide
        self.minInfoWidth = minInfoWidth
    }

    /// Resolves the cover side and the strip height for a strip of `width`.
    ///
    /// Cover side and info height are mutually dependent: a wider cover leaves
    /// less text width, which can wrap taller. The loop iterates with a
    /// monotonic max — so the candidate can only grow — and re-measures after
    /// exhausting its iterations at exactly the width `placeSubviews` will use
    /// (`width - spacing - side`), rather than at `minSide`, so the reported
    /// height and the rendered placement describe the same text width.
    ///
    /// `infoHeight` measures the information stack at the given text width.
    public func resolvedPair(
        width: CGFloat,
        infoHeight: (_ infoWidth: CGFloat) -> CGFloat
    ) -> (side: CGFloat, height: CGFloat) {
        func height(forSide side: CGFloat) -> CGFloat {
            let infoWidth = max(minInfoWidth, width - spacing - side)
            return infoHeight(infoWidth)
        }

        var side = minSide
        var tallest = minSide

        for _ in 0..<8 {
            let measured = height(forSide: side)
            tallest = max(tallest, measured)
            let next = max(tallest, minSide)
            if abs(next - side) < 0.5 {
                side = next
                break
            }
            side = next
        }

        // Consistency check: if the loop exhausted without settling, the
        // measured height must still come from the width used for placement.
        // The cover may end up shorter than the stack, but nothing protrudes.
        if height(forSide: side) > side + 0.5 {
            tallest = max(tallest, height(forSide: side))
        } else {
            tallest = max(tallest, side)
        }

        return (side, tallest)
    }

    /// Full strip size for a proposed width, matching `Layout.sizeThatFits`.
    public func sizeThatFits(
        proposalWidth: CGFloat?,
        infoHeight: (_ infoWidth: CGFloat) -> CGFloat
    ) -> CGSize {
        let width = proposalWidth ?? Self.fallbackWidth
        let pair = resolvedPair(width: width, infoHeight: infoHeight)
        return CGSize(width: width, height: max(pair.side, pair.height))
    }
}
