import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import BounceKit

// MARK: - Constants & show rules

enum SetupPrefs {
    /// Set only on an explicit user choice (Later on the last step, Esc, Open Library).
    /// App quit / sheet teardown must NOT set it. Key name kept from the old welcome window.
    static let dismissedKey = "bounce.mac.welcomeDismissed"
    /// Set once a pair request has been approved on this Mac.
    static let everPairedKey = "bounce.mac.hasEverPairedDevice"

    /// Show rules: empty library, never paired, not dismissed. DEBUG `-showWelcome` forces it.
    @MainActor
    static func isDue(transferManager: TransferManager, container: ModelContainer) -> Bool {
        #if DEBUG
        if CommandLine.arguments.contains("-showWelcome") { return true }
        #endif
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: dismissedKey) { return false }
        if defaults.bool(forKey: everPairedKey) { return false }
        if !transferManager.bondedPeerStore.peers.isEmpty { return false }
        guard let count = try? container.mainContext.fetchCount(FetchDescriptor<Track>()) else { return false }
        return count == 0
    }

    /// Help → "Set Up Bounce…": survives the library window not existing yet.
    @MainActor private static var requested = false

    @MainActor
    static func requestSetup() {
        requested = true
        NotificationCenter.default.post(name: .setupRequested, object: nil)
    }

    @MainActor
    static func takeRequest() -> Bool {
        defer { requested = false }
        return requested
    }
}

extension Notification.Name {
    /// An import is waiting in `ImportHandoff.pending` for the library window.
    static let importRequestPending = Notification.Name("bounce.importRequestPending")
    /// An import was scheduled (fast path or confirmed review sheet); `userInfo["count"]` is the file count.
    static let setupImportFinished = Notification.Name("bounce.setupImportFinished")
    /// Help → "Set Up Bounce…" asked for the setup sheet.
    static let setupRequested = Notification.Name("bounce.setupRequested")
}

enum ImportRequest {
    case picker
    case drop([URL])
}

/// Imports started outside the library view (setup sheet, empty-library state)
/// run in the library window, which owns the import pipeline and review sheet.
@MainActor
enum ImportHandoff {
    static var pending: ImportRequest?

    static func send(_ request: ImportRequest) {
        switch request {
        case .drop(let urls):
            let external = DragExportFile.excludingOwnExports(urls)
            guard !external.isEmpty else { return }
            pending = .drop(external)
        case .picker:
            pending = request
        }
        NotificationCenter.default.post(name: .importRequestPending, object: nil)
    }

    static func take() -> ImportRequest? {
        defer { pending = nil }
        return pending
    }
}

/// Help → "Set Up Bounce…".
struct SetupCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Set Up Bounce\u{2026}") {
                SetupPrefs.requestSetup()
                openWindow(id: LibraryWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Send Feedback\u{2026}") {
                Feedback.open()
            }
        }
    }
}

// MARK: - Model

/// Setup progress. Owned by the library view; the import pipeline reports into it.
@MainActor @Observable
final class SetupModel {
    enum Step { case welcome, importFiles, pair, done }

    var step: Step = .welcome
    var importedCount = 0

    func reset() {
        step = .welcome
        importedCount = 0
    }
}

// MARK: - Sheet

enum SetupShownStep { case welcome, importFiles, pair, code, done }

private let setupGreen = Color(red: 0.19, green: 0.82, blue: 0.35)

struct SetupActions {
    var getStarted: () -> Void = {}
    var skipImport: () -> Void = {}
    var continueFromImport: () -> Void = {}
    var backToImport: () -> Void = {}
    var finish: () -> Void = {}
    var denyPair: () -> Void = {}
    var approvePair: () -> Void = {}
}

struct SetupSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var checkShown = false
    @State private var displayed: SetupShownStep?
    @State private var contentVisible = true
    @State private var window: NSWindow?
    @State private var transitionTask: Task<Void, Never>?
    let model: SetupModel
    @Binding var isPresented: Bool
    /// Import review is presented as a sheet nested on top of this one, so setup stays visible.
    @Binding var importPlan: ImportPlan?
    let onCancelImport: () -> Void
    let onCommitImport: () -> Void
    let reviewBinding: (ImportPlan) -> Binding<ImportPlan>
    @Environment(TransferManager.self) private var transferManager

    private var pending: PendingPairRequest? { transferManager.pendingPairRequest }

    /// A live pair request always shows the code step, whatever step is underneath.
    private var shown: SetupShownStep {
        if pending != nil { return .code }
        switch model.step {
        case .welcome: return .welcome
        case .importFiles: return .importFiles
        case .pair: return .pair
        case .done: return .done
        }
    }

    private var actions: SetupActions {
        SetupActions(
            getStarted: { model.step = .importFiles },
            skipImport: { model.step = .pair },
            continueFromImport: { model.step = .pair },
            backToImport: { model.step = .importFiles },
            finish: finish,
            denyPair: { transferManager.denyPendingPairRequest() },
            approvePair: approve
        )
    }

    var body: some View {
        SetupLayout(
            step: displayed ?? shown,
            importedCount: model.importedCount,
            deviceName: pending?.request.deviceName,
            code: OnboardingShot.fakeCode ?? pending?.request.verificationCode ?? "",
            checkShown: checkShown,
            actions: actions,
            pairingURL: transferManager.pairingURL
        )
        .opacity(contentVisible ? 1 : 0)
        .background(escapeClose)
        .background(WindowReader(window: $window))
        .onAppear { displayed = shown }
        .onChange(of: shown) { _, target in
            transitionTask?.cancel()
            transitionTask = Task { await present(target) }
        }
        .interactiveDismissDisabled()
        .sheet(item: $importPlan) { plan in
            ImportReviewSheet(plan: reviewBinding(plan), onCancel: onCancelImport, onImport: onCommitImport)
        }
        .onChange(of: transferManager.tokenPairCount) {
            model.step = .done
        }
        .onChange(of: model.importedCount) { old, new in
            // A confirmed import moves setup on to Pair.
            if new > old, model.step == .importFiles { model.step = .pair }
        }
        .task(id: shown) {
            guard shown == .done else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.35)) { checkShown = true }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { finish() }
        }
        .onAppear { transferManager.isSetupSheetOpen = true }
        .onDisappear {
            transferManager.isSetupSheetOpen = false
            // Sheet hidden mid-request: nothing is left to approve it.
            transferManager.denyPendingPairRequest()
        }
    }

    private static let fadeDuration = 0.15
    private static let resizeDuration = 0.3

    /// A step change that alters the sheet height never shows content during the resize: the old
    /// step fades out at the old size, the window resizes while empty, then the new step fades in
    /// at the new size. Same-height changes cross-fade in place.
    private func present(_ target: SetupShownStep) async {
        let from = displayed ?? target
        let targetHeight = SetupLayout.totalHeight(of: target)
        let heightChanges = SetupLayout.totalHeight(of: from) != targetHeight

        if reduceMotion {
            displayed = target
            contentVisible = true
            if heightChanges { resizeWindow(toHeight: targetHeight, animated: false) }
            return
        }
        if !heightChanges {
            withAnimation(.easeInOut(duration: 0.25)) {
                displayed = target
                contentVisible = true
            }
            return
        }

        withAnimation(.easeOut(duration: Self.fadeDuration)) { contentVisible = false }
        try? await Task.sleep(for: .seconds(Self.fadeDuration))
        guard !Task.isCancelled else { return }

        resizeWindow(toHeight: targetHeight, animated: true)
        try? await Task.sleep(for: .seconds(Self.resizeDuration))
        guard !Task.isCancelled else { return }

        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { displayed = target }
        withAnimation(.easeIn(duration: Self.fadeDuration)) { contentVisible = true }
    }

    /// Keeps the top edge fixed, like a sheet hanging from its parent window.
    private func resizeWindow(toHeight height: CGFloat, animated: Bool) {
        guard let window else { return }
        let delta = height - window.contentRect(forFrameRect: window.frame).height
        guard abs(delta) > 0.5 else { return }
        var frame = window.frame
        frame.size.height += delta
        frame.origin.y -= delta
        guard animated else {
            window.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }

    /// Esc closes the sheet from any step, same as Later on the last step.
    private var escapeClose: some View {
        Button("Close") { finish() }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .accessibilityHidden(true)
    }

    private func approve() {
        guard pending != nil else { return }
        transferManager.approvePendingPairRequest()
        model.step = .done
    }

    /// Explicit user exit: never show the setup again unless asked via Help.
    private func finish() {
        UserDefaults.standard.set(true, forKey: SetupPrefs.dismissedKey)
        isPresented = false
    }
}

private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            if window !== view?.window { window = view?.window }
        }
    }
}

// MARK: - Layout

private extension String {
    var withoutOrphan: String {
        guard let lastSpace = lastIndex(of: " ") else { return self }
        var joined = self
        joined.replaceSubrange(lastSpace...lastSpace, with: "\u{00A0}")
        return joined
    }
}

/// The whole sheet in one stable view: the step body swaps inside a fixed frame while the
/// divider and bottom bar stay put, so a step change never rebuilds the sheet.
/// Only Welcome is taller than the other steps; `SetupSheet` sequences that one resize.
struct SetupLayout: View {
    let step: SetupShownStep
    let importedCount: Int
    let deviceName: String?
    let code: String
    let checkShown: Bool
    let actions: SetupActions
    var pairingURL: URL? = nil

    static let width: CGFloat = 496
    private static let padding: CGFloat = 24
    private static let rowHeight: CGFloat = 216
    private static let stepBodyHeight = rowHeight + 2 * padding
    private static let welcomeBodyHeight: CGFloat = 384
    private static let welcomeTextWidth: CGFloat = 330
    private static let barHeight: CGFloat = 64
    private static let stepTotalHeight = stepBodyHeight + 1 + barHeight

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var bodyHeight: CGFloat {
        switch step {
        case .welcome: Self.welcomeBodyHeight
        case .done: Self.stepTotalHeight
        case .importFiles, .pair, .code: Self.stepBodyHeight
        }
    }

    static func totalHeight(of step: SetupShownStep) -> CGFloat {
        switch step {
        case .welcome: welcomeBodyHeight + 1 + barHeight
        case .done, .importFiles, .pair, .code: stepTotalHeight
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case .welcome:
                    welcomeContent.transition(.opacity)
                case .done:
                    doneContent.transition(.opacity)
                case .importFiles, .pair, .code:
                    stepRow.transition(.opacity)
                }
            }
            .frame(height: bodyHeight)
            .clipped()

            if step != .done {
                Divider()
                bottomBar
                    .padding(.horizontal, Self.padding)
                    .frame(height: Self.barHeight)
            }
        }
        .frame(width: Self.width)
    }

    // MARK: Step row

    private var stepRow: some View {
        HStack(spacing: Self.padding) {
            panel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
            textColumn
                .frame(width: 176)
        }
        .frame(height: Self.rowHeight)
        .padding(Self.padding)
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .lineSpacing(4)
                .tracking(-0.2)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
            switch step {
            case .pair, .code:
                numberedSteps.padding(.top, 16)
            case .welcome, .importFiles, .done:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var title: String {
        switch step {
        case .welcome: "Welcome to Bounce"
        case .importFiles: "Import your first bounce"
        case .pair, .code: "Pair your iPhone"
        case .done: "You\u{2019}re all set"
        }
    }

    private var subtitle: String {
        switch step {
        case .welcome: "A music library for tracks you\u{2019}re still working on."
        case .importFiles: "A single mix, a few files or a whole folder."
        case .pair: "Take your mixes with you."
        case .code: "Check that \(deviceName ?? "your iPhone") shows the same code."
        case .done: "Opening your library\u{2026}"
        }
    }

    private var numberedSteps: some View {
        let lines = ["Scan the code", "Open Bounce on iPhone", "Check the code"]
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, text in
                HStack(spacing: 9) {
                    Text("\(index + 1)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.10)))
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        }
    }

    @ViewBuilder
    private var panel: some View {
        switch step {
        case .importFiles:
            DropPanel(importedCount: importedCount)
        case .pair:
            DownloadPanel(pairingURL: pairingURL)
        case .code:
            CodePanel(deviceName: deviceName ?? "Your iPhone", code: code)
        case .welcome, .done:
            EmptyView()
        }
    }

    // MARK: Welcome

    private static let welcomeRows: [(symbol: String, title: String, text: String)] = [
        ("square.stack.3d.up", "Keep every version",
         "Organize your demos, compare different mixes, and revisit earlier versions."),
        ("text.bubble", "Notes as you listen",
         "Leave text or voice notes on your mixes, so you remember what needs work."),
        ("arrow.triangle.2.circlepath", "Always in sync",
         "Keep your entire library synced between Mac and iPhone. No more AirDrop."),
    ]

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Welcome to Bounce")
                .font(.system(size: 24, weight: .bold))
                .tracking(-0.2)
            Text("A music library for tracks you\u{2019}re still working on.".withoutOrphan)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 24) {
                ForEach(Self.welcomeRows, id: \.title) { row in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: row.symbol)
                            .font(.system(size: 24))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 32, height: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(row.text.withoutOrphan)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                                .frame(maxWidth: Self.welcomeTextWidth, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(EdgeInsets(top: 44, leading: 40, bottom: 32, trailing: 40))
    }

    private var doneContent: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, setupGreen)
                .font(.system(size: 56))
                .symbolEffect(.bounce, value: checkShown)
                .scaleEffect(checkShown || reduceMotion ? 1 : 0.4)
                .opacity(checkShown || reduceMotion ? 1 : 0)
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.2)
                .padding(.top, 16)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            switch step {
            case .welcome:
                Spacer(minLength: 0)
                Button("Get Started", action: actions.getStarted)
                    .setupButton(prominent: true)
            case .importFiles:
                Button("Later", action: actions.skipImport)
                    .setupButton(prominent: false)
                Spacer(minLength: 0)
                Button("Continue", action: actions.continueFromImport)
                    .setupButton(prominent: true)
                    .disabled(importedCount == 0)
            case .pair:
                Button("Back", action: actions.backToImport)
                    .setupButton(prominent: false)
                Spacer(minLength: 0)
                Button("Later", action: actions.finish)
                    .setupButton(prominent: false)
            case .code:
                Button("Don\u{2019}t Pair", action: actions.denyPair)
                    .setupButton(prominent: false)
                Spacer(minLength: 0)
                Button("Pair", action: actions.approvePair)
                    .setupButton(prominent: true)
            case .done:
                EmptyView()
            }
        }
    }
}

private extension View {
    /// Capsule Liquid Glass button (deployment target is macOS 26).
    @ViewBuilder
    func setupButton(prominent: Bool) -> some View {
        if prominent {
            self.buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        } else {
            self.buttonStyle(.glass)
                .controlSize(.large)
        }
    }
}

// MARK: - Panels

private struct DropPanel: View {
    let importedCount: Int
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: importedCount > 0 ? "checkmark.circle.fill" : "tray.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(importedCount > 0 ? setupGreen : Color.accentColor)
            Text(importedCount > 0 ? "Imported \(importedCount) \(importedCount == 1 ? "file" : "files")" : "Drop files or a folder here")
                .font(.system(size: 13))
            Button(importedCount > 0 ? "Import More\u{2026}" : "Choose\u{2026}") { ImportHandoff.send(.picker) }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.primary.opacity(0.16),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
        )
        .externalFileDrop(isTargeted: $isTargeted) { urls in
            ImportHandoff.send(.drop(urls))
        }
    }
}

private struct DownloadPanel: View {
    let pairingURL: URL?

    var body: some View {
        VStack(spacing: 10) {
            Text("Scan to pair")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let qr = QRCodeImage.make(pairingURL?.absoluteString ?? BounceConstants.iPhoneAppURL) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .padding(5)
                    .frame(width: 80, height: 80)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("QR code to pair the Bounce iPhone app with this Mac")
            }
            Text("iPhone beta on TestFlight")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Mac and iPhone need to be on the same Wi-Fi.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Looking for iPhones")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CodePanel: View {
    let deviceName: String
    let code: String

    var body: some View {
        VStack(spacing: 8) {
            Text("\(deviceName) wants to pair")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(code)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .tracking(4.8)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
