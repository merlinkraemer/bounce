import SwiftUI
import SwiftData
import PhotosUI
import UIKit
import BounceKit

struct EditPlaylistSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(DownloadManager.self) private var downloadManager

    let playlist: Playlist

    @State private var name: String
    @State private var artist: String
    @State private var description: String
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var coverImage: UIImage?
    @State private var showRemoveCoverConfirm = false
    @State private var coverChanged = false

    init(playlist: Playlist) {
        self.playlist = playlist
        _name = State(initialValue: playlist.name)
        _artist = State(initialValue: playlist.artist ?? "")
        _description = State(initialValue: playlist.playlistDescription ?? "")
        if let data = playlist.coverImageData, let image = UIImage(data: data) {
            _coverImage = State(initialValue: image)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Artist", text: $artist)
                } header: {
                    Text("Playlist")
                }

                Section {
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Description")
                }

                Section {
                    CoverArtFormRow(
                        image: coverImage,
                        selectedPhotoItem: $selectedPhotoItem,
                        pickerLabel: coverImage == nil ? "Add Cover" : "Change Cover",
                        pickerSystemImage: coverImage == nil ? "photo.badge.plus" : "photo"
                    )

                    if coverImage != nil {
                        Button(role: .destructive) {
                            showRemoveCoverConfirm = true
                        } label: {
                            Label("Remove Cover", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("Cover Art")
                }
            }
            .navigationTitle("Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { saveAndDismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Remove Cover?", isPresented: $showRemoveCoverConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    coverImage = nil
                    coverChanged = true
                }
            } message: {
                Text("This removes the cover art from this playlist.")
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            coverImage = image
                            coverChanged = true
                        }
                    }
                }
            }
        }
    }

    private func saveAndDismiss() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        playlist.name = trimmedName
        playlist.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        playlist.playlistDescription = trimmedDescription.isEmpty ? nil : trimmedDescription
        if coverChanged {
            playlist.setCoverImage(coverImage?.jpegData(compressionQuality: 0.85))
        }
        playlist.updatedAt = .now

        do {
            try modelContext.save()
            if coverChanged {
                downloadManager.notifyPlaylistCoverChanged(playlist.id)
            } else {
                downloadManager.notifyLocalManifestMutated()
            }
        } catch {
            print("[EditPlaylistSheet] ERROR: Failed to save: \(error)")
        }
        dismiss()
    }
}
