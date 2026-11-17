import SwiftUI

/// Shared row appearance for all dense-table columns (Tracks, Versions, Notes, Playlists).
/// Usage: wrap a row HStack in DenseRow(isSelected:isHovered:rowIndex:) { content }.
/// Fixed row height so every column's rows align.
private let denseRowHeight: CGFloat = 30

struct DenseRow<Content: View>: View {
    let isSelected: Bool
    let isHovered: Bool
    let rowIndex: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .frame(height: denseRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
    }

    private var background: Color {
        if isSelected {
            return Color.primary.opacity(0.08)
        }
        if isHovered {
            return Color.primary.opacity(0.04)
        }
        return Color.clear
    }
}
