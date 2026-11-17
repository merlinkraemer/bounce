#if DEBUG
import SwiftUI
import AppKit

/// DEBUG-only: renders each setup step headlessly so layout can be reviewed without a window.
/// Liquid Glass does not render in ImageRenderer; geometry, spacing and text do.
@MainActor
enum SetupSnapshots {
    private static let sheetBackground = Color(red: 0.137, green: 0.137, blue: 0.149)

    private static let shots: [(name: String, step: SetupShownStep, importedCount: Int)] = [
        ("1-welcome", .welcome, 0),
        ("2-import", .importFiles, 0),
        ("3-import-done", .importFiles, 3),
        ("4-pair", .pair, 0),
        ("5-code", .code, 0),
        ("6-done", .done, 0),
    ]

    static func render(to directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            OnboardingShot.log("cannot create \(directory.path): \(error)")
            return false
        }
        var ok = true
        for shot in shots {
            let layout = SetupLayout(
                step: shot.step,
                importedCount: shot.importedCount,
                deviceName: OnboardingShot.fakeDeviceName,
                code: OnboardingShot.fakeCode ?? "",
                checkShown: true,
                actions: SetupActions()
            )
            .background(sheetBackground)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: layout)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else {
                OnboardingShot.log("render failed: \(shot.name)")
                ok = false
                continue
            }
            do {
                try png.write(to: directory.appendingPathComponent("\(shot.name).png"))
                OnboardingShot.log("wrote \(shot.name).png \(Int(image.size.width))x\(Int(image.size.height))")
            } catch {
                OnboardingShot.log("write failed \(shot.name): \(error)")
                ok = false
            }
        }
        return ok
    }
}
#endif
