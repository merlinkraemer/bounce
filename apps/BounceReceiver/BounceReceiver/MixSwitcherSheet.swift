import SwiftUI
import BounceKit

struct MixSwitcherSheet: View {
    let track: Track
    let onSelectMix: (Version) -> Void
    @Binding var isPresented: Bool

    @Environment(AudioPlayer.self) private var audioPlayer
    let downloadManager: DownloadManager
    @State private var unavailableMix: Version?
    @State private var showUnavailableAlert = false

    private var sortedMixes: [Version] {
        track.versions.sorted { a, b in
            let aNum = leadingNumber(in: a.label)
            let bNum = leadingNumber(in: b.label)

            if aNum != nil && bNum == nil { return true }
            if aNum == nil && bNum != nil { return false }

            if let aN = aNum, let bN = bNum, aN != bN {
                return aN > bN
            }

            let strCmp = a.label.localizedStandardCompare(b.label)
            if strCmp != .orderedSame {
                return strCmp == .orderedDescending
            }

            return a.addedAt > b.addedAt
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedMixes) { mix in
                    Button {
                        if FileManager.default.fileExists(atPath: mix.filePath) {
                            onSelectMix(mix)
                        } else {
                            unavailableMix = mix
                            showUnavailableAlert = true
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mix.label)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                HStack(spacing: 8) {
                                    Text(formatDate(mix.addedAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if mix.duration > 0 {
                                        Text(formatDuration(mix.duration))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                }
                            }
                            Spacer()
                            if audioPlayer.currentVersion?.id == mix.id {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        // Spacer alone isn't hit-testable inside a .plain
                        // Button — without this the empty middle of the row
                        // swallows taps, so the mix never switches.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("Mixes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .alert("Mix is not downloaded", isPresented: $showUnavailableAlert) {
            Button("Download") {
                if let unavailableMix {
                    downloadManager.requestDownload(for: unavailableMix)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Connect to the paired Mac to download this mix for offline playback.")
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func leadingNumber(in string: String) -> Double? {
        var idx = string.startIndex
        while idx < string.endIndex, string[idx].isNumber || string[idx] == "." {
            string.formIndex(after: &idx)
        }
        let prefix = string[string.startIndex..<idx]
        guard !prefix.isEmpty else { return nil }
        return Double(prefix)
    }
}
