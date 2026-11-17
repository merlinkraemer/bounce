import SwiftUI

/// Per-file import activity list shown from the sidebar footer status row.
struct ImportActivityPopover: View {
    let items: [ImportActivityItem]
    let onClear: () -> Void
    let onCancelAll: () -> Void
    let onCancel: (UUID) -> Void
    let onRetry: (UUID) -> Void

    private var hasFailures: Bool {
        items.contains { $0.phase == .failed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hasActive ? "Importing" : (hasFailures ? "Import Failed" : "Import Stopped"))
                    .font(.headline)
                Spacer()
                if items.contains(where: { isActive($0) }) {
                    Button("Cancel All", action: onCancelAll)
                        .buttonStyle(.borderless)
                } else if hasFailures || !items.isEmpty {
                    Button("Clear", action: onClear)
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if items.isEmpty {
                Text("No active imports")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(items) { item in
                            ImportActivityRow(
                                item: item,
                                onCancel: { onCancel(item.id) },
                                onRetry: { onRetry(item.id) }
                            )
                        }
                    }
                    .padding(16)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 320)
    }

    private func isActive(_ item: ImportActivityItem) -> Bool {
        switch item.phase {
        case .queued, .converting, .waveform, .finishing: return true
        default: return false
        }
    }

    private var hasActive: Bool {
        items.contains(where: isActive)
    }
}

private struct ImportActivityRow: View {
    let item: ImportActivityItem
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.filename)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(item.phase == .failed ? Color.orange : Color.primary)

            HStack(spacing: 8) {
                Text(phaseLabel)
                    .font(.caption)
                    .foregroundStyle(item.phase == .failed ? Color.orange : Color.secondary)
                Spacer(minLength: 0)
                if isActive {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.borderless)
                        .font(.caption)
                } else if item.phase == .failed {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            if let errorMessage = item.errorMessage,
               item.phase == .failed {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            progressBar
        }
    }

    private var phaseLabel: String {
        switch item.phase {
        case .queued: return "Queued"
        case .converting: return "Converting"
        case .waveform: return "Waveform"
        case .finishing: return "Finishing"
        case .complete: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        switch item.phase {
        case .converting:
            if let fraction = item.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        case .queued, .waveform, .finishing:
            ProgressView()
                .progressViewStyle(.linear)
        case .complete:
            ProgressView(value: 1)
                .progressViewStyle(.linear)
        case .failed, .cancelled:
            EmptyView()
        }
    }

    private var isActive: Bool {
        switch item.phase {
        case .queued, .converting, .waveform, .finishing: return true
        default: return false
        }
    }
}
