import SwiftUI

// MARK: - Library home — Recent section when there are no tracks

/// Fixed-height "Importing…" row that fades in/out without shifting the
/// surrounding layout. The space stays reserved so the buttons above don't
/// jump when isImporting toggles (issue #75).
struct ImportProgressIndicator: View {
    let isImporting: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Importing…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(height: 20)
        .opacity(isImporting ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isImporting)
        .accessibilityHidden(!isImporting)
    }
}

/// Empty library: quiet symbol, one line, one secondary Import button (same for paired and unpaired). Pairing lives in the
/// toolbar sync button. Centred by the caller in the space below the library rows.
struct EmptyLibraryActionCard: View {
    let isImporting: Bool
    let importError: String?
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)

            Text("No tracks yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(action: onImport) {
                Text("Import Audio")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isImporting)
            .opacity(isImporting ? 0.5 : 1)
            .padding(.top, 8)

            ImportProgressIndicator(isImporting: isImporting)

            if let importError, !importError.isEmpty {
                Text(importError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }
}
