//
//  LockableTerminalView.swift
//  iGhostVT
//

import GameController
import GhosttyTerminal
import IOSurface
import QuartzCore
import UIKit

/// The app's terminal view: `TerminalView` plus the two locks.
///
/// The locks are for touch: a tab whose program takes taps of its own, or
/// one that is only being watched, should not have a stray touch raise the
/// software keyboard or move the focus. Hardware keys, paste and drops are
/// allowed under both; the program never notices a lock — output keeps
/// flowing, the surface keeps rendering, the session keeps running. The
/// blocking lives here, at the view — refuse hit testing and first
/// responder, or the software keyboard — instead of being scattered across
/// SwiftUI modifiers that each have to remember. Installed through
/// `TerminalViewState.makePlatformView` (see `TerminalTab`).
final class LockableTerminalView: TerminalView {
    /// When true touches never land (`hitTest` returns nil) and first
    /// responder is refused and released, so a tap cannot take the focus.
    /// Not an input barrier: with keyboard navigation on, the focus system
    /// still hands the view keys and the menu's Paste, which is allowed.
    var isInteractionLocked = false {
        didSet {
            updateAccessibility()
            guard isInteractionLocked, isFirstResponder else { return }
            resignFirstResponder()
        }
    }

    /// Keyboard lock: the software keyboard stays down. Touches, scrolling,
    /// selection, and hardware keys stay live — only the on-screen keyboard
    /// is refused.
    ///
    /// Swallowing the tap toggle is not enough on its own: the library
    /// becomes first responder from several other places — the long-press
    /// selection menu, a pointer click, the host's own `requestFocus` after a
    /// sheet dismisses — and each of those brought the keyboard back up. So
    /// the lock is enforced where every one of those paths ends instead, at
    /// the input view.
    var isSoftwareKeyboardLocked = false {
        didSet {
            guard isSoftwareKeyboardLocked != oldValue else { return }
            updateAccessibility()
            // The iPad shortcuts bar is not part of `inputAccessoryView`, and
            // an empty keyboard leaves it (and its dictation button) floating
            // over the terminal, stealing 40pt of grid. Empty its groups for
            // as long as the lock lasts.
            inputAssistantItem.leadingBarButtonGroups = []
            inputAssistantItem.trailingBarButtonGroups = []
            guard isFirstResponder else { return }
            // Already first responder: swap the input views in place, so
            // locking drops the keyboard that is up and unlocking brings it
            // back without the user having to tap again.
            reloadInputViews()
        }
    }

    /// Set on a tab whose shell runs on another device: a dropped file is
    /// copied there and its path on that device is what gets pasted
    /// (`TerminalDropDelegate`), since no path on this one means anything
    /// to that shell. Answers in order, nil for a file that did not get
    /// there.
    var uploadDroppedFiles: (@MainActor ([URL]) async -> [String?])?

    /// Told the paths a drop pasted (`TerminalDropDelegate`), in drop
    /// order, so the tab can offer them again (`TabAttributes.droppedFiles`).
    var onDroppedPaths: (@MainActor ([String]) -> Void)?

    /// Waits for the tab's connection before a drop pastes, since a paste
    /// sent while it connects goes nowhere. False when the wait is given up.
    var awaitConnection: (@MainActor () async -> Bool)?

    /// The terminal's width in columns, nil before the surface reported
    /// one. Copy as One Line reads where a row ends against it.
    var terminalColumns: (@MainActor () -> Int?)?

    /// What the terminal offers UIKit as its keyboard while locked. An empty
    /// view keeps first-responder status — and with it the hardware key
    /// path — while leaving nothing to raise.
    private lazy var suppressedInputView = UIView(frame: .zero)

    /// What dictation has typed and may still revise
    /// (`LockableTerminalView+Dictation`).
    var dictatedText = DictatedText()

    override var canBecomeFirstResponder: Bool {
        !isInteractionLocked && super.canBecomeFirstResponder
    }

    #if targetEnvironment(macCatalyst)
        /// Only the key window's terminal takes the keyboard. Every Mac
        /// window's scene is active at once, and each window hands its
        /// focus out on events of its own — its scene turning active, a tab
        /// whose shell exited, a session reconnecting, the helper's status
        /// — so a window behind took first responder and the keys left the
        /// window in front. Refused here, where every path ends (the host's
        /// `requestFocus`, the focus binding, a click); the window takes it
        /// back as it becomes key (`TerminalWindow.becomeKey`).
        @discardableResult
        override func becomeFirstResponder() -> Bool {
            guard window?.isKeyWindow == true else { return false }
            return super.becomeFirstResponder()
        }
    #endif

    override var inputView: UIView? {
        isSoftwareKeyboardLocked ? suppressedInputView : super.inputView
    }

    override var inputAccessoryView: UIView? {
        // The bar belongs to the keyboard; leaving it floating over a
        // keyboard that is not there reads as a half-open keyboard. Typing
        // on a hardware keyboard the user may not want it at all.
        if isSoftwareKeyboardLocked || barHiddenForHardwareKeyboard {
            return nil
        }
        return super.inputAccessoryView
    }

    /// Whether the onscreen keys are up, from the frame UIKit last announced
    /// for the keyboard. Connected is not the same as in use: a keyboard
    /// folio folded behind an iPad stays connected (`GCKeyboard` says so)
    /// while the person types on the onscreen keyboard, and the bar is what
    /// gives that keyboard Esc, Tab and the arrows — hiding it on the
    /// connection alone took them away. App-wide, like the keyboard: a
    /// terminal that joins a window while the keys are up knows they are.
    private static var softwareKeysOnScreen = false

    /// Taller than the strip a hardware keyboard leaves (the bar alone, or
    /// iPadOS's shortcuts bar, about 40–70 pt), shorter than any onscreen
    /// keyboard.
    private static let softwareKeysMinimumHeight: CGFloat = 120

    /// Settings ▸ Accessory Keys ▸ Hide with Hardware Keyboard, decided.
    /// Only the events that can change the answer — a keyboard connecting
    /// or going away, the keys coming up or going down, the setting flipping
    /// — move it (`updateHardwareKeyboardBar`). UIKit asks for the bar on
    /// every reload, and reloads come from everywhere: the library's
    /// geometry refreshes, and every `UserDefaults` write in the process,
    /// the app's own records of recent directories and remote tabs among
    /// them. When each of those recomputed the answer, a stale reading of
    /// the keys took the bar out from under the onscreen keyboard
    /// mid-sentence, at the moment some unrelated default was written.
    private var barHiddenForHardwareKeyboard = false

    private var observesHardwareKeyboard = false

    private func observeHardwareKeyboard() {
        observesHardwareKeyboard = true
        let center = NotificationCenter.default
        for name in [.GCKeyboardDidConnect, .GCKeyboardDidDisconnect, UserDefaults.didChangeNotification] {
            center.addObserver(self, selector: #selector(hardwareKeyboardChanged), name: name, object: nil)
        }
        center.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
        )
        center.addObserver(
            self,
            selector: #selector(keyboardFrameDidChange),
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil,
        )
        center.addObserver(
            self,
            selector: #selector(sceneDidActivate(_:)),
            name: UIScene.didActivateNotification,
            object: nil,
        )
        updateHardwareKeyboardBar(reason: "window")
    }

    /// Frames announced while the window is not in front — Control Center,
    /// the app switcher, a notification pulled down — are the system
    /// putting the keyboard away for a moment, not the person putting the
    /// keys away. Taken at their word they left the keys "gone" under a
    /// keyboard that came straight back, and the next decision hid the bar.
    private var isInFront: Bool {
        window?.windowScene?.activationState == .foregroundActive
    }

    /// The on-screen height of the frame UIKit last announced for the
    /// keyboard. Zero means the keys are hidden or undocked — floating or
    /// split, which announce a zero frame — and only then is the layout
    /// guide asked.
    private static var dockedKeyboardHeight: CGFloat = 0

    /// A docked keyboard: the frame UIKit announces, in screen coordinates,
    /// as the keyboard starts to move — early enough that the bar comes up
    /// with the keys. A zero frame decides nothing yet: hidden and undocked
    /// read the same here, and the guide tells them apart once settled.
    @objc private nonisolated func keyboardFrameWillChange(_ notification: Notification) {
        let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        Task { @MainActor [weak self] in
            guard let self, let frame, isInFront, let screen = window?.screen else { return }
            let visible = frame.intersection(screen.bounds)
            let height = visible.isNull ? 0 : visible.height
            Self.dockedKeyboardHeight = height
            guard height > 0 else { return }
            noteKeyboardHeight(height, reason: "keyboard frame")
        }
    }

    /// An undocked keyboard only a layout guide that follows it can find.
    /// The window's guide, not this view's: SwiftUI moves the terminal above
    /// a docked keyboard, so this view's guide overlaps almost nothing. Read
    /// once the keyboard has settled, when the guide has too — and never
    /// over a docked frame: with a keyboard folio connected, iPadOS 26 puts
    /// the guide at the bar alone (0–60 pt) under 400 pt of onscreen keys,
    /// and each reading hid the bar the frame had just shown, dozens of
    /// times a second, the grid resizing with it.
    @objc private nonisolated func keyboardFrameDidChange() {
        Task { @MainActor [weak self] in
            guard let self, isInFront, Self.dockedKeyboardHeight == 0 else { return }
            measureUndockedKeyboard(reason: "keyboard settled")
        }
    }

    /// Back in front, an undocked keyboard is wherever the system put it
    /// back, and it may not announce that.
    @objc private nonisolated func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as AnyObject? else { return }
        let sceneID = ObjectIdentifier(scene)
        Task { @MainActor [weak self] in
            guard let self, Self.dockedKeyboardHeight == 0,
                  let windowScene = window?.windowScene, ObjectIdentifier(windowScene) == sceneID
            else { return }
            measureUndockedKeyboard(reason: "scene active")
        }
    }

    /// iOS 17 on; an older system has no guide that follows an undocked
    /// keyboard and takes the zero frame at its word.
    private func measureUndockedKeyboard(reason: String) {
        guard let window else { return }
        guard #available(iOS 17.0, *) else {
            noteKeyboardHeight(0, reason: reason)
            return
        }
        let guide = window.keyboardLayoutGuide
        guide.followsUndockedKeyboard = true
        window.layoutIfNeeded()
        noteKeyboardHeight(guide.layoutFrame.intersection(window.bounds).height, reason: reason)
    }

    /// The keyboard's height includes the bar when the bar is up; only
    /// what is left above it are keys.
    private func noteKeyboardHeight(_ height: CGFloat, reason: String) {
        var keysHeight = height
        if let bar = super.inputAccessoryView, bar.window != nil {
            keysHeight -= bar.bounds.height
        }
        Self.softwareKeysOnScreen = keysHeight >= Self.softwareKeysMinimumHeight
        updateHardwareKeyboardBar(reason: "\(reason), keys \(Int(keysHeight)) pt")
    }

    /// Nonisolated: `UserDefaults.didChangeNotification` is posted on
    /// whatever thread wrote the default (PencilKit's `registerDefaults`
    /// from a background queue was the first), and a main-actor method
    /// called there traps before it can hop.
    @objc private nonisolated func hardwareKeyboardChanged() {
        Task { @MainActor [weak self] in
            self?.updateHardwareKeyboardBar(reason: "keyboard or setting")
        }
    }

    /// Decides the bar afresh and reloads only when the decision moved, so
    /// a reload never takes the bar away on its own.
    private func updateHardwareKeyboardBar(reason: String) {
        let hides = KeyboardBarStore.hidesWithHardwareKeyboard
            && GCKeyboard.coalesced != nil
            && !Self.softwareKeysOnScreen
        guard hides != barHiddenForHardwareKeyboard else { return }
        barHiddenForHardwareKeyboard = hides
        guard isFirstResponder else { return }
        AppLog.info(.keyboard, "accessory bar \(hides ? "hidden" : "shown") (\(reason))")
        reloadInputViews()
    }

    // MARK: - Back in front

    // A return to the front can leave the terminal drawn at the size it had
    // when it left. The engine's picture — an IOSurface, the sublayer's
    // contents — is rendered again at the view's size when the app comes
    // back (the metrics sync takes the new bounds), but the sublayer that
    // hands that picture to the screen can still sit at the old one, so the
    // new frame is shown squeezed into the old: rows cut down to their
    // tails, a prompt halfway across the pane, colors a redraw behind —
    // until ⌃L forces a redraw, which changes nothing in the grid and
    // everything on the screen. The grid itself was never wrong; the
    // surface was rendered at the new size all along.
    //
    // The library places that layer from `layoutSubviews` and from its own
    // metrics callback (`UITerminalView+Lifecycle.sublayerFrame`, which
    // holds the layer at `syncedViewSize` while a resize throttle runs), but
    // both read state that a return to the front rearranges: the bounds come
    // back with the keyboard's dismissal, animated over about a quarter of a
    // second, and the throttle — on for a tab with a program in front of its
    // shell, `ssh` on a forwarded port being one — holds the surface for
    // 128 ms per size. A pass that lands between two of those can place the
    // layer at a size the surface never took, or leave it at the old one.
    // The pass below is the library's own work, run once the runloop has
    // laid the view out again, and it is skipped when neither the view nor
    // the layer moved.

    /// Whether the return-to-front observers are in the notification centre.
    /// A view is made whenever a surface mounts, so this matters:
    /// `didMoveToWindow` runs again on every reattach.
    private var observesComingBack = false

    /// How long after a return the passes keep watching. Long enough for the
    /// keyboard's dismissal animation and one throttle window with room to
    /// spare; nothing is laid out in that time unless something is out of
    /// place.
    private static let comingBackWindow: CFTimeInterval = 3

    /// After a pass that handed the engine a new size, one look back for the
    /// layer: a sync the throttle deferred lands outside the pass that asked
    /// for it.
    private static let comingBackVerificationDelay: TimeInterval = 0.2

    /// No two full passes closer together than a throttle window, so a
    /// surface that cannot take a size yet — a session still connecting —
    /// does not queue one resize per runloop turn.
    private static let comingBackPassInterval: CFTimeInterval = 0.3

    private var comingBackDeadline: CFTimeInterval = 0
    private var comingBackPassScheduled = false
    private var lastFullPassAt: CFTimeInterval = 0

    /// What the last full pass left the view at. A return at the same size
    /// and scale has nothing to lay out: only a layer that fell out of place
    /// is put back (`placePictureLayers`), so coming back to the front does
    /// not reflow a terminal that never moved.
    private var lastRedrawSize: CGSize = .zero
    private var lastRedrawScale: CGFloat = 0

    /// Registered once, for the life of the view (`observeComingBack`), and
    /// removed in `deinit`. A view is made whenever a surface mounts, so the
    /// guard matters: `didMoveToWindow` runs again on every reattach.
    private func observeComingBack() {
        guard !observesComingBack else { return }
        observesComingBack = true
        let center = NotificationCenter.default
        // The scene tells which window came back, and a scene can come back
        // on its own (Stage Manager, an iPad with two windows); the app-level
        // one is the return every window hears on iOS. Either ends in the
        // same pass.
        for name in [UIScene.didActivateNotification, UIApplication.didBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(backInFront(_:)), name: name, object: nil)
        }
    }

    /// Nonisolated for the same reason the keyboard's observers are: the
    /// notification is delivered on whatever thread posted it.
    @objc private nonisolated func backInFront(_ notification: Notification) {
        // Only the scene notification names a scene; the app-level one names
        // the application, which says nothing about this view's window.
        let sceneID = (notification.object as? UIScene).map(ObjectIdentifier.init)
        Task { @MainActor [weak self] in
            self?.noteBackInFront(fromScene: sceneID)
        }
    }

    private func noteBackInFront(fromScene sceneID: ObjectIdentifier?) {
        guard let window else { return }
        if let sceneID, let scene = window.windowScene, ObjectIdentifier(scene) != sceneID {
            return
        }
        guard UIApplication.shared.applicationState == .active else { return }
        comingBackDeadline = CACurrentMediaTime() + Self.comingBackWindow
        schedulePassAfterComingBack()
    }

    /// Coalesced to one pass per runloop turn: one return announces itself
    /// twice (the scene and the app), and the layout that settles the new
    /// bounds announces itself too (`layoutSubviews` below).
    private func schedulePassAfterComingBack(delay: TimeInterval = 0) {
        guard !comingBackPassScheduled, comingBackDeadline > 0 else { return }
        comingBackPassScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { @MainActor [weak self] in
            guard let self else { return }
            comingBackPassScheduled = false
            passAfterComingBack()
        }
    }

    /// The bounds come back animated — a keyboard that was up is dismissed on
    /// the way in — so the pass is asked for from here as well, where each
    /// step of that animation lands, instead of once from the notification.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard comingBackDeadline > 0 else { return }
        schedulePassAfterComingBack()
    }

    private func passAfterComingBack() {
        guard window != nil, comingBackDeadline > 0 else { return }
        let now = CACurrentMediaTime()
        guard now <= comingBackDeadline else {
            comingBackDeadline = 0
            return
        }
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = engineScale
        // The placement first, and on its own: it is the whole of the
        // symptom, the surface can already be the size of the view while the
        // layer that shows it is not, and putting a layer back lays nothing
        // out — so a return that only lost the placement costs one
        // comparison and a frame assignment.
        let moved = placePictureLayers()
        let unchanged = bounds.size == lastRedrawSize && scale == lastRedrawScale
        guard !unchanged || surfaceLagsView(scale: scale) else {
            if moved {
                AppLog.info(.ghostty, "back in front: picture layer re-placed at \(sizeDescription)")
            }
            return
        }
        // A surface that cannot take a size yet — a session still connecting
        // — is not a reason to give up: the pass comes back once the window
        // allows, inside the same deadline.
        let sinceLastPass = now - lastFullPassAt
        guard sinceLastPass >= Self.comingBackPassInterval else {
            schedulePassAfterComingBack(delay: Self.comingBackPassInterval - sinceLastPass)
            return
        }
        lastFullPassAt = now
        setNeedsLayout()
        layoutIfNeeded()
        fitToSize()
        placePictureLayers()
        lastRedrawSize = bounds.size
        lastRedrawScale = engineScale
        AppLog.info(
            .ghostty,
            "back in front: laid out and re-fit \(sizeDescription), \(pictureDescription)",
        )
        schedulePassAfterComingBack(delay: Self.comingBackVerificationDelay)
    }

    /// The scale the library renders at — its `resolvedDisplayScale`: the
    /// window's screen when there is one to ask, the trait collection
    /// otherwise. Not `contentScaleFactor`, which the library sets from it,
    /// and which reads 1.0 on a view that has never been laid out.
    private var engineScale: CGFloat {
        if let scale = window?.screen.nativeScale, scale > 0 { return scale }
        if traitCollection.displayScale > 0 { return traitCollection.displayScale }
        return UIScreen.main.nativeScale
    }

    /// Every layer of the engine's, the one carrying the IOSurface among
    /// them, put at the view's bounds at the screen's scale — where the
    /// library would put it — and whether anything moved. Layers UIKit owns
    /// for text input and menus carry a view behind them and are left alone;
    /// a layer with no surface behind it has nothing drawn yet and is left to
    /// the library as well.
    @discardableResult
    private func placePictureLayers() -> Bool {
        let scale = engineScale
        var moved = false
        for sublayer in layer.sublayers ?? [] where !(sublayer.delegate is UIView) {
            // Pixels that are not the size of the view are the library's to
            // reconcile: while a resize throttle runs it holds the surface at
            // the older size on purpose and keeps the layer that size, so the
            // pixels it holds are shown 1:1 — a frame stretched to the bounds
            // would show that picture scaled, the flicker that rule exists to
            // prevent. Only a placement that lags a picture already the size
            // of the view is ours to correct.
            guard let surface = sublayer.contents as? IOSurface else { continue }
            let width = Int((bounds.width * scale).rounded())
            let height = Int((bounds.height * scale).rounded())
            guard abs(surface.width - width) <= 1, abs(surface.height - height) <= 1 else {
                continue
            }
            if sublayer.frame != bounds {
                sublayer.frame = bounds
                moved = true
            }
            if sublayer.contentsScale != scale {
                sublayer.contentsScale = scale
                moved = true
            }
        }
        return moved
    }

    /// Whether the engine's picture is a size other than the view's — the
    /// state the library's own sync is there to end, and one a pass has to
    /// hand it a size for.
    private func surfaceLagsView(scale: CGFloat) -> Bool {
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        for sublayer in layer.sublayers ?? [] where !(sublayer.delegate is UIView) {
            guard let surface = sublayer.contents as? IOSurface else { continue }
            if surface.width != width || surface.height != height { return true }
        }
        return false
    }

    private var sizeDescription: String {
        String(format: "%.0fx%.0f pt", bounds.width, bounds.height)
    }

    /// The picture and the layer that shows it, for a journal that has to say
    /// what the screen was told to draw when someone reports this again.
    private var pictureDescription: String {
        let pictures = (layer.sublayers ?? [])
            .filter { !($0.delegate is UIView) }
            .map { sublayer -> String in
                let surface = sublayer.contents as? IOSurface
                let pixels = surface.map { "\($0.width)x\($0.height)" } ?? "no surface"
                return String(
                    format: "%@ layer %.0fx%.0f @%.1f",
                    pixels,
                    sublayer.frame.width,
                    sublayer.frame.height,
                    sublayer.contentsScale,
                )
            }
        return pictures.isEmpty ? "no picture layer" : pictures.joined(separator: "; ")
    }

    /// A touch landed on a locked terminal — a tap or drag under the
    /// interaction lock, a tap that will raise no keyboard under the
    /// keyboard lock. The pane shows the lock's caption again, so a touch
    /// that does nothing says why. Hardware keys pass both locks and never
    /// call this.
    var onLockedTouch: (() -> Void)?
    /// UIKit hit-tests one touch several times; one notice per touch. Only
    /// a touch (or, under the interaction lock, a scroll) counts — a
    /// pointer hovering, a drag passing over, or an accessibility query
    /// hit-tests too, with another event type or none.
    private var lastLockedTouch: TimeInterval = 0

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isInteractionLocked || isSoftwareKeyboardLocked, let event,
           event.type == .touches || (isInteractionLocked && event.type == .scroll),
           self.point(inside: point, with: event),
           event.timestamp - lastLockedTouch > 0.3
        {
            lastLockedTouch = event.timestamp
            // Never from inside hit testing: the caption is SwiftUI state,
            // and UIKit is midway through routing this very touch.
            DispatchQueue.main.async { [weak self] in
                self?.onLockedTouch?()
            }
        }
        return isInteractionLocked ? nil : super.hitTest(point, with: event)
    }

    // MARK: - Accessibility

    /// The surface is one VoiceOver element: it draws its own grid, so there
    /// is nothing underneath for assistive technology to walk into. An
    /// interaction-locked view is no element at all — it refuses hit testing
    /// and first responder there, and an element would be a way back in;
    /// the pane's lock capsule still announces that state beside it.
    private func updateAccessibility() {
        isAccessibilityElement = !isInteractionLocked
        accessibilityLabel = String(localized: "Terminal")
        // Only the keyboard lock can be read here — the interaction lock
        // removes the element above. `TabLock` owns the wording the badge
        // and the capsule already speak.
        accessibilityValue = isSoftwareKeyboardLocked ? TabLock.keyboard.badgeTitle : nil
        // Output arrives without the user doing anything to prompt it.
        accessibilityTraits.insert(.updatesFrequently)
    }

    // MARK: - The app's shortcuts

    /// Presses taken by the app; their release must not reach the surface
    /// either, or ghostty sees a key go up that never came down.
    private var interceptedPresses: Set<UIPress> = []

    /// The app's chords (`KeyShortcuts`) go to the responder chain — the
    /// window answers, through `canPerformAction`, so a chord a menu item
    /// would grey out does nothing rather than reaching the shell. Every
    /// other press is the library's: the terminal's `pressesBegan` never
    /// calls `super`, so UIKit sees each key as handled and the menu's key
    /// commands never fire while a terminal has focus — which is why the
    /// claim has to be made here, before the library. Escape is never in
    /// the list: it always reaches the terminal.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // A key edits the line behind dictation's back.
        releaseDictatedText()
        var remaining = presses
        for press in presses {
            if let key = press.key, isRemotePaste(key) {
                remaining.remove(press)
                interceptedPresses.insert(press)
                pasteThroughUpload()
                continue
            }
            guard let key = press.key, let shortcut = KeyShortcuts.shortcut(for: key) else { continue }
            remaining.remove(press)
            interceptedPresses.insert(press)
            let sender = UICommand(title: "", action: shortcut.action, propertyList: shortcut.propertyList)
            UIApplication.shared.sendAction(shortcut.action, to: nil, from: sender, for: nil)
        }
        if !remaining.isEmpty {
            super.pressesBegan(remaining, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.subtracting(interceptedPresses)
        interceptedPresses.subtract(presses)
        if !remaining.isEmpty {
            super.pressesEnded(remaining, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.subtracting(interceptedPresses)
        interceptedPresses.subtract(presses)
        if !remaining.isEmpty {
            super.pressesCancelled(remaining, with: event)
        }
    }

    // MARK: - Paste on a remote tab

    /// A paste whose pasteboard holds a file — a screenshot, a photo, a
    /// file copied in Finder or Files — goes the way a drop does on a remote
    /// tab: copied to that device on the transfer pill, its path there
    /// pasted when it lands. The library would stage it here and paste a
    /// path on this device, which the shell over there cannot open. Text
    /// stays the library's paste.
    override func paste(_ sender: Any?) {
        guard uploadDroppedFiles != nil, TerminalDropDelegate.pasteNeedsUpload() else {
            super.paste(sender)
            return
        }
        pasteThroughUpload()
    }

    private func pasteThroughUpload() {
        AppLog.info(.drop, "paste on a remote tab: copying the pasteboard's files over")
        TerminalDropDelegate.deliver(UIPasteboard.general.itemProviders, to: self)
    }

    /// ⌘V reaches ghostty's paste binding, which reads text only — an image
    /// on the pasteboard pasted nothing, a copied file pasted its path here.
    private func isRemotePaste(_ key: UIKey) -> Bool {
        uploadDroppedFiles != nil
            && key.modifierFlags.intersection([.command, .control, .alternate, .shift]) == .command
            && key.charactersIgnoringModifiers.lowercased() == "v"
            && TerminalDropDelegate.pasteNeedsUpload()
    }

    #if !targetEnvironment(macCatalyst)
        /// The touch menu's Paste calls the library's paste directly, past
        /// `paste(_:)`; on a remote tab it is swapped for one that goes
        /// through the override.
        override func touchMenuItems(for context: TerminalTouchMenuContext) -> [UIMenuElement] {
            routingPaste(super.touchMenuItems(for: context))
        }

        /// A selection over more than one row gets Copy as One Line right
        /// after Copy, and one that is a web link, and nothing else, gets
        /// Open Link after that.
        override func touchSelectionMenuItems(for context: TerminalTouchSelectionMenuContext) -> [UIMenuElement] {
            var items = routingPaste(super.touchSelectionMenuItems(for: context))
            var extras: [UIMenuElement] = []
            if let line = OneLineText.join(context.selectedText, columns: terminalColumns?()) {
                extras.append(UIAction(
                    title: String(localized: "Copy as One Line"),
                    image: UIImage(systemName: "arrow.right.to.line"),
                    identifier: UIAction.Identifier("ighostvt.copyOneLine"),
                ) { _ in
                    UIPasteboard.general.string = line
                })
            }
            if let url = Self.link(in: context.selectedText) {
                extras.append(UIAction(
                    title: String(localized: "Open Link"),
                    image: UIImage(systemName: "safari"),
                    identifier: UIAction.Identifier("ighostvt.openLink"),
                ) { _ in
                    UIApplication.shared.open(url)
                })
            }
            guard !extras.isEmpty else { return items }
            let copy = items.firstIndex { ($0 as? UIAction)?.identifier.rawValue == "terminal.copy" }
            items.insert(contentsOf: extras, at: copy.map { $0 + 1 } ?? 0)
            return items
        }

        /// The selection as one http(s) link, or nil. The whitespace around
        /// it goes, and a link a program broke over rows — Claude Code
        /// prints each row as a line of its own — is put back together,
        /// each row's indent dropped. The whole selection has to be the
        /// link: one inside a sentence is not what was selected, and two
        /// rows of links are two links, not one. A selection longer than any
        /// link (Select All) is turned away before it is searched, since the
        /// menu is built on the main thread.
        static func link(in text: String) -> URL? {
            guard text.utf16.count <= 4096 else { return nil }
            let rows = text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let candidate = rows.joined()
            guard !candidate.isEmpty,
                  !candidate.contains(where: \.isWhitespace),
                  !rows.dropFirst().contains(where: { $0.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil }),
                  let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
                  let match = detector.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
                  match.range.length == (candidate as NSString).length,
                  let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            return url
        }

        private func routingPaste(_ items: [UIMenuElement]) -> [UIMenuElement] {
            guard uploadDroppedFiles != nil else { return items }
            return items.map { element in
                if let menu = element as? UIMenu {
                    return menu.replacingChildren(routingPaste(menu.children))
                }
                guard let action = element as? UIAction,
                      action.identifier.rawValue == "terminal.paste"
                else { return element }
                return UIAction(
                    title: action.title,
                    image: action.image,
                    identifier: action.identifier,
                ) { [weak self] _ in
                    self?.paste(nil)
                }
            }
        }
    #endif

    #if !targetEnvironment(macCatalyst)
        /// The library's tap path calls this after the tap's click has been
        /// sent; only the keyboard raise/dismiss is ours to swallow. On
        /// Catalyst there is no software keyboard and no such member.
        override func toggleSoftwareKeyboard() {
            guard !isSoftwareKeyboardLocked else { return }
            super.toggleSoftwareKeyboard()
        }
    #endif

    /// Retains the drop delegate: `UIDropInteraction` holds its delegate
    /// weakly, and non-nil is also the flag that the swap already happened.
    private var dropDelegate: TerminalDropDelegate?

    /// Every observer this view takes is registered against `self` with a
    /// selector, so one removal covers them all: the keyboard bar's, and the
    /// return to the front's (`observeComingBack`). A view that goes away
    /// with a pass still queued takes it with it — the pass holds the view
    /// weakly and finds it gone.
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Swaps the library's drop handling for the app's
    /// (`TerminalDropDelegate`): a real path on the Mac, a staged copy on
    /// iOS, folders on both, and named-by-type files for data that has no
    /// file behind it.
    ///
    /// The library's `dropInteraction(_:performDrop:)` is `public`, not
    /// `open`, so a subclass cannot override it — replacing the whole
    /// interaction is what a host can do. The library installs its
    /// interaction from `setupPlatformInput()` during init, so by the time
    /// there is a window it is there to remove.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAccessibility()
        // With keyboard navigation on (the Mac's setting, Full Keyboard
        // Access) the focus system rings its focused item, and the terminal
        // is a whole pane: a grey or tinted frame around every terminal,
        // saying nothing the cursor does not. The view stays focusable.
        focusEffect = nil
        if !observesHardwareKeyboard {
            observeHardwareKeyboard()
        }
        observeComingBack()
        guard window != nil, dropDelegate == nil else { return }
        for interaction in interactions where interaction is UIDropInteraction {
            removeInteraction(interaction)
        }
        let delegate = TerminalDropDelegate(terminal: self)
        dropDelegate = delegate
        addInteraction(UIDropInteraction(delegate: delegate))
    }
}
