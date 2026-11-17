import SwiftUI
import SwiftData
import BounceKit
import AppKit

struct EditTrackSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaybackEngine.self) private var playbackEngine

    let track: Track

    @State private var workingTitle: String
    @State private var artist: String
    @State private var isReleased: Bool
    @AppStorage(BouncePreferenceKey.showSetsTab) private var showRecordings = BouncePreferenceDefault.showSetsTab
    @State private var isSet: Bool
    @State private var artworkData: Data?
    @State private var showRemoveArtworkConfirm = false
    @State private var versionToDelete: Version?
    @State private var draftVersionLabels: [UUID: String] = [:]
    @State private var lastVersionPendingDeletion: Version?

    init(track: Track) {
        self.track = track
        let seedTitle = (track.workingTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? track.workingTitle!
            : track.name
        _workingTitle = State(initialValue: seedTitle)
        _artist = State(initialValue: track.artist)
        _isReleased = State(initialValue: track.isReleased)
        _isSet = State(initialValue: track.isSet)
        _artworkData = State(initialValue: track.artwork)
        
        var labels: [UUID: String] = [:]
        for version in track.versions {
            labels[version.id] = version.label
        }
        _draftVersionLabels = State(initialValue: labels)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit Track")
                    .font(.title2.weight(.semibold))
                Text("Original filename: \(track.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            Form {
                Section("Track Details") {
                    LabeledContent("Working Title") {
                        TextField("e.g. Like Dawn", text: $workingTitle)
                            .labelsHidden()
                    }

                    LabeledContent("Artist") {
                        TextField("Artist", text: $artist)
                            .labelsHidden()
                    }
                }

                Section("Cover Art") {
                    HStack(spacing: 16) {
                        if let data = artworkData,
                           let nsImage = ArtworkThumbnailCache.thumbnail(data, id: track.id, side: 80) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: BounceConstants.panelCornerRadius, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: BounceConstants.panelCornerRadius, style: .continuous)
                                .fill(Color(.quaternarySystemFill))
                                .frame(width: 80, height: 80)
                                .overlay {
                                    Image("MusicNoteIcon").renderingMode(.template)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 40, height: 40)
                                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Button("Change Cover\u{2026}") {
                                changeCover()
                            }

                            if artworkData != nil {
                                Button("Remove Cover") {
                                    showRemoveArtworkConfirm = true
                                }
                            }
                        }
                    }
                }

                Section {
                    Toggle("Mark as Released", isOn: $isReleased)
                } footer: {
                    Text("Released versions appear in the Releases tab.")
                }

                Section("Mixes") {
                    let sortedMixes = track.versions.sorted(by: { $0.addedAt > $1.addedAt })
                    if sortedMixes.isEmpty {
                        Text("No mixes yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(sortedMixes.enumerated()), id: \.element.id) { _, version in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    let labelBinding = Binding(
                                        get: { draftVersionLabels[version.id] ?? version.label },
                                        set: { draftVersionLabels[version.id] = $0 }
                                    )
                                    TextField("Label", text: labelBinding)
                                        .textFieldStyle(.plain)
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

                                Spacer()

                                Button {
                                    versionToDelete = version
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Delete Mix")
                            }
                        }
                    }
                }

                if showRecordings {
                    Section {
                        Toggle(RecordingsCopy.longRecording, isOn: $isSet)
                    } footer: {
                        Text(RecordingsCopy.editFooterMac)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveAndDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(workingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520, height: 620)
        .alert("Remove Cover?", isPresented: $showRemoveArtworkConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                artworkData = nil
            }
        } message: {
            Text("This will remove the cover art from this track.")
        }
        .alert(
            "Delete \(versionToDelete?.label ?? "mix")?",
            isPresented: Binding(
                get: { versionToDelete != nil },
                set: { if !$0 { versionToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { versionToDelete = nil }
            Button("Delete", role: .destructive) {
                if let v = versionToDelete { deleteMix(v) }
                versionToDelete = nil
            }
        } message: {
            Text("This removes the bounce file from disk.")
        }
        .onDisappear {
            if let version = lastVersionPendingDeletion {
                deleteLastMixAndTrack(version)
            }
        }
    }

    private func changeCover() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let fileData = try? Data(contentsOf: url),
               let encoded = ArtworkThumbnailCache.encodedCoverData(from: fileData) {
                artworkData = encoded
            } else if let img = NSImage(contentsOf: url),
                      let encoded = ArtworkThumbnailCache.encodedCoverData(from: img) {
                artworkData = encoded
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
        track.updatedAt = .now
        track.lastTouchedAt = .now
        track.setArtwork(artworkData)

        // Apply draft version label changes
        for (versionID, newLabel) in draftVersionLabels {
            if let version = track.versions.first(where: { $0.id == versionID }) {
                version.label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        do {
            try modelContext.save()
        } catch {
            SyncLog.sender.error("Failed to save track edit: \(error.localizedDescription, privacy: .public)")
        }
        dismiss()
    }

    private func deleteMix(_ version: Version) {
        if playbackEngine.loadedVersionID == version.id {
            playbackEngine.stop()
        }

        if track.versions.count <= 1 {
            lastVersionPendingDeletion = version
            dismiss()
            return
        }

        let paths = modelContext.deleteVersion(version, of: track)
        track.updatedAt = .now
        track.lastTouchedAt = .now
        saveDeletion(removing: paths)
    }

    private func deleteLastMixAndTrack(_ version: Version) {
        saveDeletion(removing: modelContext.deleteVersion(version, of: track))
    }

    private func saveDeletion(removing paths: [String]) {
        do {
            try modelContext.save()
            modelContext.removeUnreferencedFiles(atPaths: paths)
        } catch {
            SyncLog.sender.error("Failed to delete mix: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
