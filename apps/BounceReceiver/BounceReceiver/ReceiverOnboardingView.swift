import SwiftUI
import SwiftData
import BounceKit

/// First launch: full-screen "What's New"-style welcome. Pair opens the pair sheet; Continue Without Pairing enters the library.
struct ReceiverOnboardingView: View {
    var dismissesPairSheet = false
    let onContinueToLibrary: () -> Void

    @State private var showPair = OnboardingShot.opensPairSheet

    private struct Feature: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private let features = [
        Feature(symbol: "square.stack.3d.up", title: "Keep every version",
                detail: "Organize your demos, compare different mixes, and revisit earlier versions."),
        Feature(symbol: "waveform.badge.plus", title: "Notes as you listen",
                detail: "Leave text or voice notes on your mixes, so you remember what needs work."),
        Feature(symbol: "arrow.triangle.2.circlepath", title: "Always in sync",
                detail: "Keep your entire library synced between Mac and iPhone. No more AirDrop."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome to Bounce")
                        .font(.largeTitle.weight(.bold))
                    Text("A music library for tracks you’re still working on.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 72)
                VStack(alignment: .leading, spacing: 32) {
                    ForEach(features) { feature in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: feature.symbol)
                                .font(.system(size: 28))
                                .foregroundStyle(.tint)
                                .frame(width: 40)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(feature.title)
                                    .font(.headline)
                                Text(feature.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button { showPair = true } label: {
                    Text("Pair with Your Mac")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.vertical, 16)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Button("Continue Without Pairing", action: onContinueToLibrary)
                    .font(.body)
                    .padding(.vertical, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground))
        }
        .onChange(of: dismissesPairSheet) { _, dismisses in
            if dismisses { showPair = false }
        }
        .sheet(isPresented: $showPair) {
            PairMacSheet(
                onPaired: {
                    showPair = false
                    onContinueToLibrary()
                },
                onCancel: { showPair = false }
            )
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Pair sheet

/// Sheet: nearby Macs -> code -> brief success, all inside one navigation stack so
/// Cancel stays in place. Reuses `DownloadManager.pair`.
struct PairMacSheet: View {
    let link: PairingLink?
    let onPaired: () -> Void
    let onCancel: () -> Void

    private enum Phase { case list, scan, connecting, code, paired }

    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selected: DiscoveredPeer? = OnboardingShot.step == .code || OnboardingShot.step == .paired
        ? OnboardingShot.fakePeer : nil
    @State private var nonce: Data? = OnboardingShot.step == .code ? Data() : nil
    @State private var phase: Phase

    init(
        link: PairingLink? = nil,
        startsWithScanner: Bool = false,
        onPaired: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.link = link
        self.onPaired = onPaired
        self.onCancel = onCancel
        let initialPhase: Phase = switch OnboardingShot.step {
        case .code: .code
        case .paired: .paired
        default: startsWithScanner && link == nil ? .scan : .list
        }
        _phase = State(initialValue: initialPhase)
    }
    @State private var pairError: String?
    @State private var pairTask: Task<Void, Never>?
    @State private var checkTrigger = 0

    private var nearby: [DiscoveredPeer] {
        (OnboardingShot.step != nil ? [OnboardingShot.fakePeer] : downloadManager.discoveredPeers).filter {
            !downloadManager.bondedPeerStore.contains(id: $0.id)
        }
    }

    private var code: String {
        if let fake = OnboardingShot.fakeCode { return fake }
        guard let nonce else { return "" }
        return PairRequest.verificationCode(deviceID: downloadManager.transport.deviceID, nonce: nonce)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .list: peerList
                case .scan: scanScreen
                case .connecting: connectingScreen
                case .code: codeScreen
                case .paired: pairedScreen
                }
            }
            .navigationTitle("Pair Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if phase != .paired {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") {
                            pairTask?.cancel()
                            onCancel()
                        }
                    }
                }
            }
        }
        .presentationBackground(Color(.systemBackground))
        .interactiveDismissDisabled(phase == .paired)
        .task {
            downloadManager.transport.beginDiscovery()
            if let link, selected == nil { startFromLink(link) }
        }
    }

    // MARK: Phases

    private var peerList: some View {
        List {
            Section {
                if nearby.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Looking for Macs\u{2026}")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(nearby) { peer in
                    Button {
                        start(peer)
                    } label: {
                        HStack {
                            Label {
                                Text(peer.name).foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Nearby Macs")
            } footer: {
                Text("Open Bounce on your Mac. It shows up here. Mac and iPhone need to be on the same Wi-Fi.")
            }
            Section {
                Button {
                    phase = .scan
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                }
            } footer: {
                Text("Scan the code in Bounce on your Mac. Works on the iPhone\u{2019}s hotspot too.")
            }
            Section {
                GetMacAppHint(isMacFound: !nearby.isEmpty)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var scanScreen: some View {
        PairingCodeScanner { scanned in
            guard phase == .scan else { return }
            startFromLink(scanned)
        }
    }

    private var connectingScreen: some View {
        VStack(spacing: 12) {
            Spacer()
            if let pairError {
                Text(pairError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                BouncePlainButton(title: "Try Again", action: reset)
            } else {
                ProgressView()
                Text("Connecting to \(selected?.name ?? "your Mac")\u{2026}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Mac and iPhone need to be on the same Wi-Fi or the iPhone\u{2019}s hotspot.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    private var codeScreen: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Confirm this code on \(selected?.name ?? "your Mac")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(code)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .tracking(8)
                .foregroundStyle(.primary)
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
            Spacer()
            Group {
                if let pairError {
                    VStack(spacing: 8) {
                        Text(pairError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                        BouncePlainButton(title: "Try Again", action: reset)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for Mac\u{2026}")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    private var pairedScreen: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, options: .nonRepeating, value: checkTrigger)
            Text("Paired with \(selected?.name ?? "your Mac")")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .task {
            if !reduceMotion { checkTrigger += 1 }
            if OnboardingShot.step == .paired { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            onPaired()
        }
    }

    // MARK: Actions

    private static func failureText(_ error: Error) -> String {
        switch error {
        case SyncError.pairingFailed, SyncError.connectionFailed:
            "\(error.localizedDescription). Check that both are on the same Wi-Fi and try again."
        default:
            error.localizedDescription
        }
    }

    private func reset() {
        pairTask?.cancel()
        selected = nil
        nonce = nil
        pairError = nil
        phase = .list
    }

    private static let linkCodeFallbackDelay: Duration = .seconds(5)

    private func startFromLink(_ link: PairingLink) {
        let nonce = PairRequest.freshNonce()
        self.nonce = nonce
        pairError = nil
        selected = DiscoveredPeer(id: link.macDeviceID, name: link.macName)
        phase = .connecting
        pairTask = Task {
            var codeFallback: Task<Void, Error>?
            defer { codeFallback?.cancel() }
            do {
                let paired = try await downloadManager.pair(with: link, nonce: nonce) {
                    codeFallback = Task {
                        try await Task.sleep(for: Self.linkCodeFallbackDelay)
                        if phase == .connecting { phase = .code }
                    }
                }
                guard !Task.isCancelled else { return }
                guard paired else {
                    pairError = "Couldn\u{2019}t find \(link.macName). Open Bounce on it and join the same Wi-Fi or the iPhone\u{2019}s hotspot."
                    return
                }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { phase = .paired }
            } catch {
                guard !Task.isCancelled else { return }
                pairError = Self.failureText(error)
            }
        }
    }

    private func start(_ peer: DiscoveredPeer) {
        guard selected == nil else { return }
        let nonce = PairRequest.freshNonce()
        self.nonce = nonce
        pairError = nil
        selected = peer
        phase = .code
        pairTask = Task {
            do {
                try await downloadManager.pair(with: peer, nonce: nonce)
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { phase = .paired }
            } catch {
                guard !Task.isCancelled else { return }
                pairError = Self.failureText(error)
            }
        }
    }
}
