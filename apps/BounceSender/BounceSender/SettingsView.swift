import SwiftUI
import AppKit
import ServiceManagement
import BounceKit

/// Native macOS Settings window (⌘,): a toolbar tab bar over grouped `Form`s,
/// native controls only.
///
/// Every control binds to the same `BouncePreferenceKey` defaults already used
/// by the menu or panel it mirrors, so the two stay in sync and existing
/// values survive.
struct SettingsView: View {
    private enum Tab: Hashable {
        case general
        case sync
        case library
        case about
    }

    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)

            SyncSettingsView()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                .tag(Tab.sync)

            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "list.bullet") }
                .tag(Tab.library)

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: 480)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @AppStorage(BouncePreferenceKey.showMenuBarItem) private var showMenuBarItem = BouncePreferenceDefault.showMenuBarItem

    @State private var loginItemStatus: SMAppService.Status = SMAppService.mainApp.status
    @State private var loginItemError: String?

    private var loginItemIsOn: Bool {
        loginItemStatus == .enabled || loginItemStatus == .requiresApproval
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show menu bar item", isOn: $showMenuBarItem)
                Toggle("Start at login", isOn: Binding(
                    get: { loginItemIsOn },
                    set: { setLaunchAtLogin($0) }
                ))

                if loginItemStatus == .requiresApproval {
                    Button("Open Login Items Settings…") {
                        openLoginItemsSettings()
                    }
                }

                if let loginItemError {
                    Text(loginItemError)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } footer: {
                if loginItemStatus == .requiresApproval {
                    Text("Approve Bounce in Login Items to finish.")
                }
            }

            DevSettingsSection()
        }
        .formStyle(.grouped)
        .onAppear {
            refreshLoginItemStatus()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if loginItemStatus != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItemStatus()
    }

    private func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
    }

    private func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Sync

private struct SyncSettingsView: View {
    @Environment(TransferManager.self) private var transferManager

    @State private var peerToForget: BondedPeer?

    var body: some View {
        Form {
            Section("Paired iPhones") {
                if transferManager.bondedPeerStore.peers.isEmpty {
                    Text("No iPhone paired")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(transferManager.bondedPeerStore.peers) { peer in
                        PairedDeviceRow(peer: peer) { peerToForget = peer }
                    }
                }
            }

            Section("iPhone App") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bounce for iPhone")
                        Text("Scan with your iPhone camera to join the Bounce beta on TestFlight, then open it to pair.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(BounceConstants.iPhoneAppURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    if let qr = QRCodeImage.make(transferManager.pairingURL?.absoluteString ?? BounceConstants.iPhoneAppURL) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 88, height: 88)
                            .padding(6)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("QR code to pair the Bounce iPhone app with this Mac")
                    }
                }
            }

            Section("This Mac") {
                LabeledContent("Device name", value: transferManager.deviceName)
                if DevFeatures.isEnabled {
                    LabeledContent("Sync lane", value: BounceConstants.isDevelopmentBuild ? "Development" : "Production")
                    LabeledContent("Device ID", value: transferManager.deviceID.uuidString)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .alert(
            "Forget \(peerToForget?.name ?? "this iPhone")?",
            isPresented: Binding(
                get: { peerToForget != nil },
                set: { if !$0 { peerToForget = nil } }
            ),
            presenting: peerToForget
        ) { peer in
            Button("Forget", role: .destructive) {
                Task { await transferManager.forgetPeer(peer.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { peer in
            Text("\(peer.name) will need to pair again before syncing.")
        }
    }
}

/// One bonded iPhone: name, live status or last-seen time, Forget action.
private struct PairedDeviceRow: View {
    let peer: BondedPeer
    let onForget: () -> Void

    @Environment(TransferManager.self) private var transferManager

    private var isLive: Bool {
        guard transferManager.connectedDeviceID == peer.id else { return false }
        switch transferManager.connectionState {
        case .connected, .idle, .syncing:
            return true
        default:
            return false
        }
    }

    private var presentation: SyncStatusPresentation {
        SyncStatusMapper.presentation(
            state: transferManager.connectionState,
            isUnpaired: false,
            isSyncing: transferManager.connectionState == .syncing,
            role: .sender
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if isLive {
                        Circle()
                            .fill(presentation.color)
                            .frame(width: 7, height: 7)
                        Text(presentation.label)
                    } else {
                        Text("Last seen \(peer.lastSeenAt.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Forget…", action: onForget)
        }
    }
}

// MARK: - Library

private struct LibrarySettingsView: View {
    @AppStorage(BouncePreferenceKey.allTracksSortMode) private var sortModeRaw = BouncePreferenceDefault.allTracksSortMode
    @AppStorage(BouncePreferenceKey.showReleasesTab) private var showReleasesTab = BouncePreferenceDefault.showReleasesTab
    @AppStorage(BouncePreferenceKey.showSetsTab) private var showSetsTab = BouncePreferenceDefault.showSetsTab
    @AppStorage(BouncePreferenceKey.detailsVisibleByDefault) private var detailsVisibleByDefault = BouncePreferenceDefault.detailsVisibleByDefault
    @AppStorage(BouncePreferenceKey.detailsVisible) private var detailsVisible = BouncePreferenceDefault.detailsVisible

    private var mediaDirectory: URL {
        ImportCoordinator.audioDirectory()
    }

    var body: some View {
        Form {
            Section("Sidebar") {
                Toggle("Show Releases tab", isOn: $showReleasesTab)
                Toggle(RecordingsCopy.settingsToggle, isOn: $showSetsTab)
            }

            Section("Tracks") {
                Picker("Sort All Tracks by", selection: $sortModeRaw) {
                    ForEach(AllTracksSortMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Open details pane at launch", isOn: Binding(
                    get: { detailsVisibleByDefault },
                    set: { newValue in
                        detailsVisibleByDefault = newValue
                        detailsVisible = newValue
                    }
                ))
            }

            Section("Storage") {
                LabeledContent("Media folder") {
                    HStack(spacing: 8) {
                        Text((mediaDirectory.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(mediaDirectory.path(percentEncoded: false))
                        Button("Reveal in Finder") {
                            revealMediaFolder()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func revealMediaFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: mediaDirectory.path(percentEncoded: false))
    }
}

// MARK: - About

private struct AboutSettingsView: View {
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Bounce"
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    private var lane: String {
        BounceConstants.isDevelopmentBuild ? "Development" : "Production"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
                        .resizable()
                        .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(appName)
                            .font(.headline)
                        Text("Version \(version) (\(build))")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }

            if DevFeatures.isEnabled {
                Section {
                    LabeledContent("Build lane", value: lane)
                }
            }
        }
        .formStyle(.grouped)
    }
}
