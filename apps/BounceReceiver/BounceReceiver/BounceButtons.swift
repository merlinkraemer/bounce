import SwiftUI

// MARK: - Full-width CTAs (library, onboarding, empty states)

/// Filled accent; icon + title use explicit white foreground (avoids `Label` tint on `.borderedProminent`).
struct BouncePrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isDisabled: Bool = false
    /// When `false`, sizes to content (e.g. side‑by‑side compact actions).
    var fullWidth: Bool = true
    /// Smaller type for form rows (e.g. sync recovery).
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(titleFont.weight(.semibold))
                }
                Text(title)
                    .font(titleFont.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 0 : 14)
            .padding(.vertical, verticalPadding)
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }

    private var titleFont: Font {
        compact ? .subheadline : .body
    }

    private var verticalPadding: CGFloat { compact ? 8 : 12 }
}

/// Outlined counterpart — same geometry as primary, secondary hierarchy.
struct BounceSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isDisabled: Bool = false
    var fullWidth: Bool = true
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(titleFont.weight(.semibold))
                }
                Text(title)
                    .font(titleFont.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 0 : 14)
            .padding(.vertical, verticalPadding)
            .background(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }

    private var titleFont: Font {
        compact ? .subheadline : .body
    }

    private var verticalPadding: CGFloat { compact ? 8 : 12 }
}

/// Low-emphasis text action (Continue to Library, Sync status).
struct BouncePlainButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}
