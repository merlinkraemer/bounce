import SwiftUI
import SwiftData
import BounceKit

/// iOS sheet to set a Track's working title and optionally join a sibling-version group.
/// Per spec: writes `workingTitle` + `versionNumber` only — never touches `name` or files.
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
            .filter { $0.lowercased() != trimmedTitle.lowercased() }
    }

    private var siblings: [WorkingTitleSibling] {
        WorkingTitleSuggestions.siblings(of: trimmedTitle, in: allTracks, excluding: track.id)
    }

    private var nextVersionNumber: Int {
        WorkingTitleSuggestions.nextVersionNumber(for: trimmedTitle, in: allTracks, excluding: track.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Like Dawn", text: $draftTitle)
                        .submitLabel(.done)
                        .onSubmit { commit() }

                    if !suggestions.isEmpty && !trimmedTitle.isEmpty {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { draftTitle = suggestion }
                                .foregroundStyle(.primary)
                        }
                    }
                } header: {
                    Text("Working title")
                } footer: {
                    Text("Original filename: \(track.name)")
                }

                if !siblings.isEmpty {
                    // Read-only sibling list. Selecting a sibling has no semantic
                    // (each sibling is its own Track row); the user's only meaningful
                    // input is the title text, which determines the group.
                    Section {
                        ForEach(siblings) { sibling in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sibling.displayLabel)
                                Text(sibling.trackName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Existing versions of this title")
                    } footer: {
                        Text("This version will be saved as v\(resolvedVersionNumber).")
                    }
                } else if !trimmedTitle.isEmpty {
                    Section {
                        Text("This will start a new working-title group as v1.")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                if track.workingTitle != nil {
                    Section {
                        Button(role: .destructive) {
                            clearWorkingTitle()
                        } label: {
                            Text("Remove Working Title")
                        }
                    }
                }
            }
            .navigationTitle("Name this version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { commit() }
                        .disabled(trimmedTitle.isEmpty)
                }
            }
        }
        .onAppear {
            draftTitle = track.workingTitle ?? ""
        }
    }

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
