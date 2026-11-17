import Foundation
import SwiftData
import SwiftUI
import UIKit
import BounceKit

/// DEBUG-only screenshot hook: `-onboardingShot <step>` opens the app directly in a
/// state with stub data (fake Mac, fixed pairing code, stub library). Inert in Release.
/// Steps: welcome, pairSheet, code, paired,
/// playlistSheet, player, libraryEmpty, settings, sync.
enum OnboardingShot {
    enum Step: String {
        case welcome, pairSheet, code, paired
        case playlistSheet, player, libraryEmpty, settings, sync
    }

    #if DEBUG
    static let step: Step? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-onboardingShot"), i + 1 < args.count else { return nil }
        return Step(rawValue: args[i + 1])
    }()
    static let fakePeer = DiscoveredPeer(id: UUID(uuidString: "00000000-0000-0000-0000-00000000B0CE")!, name: "Alex's MacBook Pro")
    /// Same shape as a real code (`PairRequest.verificationCode`: XXX-XXX, consonants only).
    static let fakeCode: String? = "KBT-RXN"
    #else
    static let step: Step? = nil
    static let fakePeer = DiscoveredPeer(id: UUID(), name: "")
    static let fakeCode: String? = nil
    #endif

    static var opensPairSheet: Bool { step == .pairSheet || step == .code || step == .paired }
    static var forcesOnboarding: Bool {
        guard let step else { return false }
        return ![.playlistSheet, .player, .libraryEmpty, .settings, .sync].contains(step)
    }
    static var opensPlaylistSheet: Bool { step == .playlistSheet }
    static var opensPlayer: Bool { step == .player }
    static var opensSettings: Bool { step == .settings }
    static var opensSync: Bool { step == .sync }

    #if DEBUG
    private static let trackID = UUID(uuidString: "00000000-0000-0000-0000-0000000057AC")!

    /// Inserts the stub library once (deterministic ids, so relaunches don't duplicate).
    @MainActor static func seedLibrary(_ context: ModelContext, audioPlayer: AudioPlayer) {
        if step == .libraryEmpty {
            // Simulator containers keep data from earlier seeded shots; start from an empty library.
            for t in (try? context.fetch(FetchDescriptor<Track>())) ?? [] { context.delete(t) }
            for p in (try? context.fetch(FetchDescriptor<Playlist>())) ?? [] { context.delete(p) }
            try? context.save()
            return
        }
        guard opensPlaylistSheet || opensPlayer else { return }
        let tid = trackID
        let existing = (try? context.fetch(FetchDescriptor<Track>(predicate: #Predicate { $0.id == tid }))) ?? []
        let track: Track
        if let t = existing.first {
            track = t
        } else {
            track = Track(id: tid, name: "slow down v5", artist: "Alex",
                          artwork: cover(.systemIndigo, .systemPink), workingTitle: "slow down v5")
            context.insert(track)
            let version = Version(trackID: tid, label: "Mix 1.01", filePath: "/nonexistent/stub.wav",
                                  fileSize: 1, fileFormat: "wav", originalFilename: "slow down v5.wav", duration: 214)
            context.insert(version)
            track.versions.append(version)
            let specs: [(String, UIColor, UIColor, Bool)] = [
                ("Late Night Drive", .systemTeal, .systemBlue, true),
                ("Club Edits", .systemOrange, .systemRed, false),
                ("Demos 2026", .systemGreen, .systemMint, true),
                ("Sunday Slow", .systemPurple, .systemIndigo, false),
            ]
            for (i, s) in specs.enumerated() {
                let pl = Playlist(name: s.0, sortIndex: i, coverImageData: cover(s.1, s.2),
                                  updatedAt: Date(timeIntervalSinceNow: -Double(i) * 60))
                context.insert(pl)
                var pos = 0
                for _ in 0..<(i + 2) {
                    let other = Track(name: "stub \(i)-\(pos)")
                    context.insert(other)
                    let e = PlaylistEntry(playlistID: pl.id, trackID: other.id, position: pos)
                    context.insert(e)
                    pl.entries.append(e)
                    pos += 1
                }
                if s.3 {
                    let e = PlaylistEntry(playlistID: pl.id, trackID: tid, position: pos)
                    context.insert(e)
                    pl.entries.append(e)
                }
            }
            try? context.save()
        }
        if opensPlayer {
            audioPlayer.currentTrack = track
            audioPlayer.currentVersion = track.versions.first
        }
    }

    private static func cover(_ a: UIColor, _ b: UIColor) -> Data? {
        let size = CGSize(width: 400, height: 400)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        return img.jpegData(compressionQuality: 0.8)
    }
    #else
    @MainActor static func seedLibrary(_ context: ModelContext, audioPlayer: AudioPlayer) {}
    #endif
}
