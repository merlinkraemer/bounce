import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit
import BounceKit

/// Modal for creating or editing a playlist. Pass nil to create new, pass a Playlist to edit.
struct PlaylistEditSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let playlist: Playlist?
    let folder: PlaylistFolder?
    var onSaved: ((Playlist) -> Void)? = nil

    @State private var name: String = ""
    @State private var artist: String = ""
    @State private var description: String = ""
    @State private var coverImageData: Data?
    @State private var draftCoverID = UUID()
    @State private var isDropTargeted = false
    @State private var isCoverHovered = false

    private var isEditing: Bool { playlist != nil }
    private var coverCacheID: UUID { playlist?.id ?? draftCoverID }

    var body: some View {
        VStack(spacing: 0) {
            Text(isEditing ? "Edit Playlist" : "New Playlist")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 12) {
                GridRow {
                    GetInfoLabel("Name:")
                    TextField("Playlist name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    GetInfoLabel("Artist:")
                    TextField("Artist name", text: $artist)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    GetInfoLabel("Description:")
                    TextField("Description", text: $description, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...3)
                }
                GridRow(alignment: .center) {
                    GetInfoLabel("Cover:")
                    HStack(spacing: 12) {
                        coverArtView
                            .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 6) {
                            Button("Choose\u{2026}") { openImagePicker() }
                            if coverImageData != nil {
                                Button("Remove") { coverImageData = nil }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 20)

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loadFromPlaylist() }
    }

    // MARK: - Cover Art

    private var coverArtView: some View {
        ZStack {
            if let data = coverImageData,
               let img = ArtworkThumbnailCache.thumbnail(data, id: coverCacheID, side: 64) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                Color(.quaternarySystemFill)

                if isCoverHovered {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 18))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                } else {
                    Image("MusicNoteIcon").renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
            }

            if isDropTargeted {
                Color.accentColor.opacity(0.2)
                RoundedRectangle(cornerRadius: BounceConstants.panelCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: BounceConstants.panelCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BounceConstants.panelCornerRadius, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isCoverHovered = $0 }
        .onTapGesture { openImagePicker() }
        .onDrop(of: [UTType.image, UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .help("Click to pick an image, or drag one here")
    }

    // MARK: - Load / Save

    private func loadFromPlaylist() {
        guard let p = playlist else { return }
        name = p.name
        artist = p.artist ?? ""
        description = p.playlistDescription ?? ""
        coverImageData = p.coverImageData
    }

    private func save() {
        guard let savedPlaylist = commitDraft() else { return }
        onSaved?(savedPlaylist)
        dismiss()
    }

    /// Write draft values back to the model.
    @discardableResult
    private func commitDraft() -> Playlist? {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return nil }

        let savedPlaylist: Playlist
        if let existing = playlist {
            existing.name = trimmedName
            existing.artist = artist.trimmingCharacters(in: .whitespaces).isEmpty ? nil : artist.trimmingCharacters(in: .whitespaces)
            existing.playlistDescription = description.trimmingCharacters(in: .whitespaces).isEmpty ? nil : description.trimmingCharacters(in: .whitespaces)
            existing.setCoverImage(coverImageData)
            existing.updatedAt = .now
            savedPlaylist = existing
        } else {
            let new = Playlist(
                name: trimmedName,
                coverImageData: coverImageData,
                artist: artist.trimmingCharacters(in: .whitespaces).isEmpty ? nil : artist.trimmingCharacters(in: .whitespaces),
                playlistDescription: description.trimmingCharacters(in: .whitespaces).isEmpty ? nil : description.trimmingCharacters(in: .whitespaces)
            )
            if let folder = folder {
                new.folder = folder
            }
            modelContext.insert(new)
            savedPlaylist = new
        }

        do {
            try modelContext.save()
            return savedPlaylist
        } catch {
            SyncLog.sender.error("Failed to save playlist draft: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Image Handling

    private func openImagePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let img = NSImage(contentsOf: url),
                  let data = ArtworkThumbnailCache.encodedCoverData(from: img) else { return }
            DispatchQueue.main.async { coverImageData = data }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                guard let nsImage = image as? NSImage,
                      let data = ArtworkThumbnailCache.encodedCoverData(from: nsImage) else { return }
                DispatchQueue.main.async { coverImageData = data }
            }
        } else {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let imageURL = url,
                      let nsImage = NSImage(contentsOf: imageURL),
                      let data = ArtworkThumbnailCache.encodedCoverData(from: nsImage) else { return }
                DispatchQueue.main.async { coverImageData = data }
            }
        }
    }
}
