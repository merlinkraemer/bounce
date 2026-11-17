import SwiftUI

/// Shared metrics for empty regions and onboarding button stacks.
enum EmptyRecentLayout {
    static let maxContentWidth: CGFloat = 280
    static let stackSpacing: CGFloat = 12
}

/// Shared empty-state layout: symbol → title → description → optional footer actions.
struct EmptyStateBlock<Footer: View>: View {
    let symbolName: String
    var symbolSize: CGFloat
    let title: String
    var description: String?
    var maxContentWidth: CGFloat
    @ViewBuilder var footer: () -> Footer

    init(
        symbolName: String,
        symbolSize: CGFloat = 40,
        title: String,
        description: String? = nil,
        maxContentWidth: CGFloat = EmptyRecentLayout.maxContentWidth,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.symbolName = symbolName
        self.symbolSize = symbolSize
        self.title = title
        self.description = description
        self.maxContentWidth = maxContentWidth
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbolName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                if let description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            footer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: maxContentWidth)
        .frame(maxWidth: .infinity)
    }
}

extension EmptyStateBlock where Footer == EmptyView {
    init(
        symbolName: String,
        symbolSize: CGFloat = 40,
        title: String,
        description: String? = nil,
        maxContentWidth: CGFloat = EmptyRecentLayout.maxContentWidth
    ) {
        self.init(
            symbolName: symbolName,
            symbolSize: symbolSize,
            title: title,
            description: description,
            maxContentWidth: maxContentWidth,
            footer: { EmptyView() }
        )
    }
}
