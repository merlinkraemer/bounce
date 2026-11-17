import AppKit

/// DEBUG-only screenshot hook for the Mac onboarding steps. Inert in Release.
///
///   -onboardingShot sync-sheet   opens the Sync sheet in its unpaired state (QR + "Waiting to pair")
///   -onboardingShot pair-alert   shows the native "Pair with <iPhone>?" alert (fixed name and code)
///   -onboardingShot setup-snapshots   renders every setup step with ImageRenderer (no windows), then quits
///   -onboardingShotOut <dir>     writes one PNG per visible window to <dir>, then quits
///
/// In this mode the app uses a throwaway library in the temp dir and never starts the sync
/// transport, so it cannot touch the real library or the network.
enum OnboardingShot {
    enum Step: String { case syncSheet = "sync-sheet", pairAlert = "pair-alert", setupSnapshots = "setup-snapshots" }

    #if DEBUG
    static let step: Step? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-onboardingShot"), i + 1 < args.count else { return nil }
        return Step(rawValue: args[i + 1])
    }()
    static let outDir: URL? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-onboardingShotOut"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }()
    static let fakeDeviceName = "Alex's iPhone"
    static let fakeCode: String? = "KBT-RXN"

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[onboardingShot] \(message)\n".utf8))
    }

    /// Real content windows (not the 22pt menu bar status item).
    private static func contentWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0.frame.width > 200 && $0.frame.height > 100 }
    }

    /// Polls once a second until the target state is on screen (main window plus the Sync sheet,
    /// or the modal alert), opening the main window if SwiftUI has not, then writes one PNG per
    /// content window and quits. Gives up after 40 s and captures whatever is there.
    static func captureWindows() {
        guard let outDir, let step else { return }
        NSApp.setActivationPolicy(.regular)
        var ticks = 0
        // `.modalPanel` is included so this also keeps firing while the NSAlert runs modally.
        let timer = Timer(timeInterval: 1, repeats: true) { timer in
            ticks += 1
            let windows = contentWindows()
            let hasMain = windows.contains { !$0.isSheet && !($0 is NSPanel) }
            if !hasMain && NSApp.modalWindow == nil && (ticks == 3 || ticks == 8) {
                log("no main window yet; asking for a new one")
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
            }
            let ready: Bool
            switch step {
            case .syncSheet: ready = windows.contains { $0.attachedSheet != nil } && ticks >= 4
            case .pairAlert: ready = NSApp.modalWindow != nil && ticks >= 4
            case .setupSnapshots: ready = false
            }
            if ticks % 5 == 0 {
                log("tick \(ticks) windows=\(NSApp.windows.map { "\($0.title)|\($0.isVisible)|\(Int($0.frame.width))x\(Int($0.frame.height))" })")
            }
            guard ready || ticks >= 40 else { return }
            timer.invalidate()
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            var n = 0
            for window in contentWindows() {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                n += 1
                let kind = window.isSheet ? "sheet" : (window is NSPanel ? "panel" : "window")
                try? png.write(to: outDir.appendingPathComponent("\(n)-\(kind).png"))
            }
            log("wrote \(n) png(s) to \(outDir.path) (ready=\(ready))")
            exit(n > 0 ? 0 : 1)
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
    }
    #else
    static let step: Step? = nil
    static let outDir: URL? = nil
    static let fakeDeviceName = ""
    static let fakeCode: String? = nil
    static func captureWindows() {}
    static func log(_ message: String) {}
    #endif

    static var isActive: Bool { step != nil }
}
