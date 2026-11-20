import SwiftUI
import BounceKit

/// Leaf that alone observes `transportState.currentTime` for the elapsed / remaining labels.
private struct TransportTimeLabel: View {
    enum Kind {
        case elapsed
        case remaining
    }

    let transportState: TransportState
    let hasVersion: Bool
    let kind: Kind

    /// Sub-hour stays compact so the scrubber keeps width; sets open up for `H:MM:SS`.
    private var labelWidth: CGFloat {
        transportState.duration >= 3600 ? 56 : 42
    }

    var body: some View {
        let currentTime = transportState.currentTime
        let duration = transportState.duration
        Text(labelText(currentTime: currentTime, duration: duration))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(hasVersion ? .primary : .quaternary)
            .frame(width: labelWidth, alignment: kind == .elapsed ? .trailing : .leading)
    }

    private func labelText(currentTime: TimeInterval, duration: TimeInterval) -> String {
        switch kind {
        case .elapsed:
            return formatClock(max(0, currentTime))
        case .remaining:
            return "-\(formatClock(max(0, duration - currentTime)))"
        }
    }

    private func formatClock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// Leaf that alone observes `transportState.currentTime` so the surrounding pill chrome
/// is not invalidated 5×/s. Feeds the current time to the scrubber as its playhead and
/// seeks the loaded audio (never the inspected mix). A tooltip carries the compact
/// track identity so the single-row pill needs no dedicated identity block.
private struct TransportWaveform: View {
    let transportState: TransportState
    let hasVersion: Bool

    var body: some View {
        WaveformScrubber(
            samples: transportState.waveformSamples,
            duration: transportState.duration,
            noteTimestamps: transportState.noteTimestamps,
            onSeek: { transportState.onSeek?($0) },
            playheadTime: transportState.currentTime
        )
        .frame(height: BounceConstants.miniWaveformHeight)
        .opacity(hasVersion ? 1 : 0.3)
        .help(identityHelp)
    }

    private var identityHelp: String {
        let title = transportState.loadedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let mix = transportState.loadedMixLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "No mix loaded" }
        return mix.isEmpty ? title : "\(title) — \(mix)"
    }
}

/// Fixed-height transport footer. Reads playback state from the shared `TransportState`
/// that `TrackDetailContentView` writes into. When no version is loaded the controls
/// are shown but disabled.
///
/// One sizing contract governs the whole footer: the inner pill is pinned to
/// `BounceConstants.transportBarHeight` and the outer padding (top 4 / bottom 8 /
/// horizontal 12) yields a fixed intrinsic height. `MainLibraryLayout` reserves that
/// intrinsic height rather than guessing one, so the pill never clips at the window edge.
struct TransportBar: View {
    let transportState: TransportState

    @State private var isQueuePopoverShown = false
    @State private var isVolumeSliderShown = false
    @State private var volumeDismissTask: Task<Void, Never>?

    /// The transport keeps the primary controls reachable on narrow windows and
    /// moves the secondary controls into More before the waveform is squeezed
    /// out of existence.
    private static let compactWidth: CGFloat = 580

    var body: some View {
        let hasVersion = transportState.onTogglePlayback != nil || transportState.duration > 0

        GeometryReader { geometry in
            let isCompact = geometry.size.width < Self.compactWidth

            GlassEffectContainer {
                HStack(spacing: 10) {
                    GlassEffectContainer {
                        HStack(spacing: 2) {
                            if !isCompact {
                                playbackModeButton(
                                    icon: "shuffle",
                                    help: "Shuffle",
                                    isActive: transportState.shuffleEnabled
                                ) {
                                    transportState.onToggleShuffle?()
                                }
                                .disabled(transportState.onToggleShuffle == nil)
                            }

                            transportButton(icon: "backward.end.fill", help: "Previous track") {
                                transportState.onSkipBackward?()
                            }

                            Button {
                                if hasVersion {
                                    transportState.onTogglePlayback?()
                                }
                            } label: {
                                Image(systemName: transportState.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .frame(width: 36, height: 36)
                                    .foregroundStyle(hasVersion ? .primary : .quaternary)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Circle())
                            .glassEffect(.regular.interactive(hasVersion), in: Circle())
                            .disabled(!hasVersion)
                            .help(transportState.isPlaying ? "Pause" : "Play")

                            transportButton(icon: "forward.end.fill", help: "Next track") {
                                transportState.onSkipForward?()
                            }

                            if !isCompact {
                                playbackModeButton(
                                    icon: repeatIcon(for: transportState.repeatMode),
                                    help: "Repeat",
                                    isActive: transportState.repeatMode != .off
                                ) {
                                    transportState.onCycleRepeatMode?()
                                }
                                .disabled(transportState.onCycleRepeatMode == nil)
                            }
                        }
                    }

                    TransportTimeLabel(
                        transportState: transportState,
                        hasVersion: hasVersion,
                        kind: .elapsed
                    )

                    TransportWaveform(transportState: transportState, hasVersion: hasVersion)

                    TransportTimeLabel(
                        transportState: transportState,
                        hasVersion: hasVersion,
                        kind: .remaining
                    )

                    GlassEffectContainer {
                        HStack(spacing: 2) {
                            if isVolumeSliderShown {
                                transportButton(icon: volumeIcon, help: "Volume") {
                                    dismissVolumeSlider()
                                }

                                Slider(
                                    value: Binding(
                                        get: { Double(transportState.volume) },
                                        set: { newValue in
                                            transportState.onSetVolume?(Float(newValue))
                                            scheduleVolumeDismiss()
                                        }
                                    ),
                                    in: 0...1
                                )
                                .controlSize(.small)
                                .frame(width: 100)

                                transportButton(icon: "xmark", help: "Close volume") {
                                    dismissVolumeSlider()
                                }
                            } else {
                                if !isCompact {
                                    transportButton(icon: volumeIcon, help: "Volume") {
                                        toggleVolumeSlider()
                                    }
                                }

                                transportButton(icon: "list.bullet", help: "Queue") {
                                    isQueuePopoverShown.toggle()
                                }
                                .background(
                                    NativePopoverHost(isPresented: $isQueuePopoverShown) {
                                        QueuePopoverView(
                                            upNextItems: transportState.upNextQueueItems,
                                            continueItems: transportState.continueQueueItems,
                                            onSelect: { versionID in
                                                isQueuePopoverShown = false
                                                transportState.onPlayQueueItem?(versionID)
                                            },
                                            onClearUpNext: {
                                                transportState.onClearUpNextQueue?()
                                            }
                                        )
                                    }
                                )

                                if isCompact {
                                    moreOptionsMenu
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: BounceConstants.transportBarHeight)
                .glassEffect(in: RoundedRectangle(cornerRadius: 22))
                .contentShape(RoundedRectangle(cornerRadius: 22))
            }
            .onChange(of: isCompact) { _, compact in
                if compact && isVolumeSliderShown {
                    dismissVolumeSlider()
                }
            }
        }
        .frame(height: BounceConstants.transportBarHeight)
        .padding(.horizontal, 12)
        .padding(.top, BounceConstants.transportBarChromeTopPadding)
        .padding(.bottom, BounceConstants.transportBarChromeBottomPadding)
        .onChange(of: isVolumeSliderShown) { _, shown in
            if shown {
                isQueuePopoverShown = false
                scheduleVolumeDismiss()
            } else {
                volumeDismissTask?.cancel()
                volumeDismissTask = nil
            }
        }
        .onDisappear {
            volumeDismissTask?.cancel()
            volumeDismissTask = nil
        }
        .disableWindowDrag()
    }

    private var volumeIcon: String {
        if transportState.volume <= 0 {
            return "speaker.fill"
        }
        if transportState.volume < 0.5 {
            return "speaker.wave.1.fill"
        }
        return "speaker.wave.2.fill"
    }

    private func toggleVolumeSlider() {
        isVolumeSliderShown.toggle()
    }

    private func dismissVolumeSlider() {
        isVolumeSliderShown = false
    }

    private var moreOptionsMenu: some View {
        Menu {
            Button("Shuffle") {
                transportState.onToggleShuffle?()
            }
            .disabled(transportState.onToggleShuffle == nil)

            Button(repeatMenuTitle) {
                transportState.onCycleRepeatMode?()
            }
            .disabled(transportState.onCycleRepeatMode == nil)

            Divider()

            Button("Volume") {
                toggleVolumeSlider()
            }
            .disabled(transportState.onSetVolume == nil)
        } label: {
            Image(systemName: "chevron.right.2")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("More playback options")
        .accessibilityLabel("More playback options")
    }

    private var repeatMenuTitle: String {
        switch transportState.repeatMode {
        case .off: return "Repeat"
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        }
    }

    private func scheduleVolumeDismiss() {
        volumeDismissTask?.cancel()
        volumeDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            isVolumeSliderShown = false
        }
    }

    private func transportButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help)
    }

    private func playbackModeButton(
        icon: String,
        help: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 28)
                .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(help)
    }

    private func repeatIcon(for mode: TransportRepeatMode) -> String {
        switch mode {
        case .off, .all: return "repeat"
        case .one:       return "repeat.1"
        }
    }
}

// MARK: - Queue popover

private struct QueuePopoverView: View {
    let upNextItems: [TransportQueueItem]
    let continueItems: [TransportQueueItem]
    let onSelect: (UUID) -> Void
    let onClearUpNext: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !upNextItems.isEmpty {
                    HStack {
                        Text("Up Next")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        Spacer()

                        Button(action: onClearUpNext) {
                            Text("Clear")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    LazyVStack(spacing: 4) {
                        ForEach(upNextItems) { item in
                            QueueRowButton(item: item, onSelect: onSelect)
                        }
                    }
                    .padding(.horizontal, 8)

                    Divider()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }

                if !continueItems.isEmpty {
                    Text("Continue Playing")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 16)
                        .padding(.top, upNextItems.isEmpty ? 16 : 0)
                        .padding(.bottom, 12)

                    LazyVStack(spacing: 4) {
                        ForEach(continueItems) { item in
                            QueueRowButton(item: item, onSelect: onSelect)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }

                if upNextItems.isEmpty && continueItems.isEmpty {
                    Text("No tracks in queue")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 32)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.never)
        .frame(width: 320)
        .frame(maxHeight: 540)
    }
}

private struct QueueRowButton: View {
    let item: TransportQueueItem
    let onSelect: (UUID) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            onSelect(item.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.isCurrent ? "speaker.wave.2.fill" : "music.note")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(item.isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: item.isCurrent ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var rowBackground: some ShapeStyle {
        if isHovered {
            return AnyShapeStyle(.quaternary)
        }
        if item.isCurrent {
            return AnyShapeStyle(.quinary)
        }
        return AnyShapeStyle(Color.clear)
    }
}
