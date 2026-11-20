import SwiftUI
import SwiftData
import UIKit
import BounceKit

// MARK: - SwiftUI Interface

struct PlayerSheet: UIViewControllerRepresentable {
    let isPresented: Bool
    /// Increments on every open request so expand still runs when the bool
    /// was already true (mid-collapse reopen / stuck presentation).
    let openToken: Int
    let onDismiss: () -> Void
    let audioPlayer: AudioPlayer
    let modelContext: ModelContext
    let downloadManager: DownloadManager
    let uploadQueue: UploadQueue

    func makeCoordinator() -> SheetCoordinator {
        SheetCoordinator()
    }

    func makeUIViewController(context: Context) -> PlayerSheetVC {
        let vc = PlayerSheetVC(
            audioPlayer: audioPlayer,
            modelContext: modelContext,
            downloadManager: downloadManager,
            uploadQueue: uploadQueue
        )
        vc.onDismiss = onDismiss
        context.coordinator.vc = vc
        return vc
    }

    func updateUIViewController(_ vc: PlayerSheetVC, context: Context) {
        vc.onDismiss = onDismiss
        vc.audioPlayer = audioPlayer

        // Pre-build the SwiftUI player tree as soon as a track exists, even
        // while the sheet is still collapsed — first expand then only animates.
        if audioPlayer.currentTrack != nil {
            vc.prewarmIfNeeded()
        }

        let presentedChanged = isPresented != context.coordinator.wasPresented
        let openRequested = openToken != context.coordinator.lastOpenToken
        if openRequested {
            context.coordinator.lastOpenToken = openToken
        }
        if presentedChanged {
            context.coordinator.wasPresented = isPresented
        }

        if isPresented {
            // Expand on false→true, and on every openToken bump while already
            // presented (reopen during collapse animation, stuck flag).
            if presentedChanged || openRequested {
                vc.expand()
            }
        } else if presentedChanged {
            vc.collapse()
        }
    }

    class SheetCoordinator {
        weak var vc: PlayerSheetVC?
        var wasPresented: Bool = false
        var lastOpenToken: Int = 0
    }
}

// MARK: - Sheet View Controller

final class PlayerSheetVC: UIViewController, UIGestureRecognizerDelegate {

    var onDismiss: (() -> Void)?
    var audioPlayer: AudioPlayer
    let modelContext: ModelContext
    let downloadManager: DownloadManager
    let uploadQueue: UploadQueue
    let draftController = PlayerDraftController()
    let voiceNoteController = VoiceNoteInteractionController()

    // MARK: - Views

    private let dimmingView = UIView()
    private let sheetView = UIView()
    private let dragHandle = UIView()
    private var hostingController: UIHostingController<PlayerSheetContent>?
    private let notesScrollState = NotesScrollState()

    /// Single top constraint — animated constant controls sheet position.
    /// 0 = visible, view.bounds.height = fully off-screen.
    private var sheetTop: NSLayoutConstraint!

    // MARK: - State

    private enum SheetState { case collapsed, expanded, dragging }
    private var sheetState: SheetState = .collapsed
    private var dismissCallbackFired = false

    private var panGesture: UIPanGestureRecognizer!
    private var dragStart: CGFloat = 0
    private var dragStartConstant: CGFloat = 0
    private var keyboardOffset: CGFloat = 0
    private var lastKeyboardHeight: CGFloat = 0
    /// Captured at pan-begin. The keyboard's `.onDrag` dismiss races our pan
    /// gesture; latching the keyboard state at start ensures a downward drag
    /// dismisses *only* the keyboard, not the sheet.
    private var keyboardActiveAtPanStart = false
    /// Once the keyboard is dismissed mid-gesture, the sheet must NOT start
    /// dragging on the same gesture — the user's intent was keyboard-only.
    private var keyboardDismissedThisGesture = false

    private enum DragDirection { case none, vertical, horizontal }
    private var dragDirection: DragDirection = .none

    /// Set to true once content is built. Never rebuilt — avoids audio disruption.
    private var contentBuilt = false

    /// `safeAreaInsets.bottom` baked into the current `PlayerSheetContent`
    /// at install time. The hosting controller captures the value as a `let`,
    /// so if it was 0 when we installed (first-layout race), the SwiftUI
    /// `bottomGap` is permanently off by the home-indicator height. We
    /// re-install once the real inset arrives. Sentinel -1 = never installed.
    private var lastInstalledSafeBottom: CGFloat = -1

    /// Same first-layout race as `lastInstalledSafeBottom`, but for the top
    /// inset. We disable the hosting controller's automatic safe area and bake
    /// the top inset into `PlayerSheetContent` ourselves, so a stale 0 here
    /// would leave the player jammed under the notch. Sentinel -1 = never set.
    private var lastInstalledSafeTop: CGFloat = -1

    /// Viewport height baked into `PlayerSheetContent`. Re-sync when the sheet
    /// bounds change so player/notes layout stays correct after first layout.
    private var lastInstalledViewportHeight: CGFloat = -1

    /// True while a deferred hosting-root re-bake is queued (see
    /// `syncHostingRootIfNeeded`) so rapid layout passes coalesce into one
    /// rootView assignment outside the layout pass.
    private var reBakeScheduled = false

    /// First-launch race: when PlayerSheet enters the view tree at the same
    /// instant the user plays a track, updateUIViewController fires expand()
    /// before viewDidLayoutSubviews has run — view bounds are zero, the
    /// animation has nothing to animate to, and the hosting controller hasn't
    /// been installed yet. Latch the request and retry it once layout lands.
    private var pendingExpand = false

    /// Display link that forces the SwiftUI hosting controller to re-render
    /// during UIScrollView tracking. SwiftUI's own render pipeline may not
    /// process @Observable changes while the run loop is in tracking mode,
    /// so we manually request layout each frame.
    private var renderLink: CADisplayLink?

    // MARK: - Init

    init(
        audioPlayer: AudioPlayer,
        modelContext: ModelContext,
        downloadManager: DownloadManager,
        uploadQueue: UploadQueue
    ) {
        self.audioPlayer = audioPlayer
        self.modelContext = modelContext
        self.downloadManager = downloadManager
        self.uploadQueue = uploadQueue
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false

        setupDimming()
        setupSheetView()
        setupDragHandle()
        setupPanGesture()
        setupKeyboardObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let wasFirstLayout = !contentBuilt
        if !contentBuilt {
            buildContent()
        }
        if wasFirstLayout && pendingExpand {
            pendingExpand = false
            expand()
        }
        // First-layout race: the safe-area inset can be 0 when buildContent /
        // expand fire, so `PlayerSheetContent` captures `safeAreaBottom = 0`
        // as a `let`. Once the real inset arrives, rebake the hosting root
        // so `bottomGap` and `playerH` use the correct home-indicator height.
        if contentBuilt {
            syncHostingRootIfNeeded()
        }
    }

    // MARK: - Setup

    private func setupDimming() {
        dimmingView.backgroundColor = .black
        dimmingView.alpha = 0
        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dimmingView)
        NSLayoutConstraint.activate([
            dimmingView.topAnchor.constraint(equalTo: view.topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        dimmingView.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(tapDismiss))
        )
    }

    private func setupSheetView() {
        sheetView.translatesAutoresizingMaskIntoConstraints = false
        sheetView.backgroundColor = .black
        sheetView.clipsToBounds = true
        sheetView.layer.cornerRadius = 20
        sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheetView.layer.cornerCurve = .continuous

        view.addSubview(sheetView)

        // Single top constraint controls Y position.
        // Height is explicit — no bottom anchor needed.
        sheetTop = sheetView.topAnchor.constraint(equalTo: view.topAnchor, constant: UIScreen.main.bounds.height)
        NSLayoutConstraint.activate([
            sheetTop,
            sheetView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sheetView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheetView.heightAnchor.constraint(equalTo: view.heightAnchor),
        ])
    }

    private func setupDragHandle() {
        dragHandle.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        dragHandle.layer.cornerRadius = 2.5
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(dragHandle)

        NSLayoutConstraint.activate([
            dragHandle.widthAnchor.constraint(equalToConstant: 36),
            dragHandle.heightAnchor.constraint(equalToConstant: 5),
            dragHandle.centerXAnchor.constraint(equalTo: sheetView.centerXAnchor),
            // Anchor below the notch/Dynamic Island, not the physical top edge,
            // so the grabber is actually visible.
            dragHandle.topAnchor.constraint(equalTo: sheetView.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])
    }

    private func setupKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let info = notification.userInfo,
              let endFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              sheetState == .expanded
        else { return }

        let kbFrameInView = view.convert(endFrame, from: nil)
        let intersection = view.bounds.intersection(kbFrameInView)
        lastKeyboardHeight = intersection.isNull ? 0 : intersection.height

        animateKeyboardOffset(to: computeKeyboardOffset(), with: info)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        lastKeyboardHeight = 0
        guard let info = notification.userInfo, sheetState == .expanded else {
            keyboardOffset = 0
            return
        }
        animateKeyboardOffset(to: 0, with: info)
    }

    /// Composer is part of the scrolling content, but at scroll=0 sits a fixed
    /// distance above the sheet's safe-area bottom. When the sheet shifts up by
    /// `keyboardOffset`, the composer rides with it. Lift just far enough that
    /// the composer ends up above the keyboard.
    private func computeKeyboardOffset() -> CGFloat {
        guard lastKeyboardHeight > 0 else { return 0 }
        return max(0, lastKeyboardHeight - view.safeAreaInsets.bottom)
    }

    private func animateKeyboardOffset(to offset: CGFloat, with info: [AnyHashable: Any]) {
        keyboardOffset = offset
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 0
        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)

        UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState]) {
            self.sheetTop.constant = -offset
            self.view.layoutIfNeeded()
        }
    }

    private func setupPanGesture() {
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        panGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(panGesture)
    }

    // MARK: - Content

    private func buildContent() {
        contentBuilt = true
        installHostingController()
    }

    private func makeSheetContent(
        safeTop: CGFloat,
        safeBottom: CGFloat,
        viewportHeight: CGFloat
    ) -> PlayerSheetContent {
        PlayerSheetContent(
            draftController: draftController,
            audioPlayer: audioPlayer,
            voiceNoteController: voiceNoteController,
            modelContext: modelContext,
            downloadManager: downloadManager,
            uploadQueue: uploadQueue,
            notesScrollState: notesScrollState,
            onDismiss: { [weak self] in self?.triggerDismiss() },
            viewportHeight: viewportHeight,
            safeAreaTop: safeTop,
            safeAreaBottom: safeBottom
        )
    }

    /// Updates baked layout metrics without tearing down the hosting tree when
    /// a controller already exists (safe-area / bounds races after first install).
    private func syncHostingRootIfNeeded() {
        let safeBottom = view.safeAreaInsets.bottom
        let safeTop = view.safeAreaInsets.top
        let viewportHeight = sheetView.bounds.height
        guard viewportHeight > 0 else { return }

        let metricsChanged = abs(safeBottom - lastInstalledSafeBottom) > 0.5
            || abs(safeTop - lastInstalledSafeTop) > 0.5
            || abs(viewportHeight - lastInstalledViewportHeight) > 0.5
        guard metricsChanged else { return }

        if hostingController == nil {
            installHostingController()
            return
        }

        // Defer out of the layout pass and coalesce: assigning rootView
        // invalidates the hosting view synchronously — doing that inside
        // viewDidLayoutSubviews re-enters layout and can latch into a
        // nav-bar-driven layout loop during push/pop transitions.
        guard !reBakeScheduled else { return }
        reBakeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reBakeScheduled = false
            // Re-read at apply time so coalesced passes bake the latest metrics.
            let safeBottom = self.view.safeAreaInsets.bottom
            let safeTop = self.view.safeAreaInsets.top
            let viewportHeight = self.sheetView.bounds.height
            guard viewportHeight > 0 else { return }
            self.lastInstalledSafeBottom = safeBottom
            self.lastInstalledSafeTop = safeTop
            self.lastInstalledViewportHeight = viewportHeight
            self.hostingController?.rootView = self.makeSheetContent(
                safeTop: safeTop,
                safeBottom: safeBottom,
                viewportHeight: viewportHeight
            )
        }
    }

    /// Tears down and recreates the hosting controller so the SwiftUI initial
    /// render picks up the current audioPlayer state synchronously — before the
    /// expand animation makes the sheet visible.
    private func installHostingController() {
        let safeBottom = view.safeAreaInsets.bottom
        let safeTop = view.safeAreaInsets.top
        let viewportHeight = max(sheetView.bounds.height, view.bounds.height)
        lastInstalledSafeBottom = safeBottom
        lastInstalledSafeTop = safeTop
        lastInstalledViewportHeight = viewportHeight
        if let old = hostingController {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }

        let content = makeSheetContent(
            safeTop: safeTop,
            safeBottom: safeBottom,
            viewportHeight: viewportHeight
        )
        let host = UIHostingController(rootView: content)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        host.overrideUserInterfaceStyle = .dark
        host.sizingOptions = []
        // The sheet is full-screen; we bake the top/bottom insets into the
        // SwiftUI layout ourselves. Without this, the hosting controller adds
        // its own top safe-area inset on top of our drag-handle zone, pushing
        // the whole player ~59pt too low.
        host.safeAreaRegions = []

        addChild(host)
        sheetView.addSubview(host.view)
        host.didMove(toParent: self)
        hostingController = host

        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: sheetView.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: sheetView.bottomAnchor),
        ])
    }

    // MARK: - Expand / Collapse

    func expand() {
        // Force viewDidLoad so sheetTop / sheetView exist before we touch them.
        _ = view
        // Defer if the view isn't laid out yet — animating against zero bounds
        // produces an invisible sheet AND flips sheetState to .expanded, which
        // permanently blocks future expand() calls.
        guard view.bounds.height > 0 else {
            pendingExpand = true
            return
        }

        // Already fully on-screen — just ensure interaction is on.
        if sheetState == .expanded && sheetTop.constant <= 0.5 {
            view.isUserInteractionEnabled = true
            return
        }

        notesScrollState.scrollView?.setContentOffset(.zero, animated: false)
        sheetState = .expanded
        dismissCallbackFired = false
        pendingExpand = false
        dragDirection = .none
        view.isUserInteractionEnabled = true

        // Build hosting controller if not yet created (first expand).
        // Do NOT rebuild on subsequent expands — tearing down SwiftUI
        // during playback stops audio.
        if !contentBuilt {
            buildContent()
        } else {
            syncHostingRootIfNeeded()
        }

        // Start render link to keep SwiftUI views alive during scroll tracking.
        startRenderLink()

        // Animate from the current position (covers mid-collapse reopen).
        UIView.animate(
            withDuration: 0.4,
            delay: 0,
            usingSpringWithDamping: 0.88,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState]
        ) {
            self.dimmingView.alpha = 0.5
            self.sheetTop.constant = 0
            self.view.layoutIfNeeded()
        }
    }

    func collapse() {
        // Drop any deferred expand so a dismiss issued before the first
        // layout doesn't get overruled when layout finally arrives.
        pendingExpand = false

        // Clear SwiftUI presentation immediately so the representable stops
        // eating hits over the miniplayer / track list during the animation.
        // Completion used to be the only clear path — that left a ~350ms
        // (or permanent, if stuck) invisible hit-test overlay.
        if !dismissCallbackFired {
            dismissCallbackFired = true
            onDismiss?()
        }

        guard sheetState != .collapsed else {
            view.isUserInteractionEnabled = false
            return
        }
        sheetState = .collapsed

        // Stop render link — no need to force updates while collapsed.
        stopRenderLink()

        let hideConstant = view.bounds.height
        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            usingSpringWithDamping: 0.9,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState]
        ) {
            self.dimmingView.alpha = 0
            self.sheetTop.constant = hideConstant
            self.view.layoutIfNeeded()
        } completion: { _ in
            // If the sheet was re-expanded while this collapse animation was
            // running, leave interaction alone — expand already re-enabled it.
            guard self.sheetState == .collapsed else { return }
            self.view.isUserInteractionEnabled = false
        }
    }

    // MARK: - Dismiss

    @objc private func tapDismiss() {
        if draftController.hasDraft {
            draftController.attempt(action: { [weak self] in self?.collapse() })
        } else {
            collapse()
        }
    }

    private func triggerDismiss() {
        view.endEditing(true)
        collapse()
    }

    // MARK: - Render Link

    /// Forces SwiftUI to re-render during UIScrollView tracking by invalidating
    /// the hosting controller's view layout each frame. CADisplayLink in
    /// `.common` mode fires during both default and tracking run loop modes.
    private func startRenderLink() {
        guard renderLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(renderLinkTick(_:)))
        link.add(to: .main, forMode: .common)
        renderLink = link
    }

    private func stopRenderLink() {
        renderLink?.invalidate()
        renderLink = nil
    }

    @objc private func renderLinkTick(_ link: CADisplayLink) {
        // Only force a full-tree relayout while scrubbing or the notes scroll
        // is actively tracking. Playback already drives WaveformView via its
        // own DisplayLinkUpdater — layoutIfNeeded() on the whole hosting tree
        // every frame was the main fullscreen lag source.
        let scrollTracking = notesScrollState.scrollView?.isTracking == true
            || notesScrollState.scrollView?.isDecelerating == true
        guard audioPlayer.isScrubbing || scrollTracking else { return }

        hostingController?.view.setNeedsLayout()
        hostingController?.view.layoutIfNeeded()
    }

    /// Builds the SwiftUI tree while the sheet is still off-screen so the
    /// first expand only animates instead of compiling the player + waveforms.
    func prewarmIfNeeded() {
        guard view.bounds.height > 0 else { return }
        if !contentBuilt {
            buildContent()
        }
    }

    // MARK: - Pan Gesture

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {

        case .began:
            dragStart = translation.y
            dragStartConstant = sheetTop.constant
            dragDirection = .none
            keyboardActiveAtPanStart = lastKeyboardHeight > 0
            keyboardDismissedThisGesture = false

        case .changed:
            // Lock direction on first significant movement
            if dragDirection == .none {
                let absX = abs(translation.x)
                let absY = abs(translation.y)
                if absX > 8 || absY > 8 {
                    dragDirection = absX > absY ? .horizontal : .vertical
                }
                if dragDirection == .horizontal { return }
            }
            if dragDirection == .horizontal { return }

            let notesScroll = notesScrollState.isEnabled ? notesScrollState.scrollView : nil
            let isAtTop = (notesScroll?.contentOffset.y ?? 0) <= 0.5
            let isDraggingDown = (translation.y - dragStart) > 0

            let maxY = view.bounds.height

            if sheetState == .dragging {
                let dragAmount = translation.y - dragStart
                let newY = dragStartConstant + dragAmount
                let clampedY = max(0, min(newY, maxY))

                sheetTop.constant = clampedY
                dimmingView.alpha = 0.5 * (1 - clampedY / maxY)
                view.layoutIfNeeded()
                notesScroll?.setContentOffset(.zero, animated: false)

            } else if isAtTop && isDraggingDown && keyboardActiveAtPanStart {
                // Keyboard was up at pan start: a downward drag dismisses the
                // keyboard instead of the sheet. Resign first responder and
                // latch so we don't initiate dismissal later in the same drag.
                view.endEditing(true)
                keyboardActiveAtPanStart = false
                keyboardDismissedThisGesture = true
            } else if isAtTop && isDraggingDown && !keyboardDismissedThisGesture {
                sheetState = .dragging
                dragStart = translation.y
                dragStartConstant = sheetTop.constant

                let dragAmount = translation.y - dragStart
                let clampedY = max(0, min(dragAmount, maxY))

                sheetTop.constant = clampedY
                dimmingView.alpha = 0.5 * (1 - clampedY / maxY)
                view.layoutIfNeeded()
                notesScroll?.setContentOffset(.zero, animated: false)
            }

        case .ended, .cancelled:
            guard dragDirection == .vertical || dragDirection == .none else {
                sheetState = .expanded
                return
            }
            guard sheetState == .dragging else {
                sheetState = .expanded
                return
            }

            let currentY = sheetTop.constant
            let maxY = view.bounds.height
            let shouldDismiss: Bool

            if velocity.y > 800 {
                shouldDismiss = true
            } else if velocity.y < -800 {
                shouldDismiss = false
            } else {
                shouldDismiss = currentY > maxY * 0.3
            }

            if shouldDismiss {
                if draftController.hasDraft {
                    sheetState = .expanded
                    UIView.animate(
                        withDuration: 0.3,
                        delay: 0,
                        usingSpringWithDamping: 0.85,
                        initialSpringVelocity: 0
                    ) {
                        self.dimmingView.alpha = 0.5
                        self.sheetTop.constant = 0
                        self.view.layoutIfNeeded()
                    }
                    draftController.attempt(action: { [weak self] in self?.collapse() })
                } else {
                    triggerDismiss()
                }
            } else {
                sheetState = .expanded
                UIView.animate(
                    withDuration: 0.3,
                    delay: 0,
                    usingSpringWithDamping: 0.85,
                    initialSpringVelocity: 0
                ) {
                    self.dimmingView.alpha = 0.5
                    self.sheetTop.constant = -self.keyboardOffset
                    self.view.layoutIfNeeded()
                }
            }
            dragDirection = .none

        default:
            break
        }
    }

    // MARK: - Gesture Delegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer == panGesture || otherGestureRecognizer == panGesture {
            return true
        }
        return false
    }
}

// MARK: - SwiftUI Content

struct PlayerSheetContent: View {
    let draftController: PlayerDraftController
    let audioPlayer: AudioPlayer
    @Bindable var voiceNoteController: VoiceNoteInteractionController
    let modelContext: ModelContext
    let downloadManager: DownloadManager
    let uploadQueue: UploadQueue
    let notesScrollState: NotesScrollState
    let onDismiss: () -> Void
    let viewportHeight: CGFloat
    let safeAreaTop: CGFloat
    let safeAreaBottom: CGFloat

    @State private var showShareSheet = false
    @State private var showMixSwitcher = false
    @State private var showUpNext = false
    @State private var trackToEdit: Track?
    @State private var trackToAddToPlaylist: Track?
    @State private var composerHeight: CGFloat = 60
    @State private var hasVisibleNotes = false

    /// Grabber clearance below the top safe area. The hosting controller's
    /// automatic safe area is disabled, so the real top inset is
    /// `safeAreaTop + dragHandleHeight`.
    private static let dragHandleHeight: CGFloat = 14
    private static let composerBottomPadding: CGFloat = 8
    private static let composerToNotesGap: CGFloat = 12
    private static let firstNotePeek: CGFloat = 40

    private var scrollShouldBeEnabled: Bool {
        hasVisibleNotes && !voiceNoteController.state.isRecording
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let track = audioPlayer.currentTrack {
                let notesPeekH: CGFloat = hasVisibleNotes ? Self.firstNotePeek : 0
                let notesGapH: CGFloat = hasVisibleNotes ? Self.composerToNotesGap : 0
                let bottomGap = safeAreaBottom + Self.composerBottomPadding
                // Player fills the viewport minus the top inset, the composer
                // and (when notes exist) a peek of the first note, so the whole
                // sheet — player, composer and notes — scrolls together.
                let playerH = max(0,
                    viewportHeight
                    - safeAreaTop
                    - Self.dragHandleHeight
                    - composerHeight
                    - notesGapH
                    - notesPeekH
                    - bottomGap
                )

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Top inset: safe area (notch/Dynamic Island) + grabber clearance.
                        // Baked in here because the hosting controller's automatic safe
                        // area is disabled.
                        Color.clear
                            .frame(height: safeAreaTop + Self.dragHandleHeight)

                        PlayerView(
                            voiceNoteController: voiceNoteController,
                            onDismiss: { draftController.attempt(action: handleDismiss) },
                            onShare: { showShareSheet = true },
                            onAddToPlaylist: { trackToAddToPlaylist = audioPlayer.currentTrack },
                            onQueue: { draftController.attempt(action: { showUpNext = true }) },
                            onPrevious: {
                                draftController.attempt(action: {
                                    runWithoutAnimation {
                                        audioPlayer.previous()
                                    }
                                })
                            },
                            onNext: {
                                draftController.attempt(action: {
                                    runWithoutAnimation {
                                        audioPlayer.next()
                                    }
                                })
                            },
                            onEditTrack: { draftController.attempt(action: { trackToEdit = audioPlayer.currentTrack }) },
                            onVersionTap: { draftController.attempt(action: { showMixSwitcher = true }) }
                        )
                        .frame(height: playerH)

                        NoteComposerBar(
                            track: track,
                            voiceNoteController: voiceNoteController,
                            modelContext: modelContext,
                            downloadManager: downloadManager,
                            uploadQueue: uploadQueue,
                            draftController: draftController
                        )
                        .padding(.horizontal, 16)

                        if hasVisibleNotes {
                            Color.clear.frame(height: notesGapH)
                            TrackDetailView(
                                modelContext: modelContext,
                                downloadManager: downloadManager
                            )
                        }

                        Color.clear.frame(height: bottomGap)
                    }
                    .background(
                        NotesScrollResolver(
                            state: notesScrollState,
                            isEnabled: scrollShouldBeEnabled
                        )
                    )
                }
                .scrollContentBackground(.hidden)
            }

            ScrollContentTopFade(baseColor: .black, topInset: safeAreaTop, fadeHeight: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .environment(audioPlayer)
        .environment(downloadManager)
        .modelContext(modelContext)
        .onAppear { refreshHasVisibleNotes() }
        .onChange(of: audioPlayer.currentTrack?.id) { _, _ in
            refreshHasVisibleNotes()
            // Keep the UIScrollView reference; only toggle enabled. Nilling the
            // bridge here made notes scroll dead until an async resolver retry
            // happened to win — pan-to-dismiss then stole vertical drags.
            notesScrollState.applyEnabled(scrollShouldBeEnabled)
        }
        .onChange(of: audioPlayer.currentTrack?.visibleNotes.count) { _, _ in
            refreshHasVisibleNotes()
        }
        .onChange(of: audioPlayer.currentVersion?.id) { _, _ in
            refreshHasVisibleNotes()
        }
        .onPreferenceChange(ComposerHeightPreferenceKey.self) { newHeight in
            if newHeight > 0 { composerHeight = newHeight }
        }
        .sheet(isPresented: $showShareSheet) {
            if let fileURL = audioPlayer.currentFileURL {
                ShareSheet(items: [fileURL])
            }
        }
        .sheet(isPresented: $showMixSwitcher) {
            if let track = audioPlayer.currentTrack {
                MixSwitcherSheet(
                    track: track,
                    onSelectMix: { mix in
                        draftController.attempt(action: {
                            showMixSwitcher = false
                            guard mix.id != audioPlayer.currentVersion?.id else { return }
                            let wasPlaying = audioPlayer.isPlaying
                            let currentTime = audioPlayer.currentTime
                            audioPlayer.load(track: track, version: mix, startTime: currentTime, autoPlay: wasPlaying)
                        })
                    },
                    isPresented: $showMixSwitcher,
                    downloadManager: downloadManager
                )
            }
        }
        .sheet(item: $trackToEdit) { track in
            EditTrackSheet(track: track)
                .environment(audioPlayer)
                .environment(downloadManager)
                .modelContext(modelContext)
        }
        .sheet(item: $trackToAddToPlaylist) { track in
            AddTracksToPlaylistSheet(
                playlist: nil,
                tracks: (try? modelContext.fetch(FetchDescriptor<Track>())) ?? [track],
                preselectedTrackIDs: [track.id],
                createdPlaylist: .constant(nil)
            )
            .environment(downloadManager)
            .modelContext(modelContext)
        }
        .sheet(isPresented: $showUpNext) {
            UpNextSheet()
                .environment(audioPlayer)
        }
        .onChange(of: draftController.hasDraft) { _, hasDraft in
            audioPlayer.canAutoAdvance = !hasDraft
        }
        .onChange(of: hasVisibleNotes) { _, _ in
            notesScrollState.applyEnabled(scrollShouldBeEnabled)
        }
        .onChange(of: voiceNoteController.state.isRecording) { _, _ in
            notesScrollState.applyEnabled(scrollShouldBeEnabled)
        }
        .onDisappear {
            voiceNoteController.cancel()
            audioPlayer.canAutoAdvance = true
            notesScrollState.scrollView = nil
            notesScrollState.isEnabled = false
        }
        .alert("Unsaved Draft", isPresented: Binding(
            get: { draftController.showDiscardAlert },
            set: { draftController.showDiscardAlert = $0 }
        )) {
            Button("Keep Draft", role: .cancel) { draftController.cancelDiscard() }
            Button("Discard & Continue", role: .destructive) { draftController.confirmDiscard() }
        } message: {
            Text("You have an unsaved note. Keep it or discard?")
        }
    }

    private func refreshHasVisibleNotes() {
        let next = !(audioPlayer.currentTrack?.visibleNotes(forVersion: audioPlayer.currentVersion?.id).isEmpty ?? true)
        if hasVisibleNotes != next {
            hasVisibleNotes = next
        }
    }

    private func handleDismiss() {
        voiceNoteController.cancel()
        onDismiss()
    }

    private func runWithoutAnimation(_ action: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        transaction.animation = nil
        withTransaction(transaction) {
            action()
        }
    }
}

// MARK: - Scroll bridge

final class NotesScrollState {
    weak var scrollView: UIScrollView?
    var isEnabled = false

    func applyEnabled(_ enabled: Bool) {
        isEnabled = enabled
        scrollView?.isScrollEnabled = enabled
    }
}

/// Resolves the inner notes ScrollView back to UIKit so the sheet controller
/// can coordinate drag-to-dismiss with the notes scroll position.
private struct NotesScrollResolver: UIViewRepresentable {
    let state: NotesScrollState
    var isEnabled: Bool

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Resolve synchronously first — the async Task+sleep path often lost
        // the race and left isScrollEnabled sticky-false.
        if apply(to: uiView) { return }

        // One deferred pass for when the scroll view isn't in the hierarchy yet
        // on this update cycle (common on first expand / track switch).
        DispatchQueue.main.async {
            _ = self.apply(to: uiView)
        }
    }

    @discardableResult
    private func apply(to uiView: UIView) -> Bool {
        guard let scrollView = scrollContaining(uiView) else {
            state.isEnabled = isEnabled
            // Don't wipe a previously resolved scroll view just because this
            // update ran before the view was re-parented.
            if let existing = state.scrollView {
                existing.isScrollEnabled = isEnabled
            }
            return false
        }
        state.scrollView = scrollView
        state.isEnabled = isEnabled
        scrollView.isScrollEnabled = isEnabled
        scrollView.keyboardDismissMode = .onDrag
        scrollView.alwaysBounceVertical = true
        return true
    }

    private func scrollContaining(_ view: UIView) -> UIScrollView? {
        var parent: UIView? = view.superview
        while let current = parent {
            if let scroll = current as? UIScrollView { return scroll }
            parent = current.superview
        }
        return nil
    }
}
