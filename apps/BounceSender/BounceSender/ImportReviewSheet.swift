import SwiftUI
import AVFoundation
import BounceKit

struct ImportReviewSheet: View {
    @Binding var plan: ImportPlan

    let onCancel: () -> Void
    let onImport: () -> Void

    private var activeItemCount: Int { plan.allItems.filter { !$0.skip }.count }
    private var skippedCount: Int { plan.allItems.count - activeItemCount }
    private var totalFiles: Int { plan.allItems.count }
    private var totalTracks: Int { plan.groups.count }

    private var importButtonTitle: String {
        if activeItemCount == 0 { return "Skip All" }
        return activeItemCount == 1 ? "Import 1 File" : "Import \(activeItemCount) Files"
    }

    private var subtitle: String {
        let fileLabel = totalFiles == 1 ? "1 file" : "\(totalFiles) files"
        let trackLabel = totalTracks == 1 ? "1 track" : "\(totalTracks) tracks"
        return "\(fileLabel) · \(trackLabel)"
    }

    private func collidingLabels(in group: ImportPlanGroup) -> Set<String> {
        var counts: [String: Int] = [:]
        for item in group.items where !item.skip {
            let key = item.editableVersionLabel.lowercased()
            guard !key.isEmpty else { continue }
            counts[key, default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    /// Whether `item` renders the orange clash note beneath its row.
    private func hasLabelClash(_ item: ImportPlanItem, collisions: Set<String>) -> Bool {
        guard !item.skip, !item.editableVersionLabel.isEmpty else { return false }
        return collisions.contains(item.editableVersionLabel.lowercased())
    }

    private func siblingGroups(excluding excludedID: UUID) -> [SiblingGroupOption] {
        plan.groups.compactMap { group -> SiblingGroupOption? in
            guard group.id != excludedID else { return nil }
            let name: String
            switch group.target {
            case .existingTrack(let id):
                if let track = plan.availableTracks.first(where: { $0.id == id }) {
                    name = track.workingTitle?.isEmpty == false ? track.workingTitle! : track.name
                } else {
                    name = "Existing track"
                }
            case .newTrack, .unresolved:
                name = group.editableTrackName.isEmpty ? "New track" : group.editableTrackName
            }
            return SiblingGroupOption(id: group.id, name: name, fileCount: group.items.count)
        }
    }

    private var isSingleFile: Bool {
        plan.groups.count == 1 && plan.groups[0].items.count == 1
    }

    @AppStorage(BouncePreferenceKey.showSetsTab) private var recordingsEnabled = BouncePreferenceDefault.showSetsTab

    /// A not-skipped file is long enough to be a recording while Recordings is off.
    private var showsLongFileHint: Bool {
        !recordingsEnabled && plan.allItems.contains {
            !$0.skip && $0.sourceDuration >= BounceConstants.setAutoTagDurationThreshold
        }
    }

    /// With Recordings off nothing may be tagged long, including the duration suggestion.
    private func commit() {
        if !recordingsEnabled {
            for index in plan.groups.indices { plan.groups[index].markAsSet = false }
        }
        onImport()
    }

    var body: some View {
        if isSingleFile {
            SingleFileImportSheet(
                group: $plan.groups[0],
                availableTracks: plan.availableTracks,
                importDisabled: plan.hasUnresolvedSelections || activeItemCount == 0,
                recordingsEnabled: $recordingsEnabled,
                showsLongFileHint: showsLongFileHint,
                onCancel: onCancel,
                onImport: commit
            )
        } else {
            multiFileBody
        }
    }

    private var multiFileBody: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review Import")
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach($plan.groups) { $group in
                        let collisions = collidingLabels(in: group)
                        GroupCard(
                            group: $group,
                            availableTracks: plan.availableTracks,
                            siblingGroups: siblingGroups(excluding: group.id),
                            recordingsEnabled: recordingsEnabled,
                            collisions: collisions,
                            hasLabelClash: { hasLabelClash($0, collisions: collisions) },
                            onMergeIntoSibling: { targetID in
                                plan.mergeGroup(sourceID: group.id, into: targetID)
                            },
                            onSplit: { plan.splitItem(itemID: $0) },
                            onMove: { itemID, gid in plan.moveItem(itemID: itemID, toGroupID: gid) }
                        )
                    }
                }
                .padding(20)
            }

            if showsLongFileHint {
                LongFileHint(recordingsEnabled: $recordingsEnabled)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            Divider()

            HStack(spacing: 12) {
                if skippedCount > 0 {
                    Text("\(skippedCount) skipped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(importButtonTitle, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.hasUnresolvedSelections || activeItemCount == 0)
            }
            .padding(20)
        }
        .frame(minWidth: 440, idealWidth: 480, maxWidth: 520, minHeight: 360, idealHeight: 580)
    }
}

// MARK: - Shared form

/// Title / New mix of (only once the library has tracks) / Recorded / Long recording block, shared by the
/// single-file sheet and each group card of the multi-file sheet.
private struct GroupForm: View {
    @Binding var group: ImportPlanGroup
    let availableTracks: [ImportTrackOption]
    var siblingGroups: [SiblingGroupOption] = []
    var onMergeIntoSibling: (UUID) -> Void = { _ in }
    let recordingsEnabled: Bool
    var defaultsToToday = false

    private var existingTrack: ImportTrackOption? {
        guard case .existingTrack(let id) = group.target else { return nil }
        return availableTracks.first { $0.id == id }
    }

    private var longRecordingBinding: Binding<Bool> {
        Binding(
            get: { group.effectiveMarkAsSet },
            set: { group.markAsSet = $0 }
        )
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 12) {
            GridRow {
                label("Title:")
                titleField
            }
            if !availableTracks.isEmpty {
                GridRow {
                    label("New mix of:")
                    VStack(alignment: .leading, spacing: 4) {
                        TargetPopUp(
                            target: $group.target,
                            availableTracks: availableTracks,
                            siblingGroups: siblingGroups,
                            detectedHint: group.items.first?.detectedTrackName ?? "",
                            onMergeIntoSibling: onMergeIntoSibling
                        )
                        if let existingTrack {
                            Text("becomes mix \(existingTrack.versionCount + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            GridRow {
                label("Recorded:")
                RecordingDateField(
                    dateString: $group.recordingDateString,
                    isExplicit: $group.recordingDateIsExplicit,
                    defaultsToToday: defaultsToToday
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if recordingsEnabled {
                GridRow {
                    Color.clear.frame(width: 0, height: 0)
                    Toggle(RecordingsCopy.longRecording, isOn: longRecordingBinding)
                        .toggleStyle(.checkbox)
                        .disabled(!group.isNewTrack)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func label(_ text: String) -> some View { GetInfoLabel(text) }

    @ViewBuilder
    private var titleField: some View {
        if let existingTrack {
            TextField("", text: .constant(existingTrack.workingTitle?.isEmpty == false ? existingTrack.workingTitle! : existingTrack.name))
                .textFieldStyle(.roundedBorder)
                .truncationMode(.middle)
                .disabled(true)
        } else {
            TextField(group.target.isUnresolved ? "Pick a target" : "Track name", text: $group.editableTrackName)
                .textFieldStyle(.roundedBorder)
                .truncationMode(.middle)
        }
    }
}

/// Right-aligned secondary label for Get Info-style `Grid` forms (import sheet,
/// playlist sheet). Sets the grid column to trailing alignment.
struct GetInfoLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .gridColumnAlignment(.trailing)
    }
}

/// Shown under the form while Recordings is off and a long file is imported.
private struct LongFileHint: View {
    @Binding var recordingsEnabled: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(RecordingsCopy.importHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(RecordingsCopy.importHintButton) { recordingsEnabled = true }
                .controlSize(.small)
        }
    }
}

// MARK: - Group Card (multi-file)

private struct GroupCard: View {
    @Binding var group: ImportPlanGroup
    let availableTracks: [ImportTrackOption]
    let siblingGroups: [SiblingGroupOption]
    let recordingsEnabled: Bool
    let collisions: Set<String>
    let hasLabelClash: (ImportPlanItem) -> Bool
    let onMergeIntoSibling: (UUID) -> Void
    let onSplit: (UUID) -> Void
    let onMove: (UUID, UUID) -> Void

    private var allSkipped: Bool {
        let candidates = group.items.filter { !$0.isExactDuplicate }
        return !candidates.isEmpty && candidates.allSatisfy { $0.skip }
    }

    private func toggleSkipAll() {
        let target = !allSkipped
        for index in group.items.indices where !group.items[index].isExactDuplicate {
            group.items[index].skip = target
        }
    }

    private var allItemsSkipped: Bool { group.items.allSatisfy { $0.skip } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach($group.items) { $item in
                    FileRow(
                        item: $item,
                        hasLabelCollision: hasLabelClash(item),
                        siblingGroups: siblingGroups,
                        onSplit: { onSplit(item.id) },
                        onMove: { gid in onMove(item.id, gid) }
                    )
                }
            }

            GroupForm(
                group: $group,
                availableTracks: availableTracks,
                siblingGroups: siblingGroups,
                onMergeIntoSibling: onMergeIntoSibling,
                recordingsEnabled: recordingsEnabled
            )
            .opacity(allItemsSkipped ? 0.4 : 1)
            .disabled(allItemsSkipped)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: BounceConstants.panelCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: BounceConstants.panelCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .contextMenu {
            if group.items.count > 1 {
                Button(allSkipped ? "Include all" : "Skip all") { toggleSkipAll() }
            }
        }
    }
}

// MARK: - Single File Sheet

/// Finder Get Info-style sheet for the common one-file import: file header on
/// top, a compact right-aligned form below, sized to its content.
private struct SingleFileImportSheet: View {
    @Binding var group: ImportPlanGroup
    let availableTracks: [ImportTrackOption]
    let importDisabled: Bool
    @Binding var recordingsEnabled: Bool
    let showsLongFileHint: Bool
    let onCancel: () -> Void
    let onImport: () -> Void

    @State private var details: String = ""

    private var item: ImportPlanItem { group.items[0] }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

            GroupForm(
                group: $group,
                availableTracks: availableTracks,
                recordingsEnabled: recordingsEnabled,
                defaultsToToday: true
            )
            .padding(.horizontal, 20)

            if showsLongFileHint {
                LongFileHint(recordingsEnabled: $recordingsEnabled)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: onImport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(importDisabled)
            }
            .padding(20)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .task { details = await FileDetails.summary(for: item) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.sourceURL.path))
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.sourceURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if !details.isEmpty {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private enum FileDetails {
    /// "1:02:13 · 48 kHz · 612 MB" — missing parts are skipped.
    static func summary(for item: ImportPlanItem) async -> String {
        let url = item.sourceURL
        let duration = item.sourceDuration
        return await Task.detached(priority: .utility) {
            var parts: [String] = []
            if duration > 0 { parts.append(formatDuration(duration)) }
            if let file = try? AVAudioFile(forReading: url) {
                let kHz = file.fileFormat.sampleRate / 1000
                parts.append(String(format: kHz.rounded() == kHz ? "%.0f kHz" : "%.1f kHz", kHz))
            }
            if let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            }
            return parts.joined(separator: " · ")
        }.value
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Sibling Group Option

private struct SiblingGroupOption: Identifiable, Hashable {
    let id: UUID
    let name: String
    let fileCount: Int
}

// MARK: - File Row

private struct FileRow: View {
    @Binding var item: ImportPlanItem
    let hasLabelCollision: Bool
    let siblingGroups: [SiblingGroupOption]
    let onSplit: () -> Void
    let onMove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // Row-wide toggle: the button owns the filename + status tag and
                // stretches across the leftover width, but stops before the
                // trailing EditableCell so clicks on the version label can never
                // toggle inclusion — the text field keeps its own hit target.
                Button(action: toggleInclude) {
                    HStack(spacing: 8) {
                        Text(item.sourceURL.lastPathComponent)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .strikethrough(item.skip, color: .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let tag = issueTag {
                            Text(tag.0)
                                .font(.caption2)
                                .foregroundStyle(tag.1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.skip ? "Include this file" : "Skip this file")

                EditableCell(
                    text: $item.editableVersionLabel,
                    font: .subheadline,
                    alignment: .trailing,
                    monospacedDigit: true
                )
                .frame(width: 70)
                .disabled(item.skip || item.isExactDuplicate)
                .onAppear { seedVersionLabelIfNeeded() }

                Toggle(isOn: includeBinding) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(item.isExactDuplicate)
            }
            .contextMenu {
                Button("Make its own track") { onSplit() }
                if !siblingGroups.isEmpty {
                    Menu("Move to") {
                        ForEach(siblingGroups) { other in
                            Button(other.name) { onMove(other.id) }
                        }
                    }
                }
            }

            if hasLabelCollision {
                Text("Will save as \u{201C}\(item.editableVersionLabel) (2)\u{201D} to avoid clash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    private var issueTag: (String, Color)? {
        if item.isExactDuplicate { return ("(in library)", .secondary) }
        if item.isNearDuplicate { return ("(near-duplicate)", .orange) }
        if item.mixVsVersionAmbiguous { return ("(track or mix?)", .orange) }
        return nil
    }

    private var includeBinding: Binding<Bool> {
        Binding(get: { !item.skip }, set: { item.skip = !$0 })
    }

    /// Older plans (or planner paths that could not resolve a label) may leave the
    /// editable label empty. Seed it from the detected value so the field the user
    /// edits is the same value the importer writes.
    private func seedVersionLabelIfNeeded() {
        guard item.editableVersionLabel.isEmpty, item.hasDetectedVersion else { return }
        item.editableVersionLabel = item.detectedVersionLabel
    }

    private func toggleInclude() {
        guard !item.isExactDuplicate else { return }
        includeBinding.wrappedValue.toggle()
    }
}

/// Plain typed date field in the user's locale format (dd.MM.yyyy in German).
/// Invalid text shows an error state and never replaces the last valid value;
/// leaving the field restores the last valid date.
private struct RecordingDateField: View {
    @Binding var dateString: String?
    @Binding var isExplicit: Bool
    /// Single-file sheet: fall back to today when the filename had no date.
    var defaultsToToday = false

    @State private var text = ""
    @State private var isInvalid = false
    @FocusState private var focused: Bool

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.calendar = .autoupdatingCurrent
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "ddMMyyyy", options: 0, locale: .autoupdatingCurrent) ?? "dd.MM.yyyy"
        f.isLenient = false
        return f
    }()

    private func display(_ value: String?) -> String {
        RecordingDate.date(from: value).map { Self.formatter.string(from: $0) } ?? ""
    }

    private func parse(_ input: String) -> Date? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard let date = Self.formatter.date(from: trimmed) else { return nil }
        let year = Calendar.autoupdatingCurrent.component(.year, from: date)
        return (1900...2200).contains(year) ? date : nil
    }

    var body: some View {
        TextField(Self.formatter.dateFormat.lowercased(), text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 110)
            .focused($focused)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.red, lineWidth: 1.5)
                    .opacity(isInvalid ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .onAppear {
                if dateString == nil, defaultsToToday {
                    dateString = RecordingDate.string(from: .now)
                    isExplicit = true
                }
                text = display(dateString)
            }
            .onChange(of: text) { _, newValue in
                if let date = parse(newValue) {
                    isInvalid = false
                    let canonical = RecordingDate.string(from: date)
                    if canonical != dateString {
                        dateString = canonical
                        isExplicit = true
                    }
                } else {
                    isInvalid = !(newValue.isEmpty && dateString == nil)
                }
            }
            .onChange(of: focused) { _, isFocused in
                guard !isFocused else { return }
                text = display(dateString)
                isInvalid = false
            }
    }
}

// MARK: - Editable Cell

/// Chrome-free editable cell: plain text, no permanent field box or border.
/// A hover wash and an accent focus ring reveal that the value is editable,
/// matching the native grouped-form treatment without adding chrome at rest.
private struct EditableCell: View {
    @Binding var text: String
    var placeholder: String = ""
    var font: Font = .body
    var alignment: TextAlignment = .leading
    var monospacedDigit: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(monospacedDigit ? font.monospacedDigit() : font)
            .multilineTextAlignment(alignment)
            .focused($isFocused)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(fillColor)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .onHover { hovering in
                isHovered = isEnabled && hovering
            }
    }

    private var fillColor: Color {
        guard isEnabled else { return .clear }
        if isFocused { return Color(nsColor: .textBackgroundColor) }
        if isHovered { return Color.primary.opacity(0.06) }
        return .clear
    }
}

// MARK: - Target Pop-Up

/// Standard pop-up button: "None (new track)", likely tracks, "Other Track…".
/// The last item opens the searchable picker for any track in the library.
private struct TargetPopUp: View {
    @Binding var target: ImportPlanGroupTarget
    let availableTracks: [ImportTrackOption]
    let siblingGroups: [SiblingGroupOption]
    let detectedHint: String
    let onMergeIntoSibling: (UUID) -> Void

    private enum Choice: Hashable {
        case new, unresolved, track(UUID), other
    }

    @State private var pickerOpen = false

    private var selection: Binding<Choice> {
        Binding(
            get: {
                switch target {
                case .newTrack: return .new
                case .unresolved: return .unresolved
                case .existingTrack(let id): return .track(id)
                }
            },
            set: { choice in
                switch choice {
                case .new: target = .newTrack
                case .unresolved: break
                case .track(let id): target = .existingTrack(id)
                case .other: pickerOpen = true
                }
            }
        )
    }

    /// Filename matches first, then most recently updated. A track picked via
    /// "Other Track…" stays listed so the menu can show it as selected.
    private var shortlist: [ImportTrackOption] {
        var tracks = Array(TrackRanking.byHint(availableTracks, hint: detectedHint).prefix(6))
        if case .existingTrack(let id) = target, !tracks.contains(where: { $0.id == id }),
           let current = availableTracks.first(where: { $0.id == id }) {
            tracks.insert(current, at: 0)
        }
        return tracks
    }

    var body: some View {
        Picker("", selection: selection) {
            if case .unresolved = target {
                Text("Choose…").tag(Choice.unresolved)
            }
            Text("None (new track)").tag(Choice.new)
            if !shortlist.isEmpty {
                Divider()
                ForEach(shortlist) { track in
                    Text(track.workingTitle?.isEmpty == false ? track.workingTitle! : track.name)
                        .tag(Choice.track(track.id))
                }
            }
            Divider()
            Text("Other Track…").tag(Choice.other)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
            TargetPickerPopover(
                availableTracks: availableTracks,
                siblingGroups: siblingGroups,
                detectedHint: detectedHint,
                currentTarget: target,
                onPick: { newTarget in
                    target = newTarget
                    pickerOpen = false
                },
                onMergeIntoSibling: { siblingID in
                    pickerOpen = false
                    onMergeIntoSibling(siblingID)
                }
            )
        }
    }
}

// MARK: - Target Picker Popover

private struct TargetPickerPopover: View {
    let availableTracks: [ImportTrackOption]
    let siblingGroups: [SiblingGroupOption]
    let detectedHint: String
    let currentTarget: ImportPlanGroupTarget
    let onPick: (ImportPlanGroupTarget) -> Void
    let onMergeIntoSibling: (UUID) -> Void

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    private var filteredSiblings: [SiblingGroupOption] {
        guard !searchText.isEmpty else { return siblingGroups }
        let q = TrackRanking.normalize(searchText)
        return siblingGroups.filter { TrackRanking.normalize($0.name).contains(q) }
    }

    private var filteredTracks: [ImportTrackOption] {
        let ranked: [ImportTrackOption]
        if searchText.isEmpty {
            ranked = rankByHint(availableTracks, hint: detectedHint)
        } else {
            ranked = rankBySearch(availableTracks, query: searchText)
        }
        return Array(ranked.prefix(10))
    }

    private var currentIsNewTrack: Bool {
        if case .newTrack = currentTarget { return true }
        return false
    }

    private func currentExistingID() -> UUID? {
        if case .existingTrack(let id) = currentTarget { return id }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Add as mix of")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search tracks", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    PickerRow(
                        icon: "plus",
                        title: "New track",
                        trailing: nil,
                        isCurrent: currentIsNewTrack,
                        onTap: { onPick(.newTrack) }
                    )

                    if !filteredSiblings.isEmpty {
                        SectionLabel("In this batch")
                        ForEach(filteredSiblings) { sibling in
                            PickerRow(
                                icon: "square.stack.3d.up",
                                title: sibling.name,
                                trailing: sibling.fileCount == 1 ? "1 file" : "\(sibling.fileCount) files",
                                isCurrent: false,
                                onTap: { onMergeIntoSibling(sibling.id) }
                            )
                        }
                    }

                    if !filteredTracks.isEmpty {
                        SectionLabel("Library")
                        ForEach(filteredTracks) { track in
                            PickerRow(
                                icon: "music.note",
                                title: trackDisplayName(track),
                                trailing: track.versionCount == 1 ? "1 mix" : "\(track.versionCount) mixes",
                                isCurrent: currentExistingID() == track.id,
                                onTap: { onPick(.existingTrack(track.id)) }
                            )
                        }
                    } else if !availableTracks.isEmpty && !searchText.isEmpty {
                        Text("No matches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 280)
        }
        .frame(width: 300)
        .onAppear { searchFocused = true }
    }

    private func trackDisplayName(_ track: ImportTrackOption) -> String {
        track.workingTitle?.isEmpty == false ? track.workingTitle! : track.name
    }

    private func rankByHint(_ tracks: [ImportTrackOption], hint: String) -> [ImportTrackOption] {
        TrackRanking.byHint(tracks, hint: hint)
    }

    private func rankBySearch(_ tracks: [ImportTrackOption], query: String) -> [ImportTrackOption] {
        TrackRanking.bySearch(tracks, query: query)
    }
}

// MARK: - Track Ranking

private enum TrackRanking {
    static func byHint(_ tracks: [ImportTrackOption], hint: String) -> [ImportTrackOption] {
        let needle = normalize(hint)
        if needle.isEmpty {
            return tracks.sorted { $0.updatedAt > $1.updatedAt }
        }
        return tracks
            .map { track -> (Int, ImportTrackOption) in
                let candidates = [track.name, track.workingTitle ?? ""].map(normalize)
                if candidates.contains(needle) { return (0, track) }
                if candidates.contains(where: { !$0.isEmpty && ($0.hasPrefix(needle) || needle.hasPrefix($0)) }) { return (1, track) }
                if candidates.contains(where: { !$0.isEmpty && $0.contains(needle) }) { return (2, track) }
                return (3, track)
            }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                return lhs.1.updatedAt > rhs.1.updatedAt
            }
            .map(\.1)
    }

    static func bySearch(_ tracks: [ImportTrackOption], query: String) -> [ImportTrackOption] {
        let q = normalize(query)
        guard !q.isEmpty else { return tracks }
        return tracks
            .compactMap { track -> (Int, ImportTrackOption)? in
                let candidates = [track.name, track.workingTitle ?? ""].map(normalize)
                if candidates.contains(q) { return (0, track) }
                if candidates.contains(where: { !$0.isEmpty && $0.hasPrefix(q) }) { return (1, track) }
                if candidates.contains(where: { !$0.isEmpty && $0.contains(q) }) { return (2, track) }
                return nil
            }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                return lhs.1.updatedAt > rhs.1.updatedAt
            }
            .map(\.1)
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

private struct PickerRow: View {
    let icon: String
    let title: String
    let trailing: String?
    let isCurrent: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Color.accentColor.opacity(BounceConstants.panelHoverOpacity) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
