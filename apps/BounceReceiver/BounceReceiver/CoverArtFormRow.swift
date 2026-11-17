import SwiftUI
import PhotosUI
import UIKit

/// Shared cover-art picker row for Form edit sheets.
/// Horizontal thumb + picker avoids the large centered preview getting clipped
/// by grouped Form section margins.
struct CoverArtFormRow: View {
    let image: UIImage?
    @Binding var selectedPhotoItem: PhotosPickerItem?
    var pickerLabel: String
    var pickerSystemImage: String

    init(
        image: UIImage?,
        selectedPhotoItem: Binding<PhotosPickerItem?>,
        pickerLabel: String = "Choose Image",
        pickerSystemImage: String = "photo.badge.plus"
    ) {
        self.image = image
        self._selectedPhotoItem = selectedPhotoItem
        self.pickerLabel = pickerLabel
        self.pickerSystemImage = pickerSystemImage
    }

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Label(pickerLabel, systemImage: pickerSystemImage)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
