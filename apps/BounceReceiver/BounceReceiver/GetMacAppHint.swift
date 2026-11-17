import SwiftUI
import BounceKit

/// Shown in the pair sheet while no Mac is found: a quiet footer first, then
/// a card after `cardDelay` without a Mac.
struct GetMacAppHint: View {
    let isMacFound: Bool

    @State private var showsCard = false

    private static let cardDelay: Duration = .seconds(10)

    var body: some View {
        Group {
            if isMacFound {
                EmptyView()
            } else if showsCard {
                card
            } else {
                footer
            }
        }
        .task(id: isMacFound) {
            showsCard = false
            guard !isMacFound else { return }
            try? await Task.sleep(for: Self.cardDelay)
            if !Task.isCancelled { showsCard = true }
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("No Bounce on your Mac yet? Get it at onbounce.app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SendLinkToMacButton(prominent: false)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private var card: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tint)
            Text("Need Bounce for Mac?")
                .font(.headline)
            Text("Bounce on your Mac holds your library. Get it at onbounce.app, then open it on the same Wi-Fi.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SendLinkToMacButton(prominent: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SendLinkToMacButton: View {
    let prominent: Bool

    var body: some View {
        if let url = BounceConstants.macAppDownloadURL {
            ShareLink(item: url) { label }
                .buttonStyle(.plain)
        } else {
            Button(action: {}) { label }
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var label: some View {
        if prominent {
            Label("Send Link to Mac", systemImage: "square.and.arrow.up")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            Label("Send Link to Mac", systemImage: "square.and.arrow.up")
                .font(.subheadline)
                .foregroundStyle(.tint)
                .frame(minHeight: 44)
        }
    }
}
