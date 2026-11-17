import SwiftUI
import SwiftData
import BounceKit

/// Mac sheet to set a Track's working title and (optionally) join a sibling-version group.
/// Per spec: writes to `workingTitle` + `versionNumber` only — never touches `name` or files.
struct WorkingTitleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allTracks: [Track]

    let track: Track

    @State private var draftTitle: String = ""

    private var trimmedTitle: String {
        draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the typed title is the same group the track is already in.
    /// Drives whether we keep the existing `versionNumber` or assign a fresh one.
    private var isSameGroupAsExisting: Bool {
        guard let normalizedNew = LibrarySorting.normalizedWorkingTitle(trimmedTitle) else { return false }
        guard let normalizedOld = LibrarySorting.normalizedWorkingTitle(track.workingTitle) else { return false }
        return normalizedNew == normalizedOld
    }

    /// What versionNumber `commit` will write — displayed inline so the user knows what they're getting.
    private var resolvedVersionNumber: Int {
        if isSameGroupAsExisting, let existing = track.versionNumber { return existing }
        return nextVersionNumber
    }

    private var suggestions: [String] {
        WorkingTitleSuggestions.filteredTitles(prefix: trimmedTitle, from: allTracks)
    }

    private var siblings: [WorkingTitleSibling] {
        WorkingTitleSuggestions.siblings(of: trimmedTitle, in: allTracks, excluding: track.id)
    }

    private var nextVersionNumber: Int {
        WorkingTitleSuggestions.nextVersionNumber(for: trimmedTitle, in: allTracks, excluding: track.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name this version")
                    .font(.title2.weight(.semibold))
                Text("Original filename: \(track.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Working Title")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("e.g. Like Dawn", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .onSubmit { commit() }

                if !trimmedTitle.isEmpty && !suggestions.isEmpty && !suggestions.contains(where: { $0.lowercased() == trimmedTitle.lowercased() }) {
                    suggestionList
                }
            }

            if !trimmedTitle.isEmpty {
                if siblings.isEmpty {
                    Text("This will start a new working-title group as v1.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    siblingsList
                }
            }

            HStack(spacing: 12) {
                if track.workingTitle != nil {
                    Button(role: .destructive) {
                        clearWorkingTitle()
                    } label: {
                        Text("Remove Working Title")
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            draftTitle = track.workingTitle ?? ""
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Existing titles")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    draftTitle = suggestion
                } label: {
                    HStack {
                        Text(suggestion)
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Read-only list of existing siblings + the resolved version-number outcome.
    /// We deliberately do NOT offer per-sibling selection: each sibling is its own
    /// Track row, so "clicking" one has no meaningful semantic. The only choice
    /// the user has is the working-title text itself, which determines the group.
    private var siblingsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Existing versions of this title")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(siblings) { sibling in
                HStack(spacing: 8) {
                    Text(sibling.displayLabel)
                        .font(.subheadline)
                    Text("· \(sibling.trackName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(Color.accentColor)
                Text("This version will be saved as v\(resolvedVersionNumber)")
                    .font(.subheadline)
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Actions

    private func commit() {
        guard !trimmedTitle.isEmpty else { return }

        track.workingTitle = trimmedTitle
        // Preserve the existing versionNumber when the user is just editing the
        // title spelling within the same group; otherwise claim the next free slot.
        if !(isSameGroupAsExisting && track.versionNumber != nil) {
            track.versionNumber = nextVersionNumber
        }

        track.updatedAt = .now
        track.lastTouchedAt = .now
        try? modelContext.save()
        dismiss()
    }

    private func clearWorkingTitle() {
        track.workingTitle = nil
        track.versionNumber = nil
        track.updatedAt = .now
        try? modelContext.save()
        dismiss()
    }
}
