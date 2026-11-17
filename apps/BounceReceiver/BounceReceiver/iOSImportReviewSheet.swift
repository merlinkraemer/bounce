import SwiftUI
import SwiftData
import PhotosUI
import BounceKit

struct iOSImportReviewSheet: View {
    @State var group: ImportPlanGroup
    let availableTracks: [ImportTrackOption]
    let onConfirm: (ImportPlanGroup) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhotoItem: PhotosPickerItem?

    private var item: ImportPlanItem { group.items.first! }

    private var isNewTrack: Bool { group.target.isNewTrack }
    private var isUnresolved: Bool { group.target.isUnresolved }

    private var itemBinding: Binding<ImportPlanItem> {
        Binding(
            get: { group.items.first! },
            set: { group.items[0] = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                matchSection
                if isNewTrack {
                    nameSection
                    coverSection
                }
                targetSection
                versionLabelSection
                recordingDateSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Review Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        onConfirm(group)
                        dismiss()
                    }
                    .disabled(!canImport)
                }
            }
        }
    }

    private var matchSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(item.originalFilename)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    matchBadge
                }

                if item.isNearDuplicate && !item.isExactDuplicate {
                    dupBadge(text: "Near-duplicate", color: .orange)
                }

                Text(item.hasDetectedVersion
                     ? "Detected \"\(item.detectedVersionLabel)\" of \"\(item.detectedTrackName)\""
                     : "No version marker detected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var nameSection: some View {
        Section("Track") {
            TextField("Track name", text: $group.editableTrackName)
        }
    }

    private var versionLabelSection: some View {
        Section("Version") {
            TextField("Version label", text: itemBinding.editableVersionLabel)
        }
    }

    private var recordingDateSection: some View {
        Section("Recording date") {
            DatePicker("Date", selection: dateBinding, displayedComponents: .date)
            Button("Clear date", role: .destructive) {
                group.recordingDateString = nil
                group.recordingDateIsExplicit = true
            }
        }
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { RecordingDate.date(from: group.recordingDateString) ?? .now },
            set: {
                group.recordingDateString = RecordingDate.string(from: $0)
                group.recordingDateIsExplicit = true
            }
        )
    }

    private var targetSection: some View {
        Section {
            if item.isExactDuplicate {
                Text("This file is already in your library.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Import as", selection: targetSelectionBinding) {
                    Text("New track").tag(TargetSelection.newTrack)
                    Text("Add to existing").tag(TargetSelection.existingPlaceholder)
                }
                .pickerStyle(.segmented)

                if !isNewTrack {
                    Picker("Target track", selection: existingTargetBinding) {
                        Text("Choose track").tag(Optional<UUID>.none)
                        ForEach(availableTracks) { track in
                            Text(track.menuLabel).tag(Optional(track.id))
                        }
                    }
                }

                if item.mixVsVersionAmbiguous {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle")
                        Text("Filename ends with a number — treated as a mix. Switch to \"New track\" if it's actually a separate version.")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private var coverSection: some View {
        let coverImage = (group.selectedCoverArt ?? group.extractedArtwork).flatMap { UIImage(data: $0) }
        return Section {
            CoverArtFormRow(
                image: coverImage,
                selectedPhotoItem: $selectedPhotoItem,
                pickerLabel: coverImage == nil ? "Add Cover" : "Change Cover",
                pickerSystemImage: coverImage == nil ? "photo.badge.plus" : "photo"
            )
            .onChange(of: selectedPhotoItem) { _, newValue in
                Task {
                    if let data = try? await newValue?.loadTransferable(type: Data.self) {
                        group.selectedCoverArt = data
                    }
                }
            }
        }
    }

    private enum TargetSelection: Hashable {
        case newTrack
        case existingPlaceholder
    }

    private var targetSelectionBinding: Binding<TargetSelection> {
        Binding(
            get: { isNewTrack ? .newTrack : .existingPlaceholder },
            set: { selection in
                switch selection {
                case .newTrack:
                    group.target = .newTrack
                case .existingPlaceholder:
                    if case .existingTrack = group.target { return }
                    group.target = .unresolved
                }
            }
        )
    }

    private var existingTargetBinding: Binding<UUID?> {
        Binding(
            get: { group.target.resolvedTrackID },
            set: { newValue in
                if let id = newValue {
                    group.target = .existingTrack(id)
                } else {
                    group.target = .unresolved
                }
            }
        )
    }

    private var matchBadge: some View {
        let (label, color) = matchBadgeInfo
        return Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var matchBadgeInfo: (String, Color) {
        if item.isExactDuplicate { return ("Already in library", .gray) }
        switch item.matchKind {
        case .workingTitlePrefix: return ("Working-title match", .green)
        case .dateStem: return ("Date-stem match", .blue)
        case .ambiguous: return ("Multiple matches", .orange)
        case .none: return ("New track", .secondary)
        }
    }

    private func dupBadge(text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
            Text(text)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
    }

    private var canImport: Bool {
        if item.skip { return false }
        if item.isExactDuplicate { return false }
        if isUnresolved { return false }
        return true
    }
}
