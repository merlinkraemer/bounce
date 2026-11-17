import SwiftUI
import SwiftData
import PhotosUI
import BounceKit
import UIKit

struct EditTrackSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(DownloadManager.self) private var downloadManager

    let track: Track

    @State private var name: String
    @State private var artist: String
    @State private var workingTitle: String
    @State private var isReleased: Bool
    @AppStorage(BouncePreferenceKey.showSetsTab) private var showRecordings = BouncePreferenceDefault.showSetsTab
    @State private var isSet: Bool
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var artworkImage: UIImage?
    @State private var pendingArtworkData: Data?
    @State private var artworkChanged = false
    @State private var showRemoveArtworkConfirm = false
    @State private var versionToDelete: Version?
    @State private var versionRemoval: DownloadManager.TrackRemoval = .delete
    @State private var mixLabels: [UUID: String]

    init(track: Track) {
        self.track = track
        _name = State(initialValue: track.name)
        _artist = State(initialValue: track.artist)
        let seedTitle = (track.workingTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? track.workingTitle!
            : track.name
        _workingTitle = State(initialValue: seedTitle)
        _isReleased = State(initialValue: track.isReleased)
        _isSet = State(initialValue: track.isSet)
        _mixLabels = State(initialValue: Dictionary(track.versions.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first }))
        if let data = track.artwork, let img = UIImage(data: data) {
            _artworkImage = State(initialValue: img)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $workingTitle)
                    TextField("Artist", text: $artist)
                } header: {
                    Text("Track")
                } footer: {
                    Text("Original filename: \(track.name)")
                }

                Section {
                    CoverArtFormRow(
                        image: artworkImage,
                        selectedPhotoItem: $selectedPhotoItem,
                        pickerLabel: artworkImage == nil ? "Add Cover" : "Change Cover",
                        pickerSystemImage: artworkImage == nil ? "photo.badge.plus" : "photo"
                    )

                    if artworkImage != nil {
                        Button(role: .destructive) {
                            showRemoveArtworkConfirm = true
                        } label: {
                            Label("Remove Cover", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("Cover Art")
                }

                Section {
                    Toggle("Mark as Released", isOn: $isReleased)
                } footer: {
                    Text("Released versions appear in the Releases tab.")
                }

                if showRecordings {
                    Section {
                        Toggle(RecordingsCopy.longRecording, isOn: $isSet)
                    } footer: {
                        Text(RecordingsCopy.editFooterIOS)
                    }
                }

                Section {
                    let sortedMixes = track.versions.sorted(by: { $0.addedAt > $1.addedAt })
                    if sortedMixes.isEmpty {
                        Text("No mixes yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedMixes) { version in
                            VersionRow(version: version, label: mixLabelBinding(for: version))
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if let removal = downloadManager.removal(for: version, of: track) {
                                        Button(role: .destructive) {
                                            versionRemoval = removal
                                            versionToDelete = version
                                        } label: {
                                            Image(systemName: TrackRemovalCopy.systemImage(removal))
                                        }
                                        .accessibilityLabel((removal == .removeDownload ? "Remove Download" : "Delete Mix") as String)
                                    }
                                }
                        }
                    }
                } header: {
                    Text("Mixes")
                } footer: {
                    Text("Each mix is a separate bounce you can A/B inside this track.")
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                TrackRemovalCopy.confirmTitle(versionRemoval, name: versionToDelete?.label ?? "mix"),
                isPresented: Binding(
                    get: { versionToDelete != nil },
                    set: { if !$0 { versionToDelete = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { versionToDelete = nil }
                Button(TrackRemovalCopy.actionTitle(versionRemoval), role: .destructive) {
                    if let v = versionToDelete { removeMix(v) }
                    versionToDelete = nil
                }
            } message: {
                Text((versionRemoval == .removeDownload
                    ? "The mix stays listed with its notes. Its audio is removed from this iPhone until you download it again."
                    : "This removes the bounce file from this iPhone.") as String)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveAndDismiss()
                    }
                }
            }
            .alert("Remove Cover?", isPresented: $showRemoveArtworkConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    artworkImage = nil
                    pendingArtworkData = nil
                    artworkChanged = true
                }
            } message: {
                Text("This removes the cover art from this track.")
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        artworkImage = img
                        pendingArtworkData = data
                        artworkChanged = true
                    }
                }
            }
        }
    }

    private func saveAndDismiss() {
        track.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)

        let trimmedTitle = workingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed: String = (track.workingTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? track.workingTitle!
            : track.name
        if trimmedTitle.isEmpty {
            track.workingTitle = nil
        } else if trimmedTitle != seed {
            track.workingTitle = trimmedTitle
        }

        track.isReleased = isReleased
        track.isSet = isSet
        for version in track.versions {
            guard let draft = mixLabels[version.id] else { continue }
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != version.label { version.label = trimmed }
        }
        track.updatedAt = .now
        track.lastTouchedAt = .now

        if artworkChanged {
            track.setArtwork(pendingArtworkData)
        }

        do {
            try modelContext.save()
        } catch {
            print("[EditTrackSheet] ERROR: Failed to save: \(error)")
        }
        dismiss()
    }

    private func mixLabelBinding(for version: Version) -> Binding<String> {
        Binding(
            get: { mixLabels[version.id] ?? version.label },
            set: { mixLabels[version.id] = $0 }
        )
    }

    private func removeMix(_ version: Version) {
        switch versionRemoval {
        case .removeDownload:
            downloadManager.removeDownload(for: version)
        case .delete:
            downloadManager.deleteLocalVersion(version, of: track)
        }
    }
}

private struct VersionRow: View {
    let version: Version
    @Binding var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Label", text: $label)
                .font(.body)

            HStack(spacing: 8) {
                Text(version.addedAt.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if version.duration > 0 {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Text(formatDuration(version.duration))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
