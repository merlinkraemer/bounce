import SwiftUI
import UniformTypeIdentifiers

/// A UIViewControllerRepresentable that presents the system document picker
/// filtered to audio file types.
struct AudioDocumentPicker: UIViewControllerRepresentable {
    let onSelect: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [
            .audio,
            .mp3,
            .wav,
            .aiff,
            .mpeg4Audio,
            UTType("org.xiph.flac") ?? .audio,
            UTType("com.apple.protected-mpeg-4-audio") ?? .audio,
        ]

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSelect: ([URL]) -> Void

        init(onSelect: @escaping ([URL]) -> Void) {
            self.onSelect = onSelect
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onSelect(urls)
        }
    }
}
