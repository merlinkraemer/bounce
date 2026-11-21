import SwiftUI
import AVFoundation
import VisionKit
import BounceKit

struct PairingCodeScanner: View {
    let onScan: (PairingLink) -> Void

    private enum Access { case checking, ready, denied, unsupported }

    @State private var access: Access = .checking
    @State private var message: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            switch access {
            case .checking:
                ProgressView()
            case .ready:
                QRDataScanner(onPayload: handle)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) { hint }
            case .denied:
                unavailable("Allow camera access in Settings to scan the code.") {
                    BouncePlainButton(title: "Open Settings", action: openSettings)
                }
            case .unsupported:
                unavailable("This iPhone can\u{2019}t scan here. Scan the code with the Camera app instead.") {
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { access = await Self.requestAccess() }
    }

    private var hint: some View {
        Text(message ?? "Point at the code in Bounce on your Mac.")
            .font(.footnote)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
    }

    private func unavailable<Action: View>(_ text: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 12) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            action()
        }
        .padding(.horizontal, 24)
    }

    private func handle(_ payload: String) {
        guard let url = URL(string: payload) else {
            message = "Not a Bounce pairing code."
            return
        }
        do {
            onScan(try PairingLink.parse(url))
        } catch PairingLinkError.laneMismatch {
            message = "This code is for a different Bounce app."
        } catch {
            message = "Not a Bounce pairing code."
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    @MainActor
    private static func requestAccess() async -> Access {
        guard DataScannerViewController.isSupported else { return .unsupported }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { return .denied }
        default:
            return .denied
        }
        return DataScannerViewController.isAvailable ? .ready : .denied
    }
}

private struct QRDataScanner: UIViewControllerRepresentable {
    let onPayload: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onPayload = onPayload
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onPayload: (String) -> Void

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    onPayload(payload)
                    return
                }
            }
        }
    }
}
