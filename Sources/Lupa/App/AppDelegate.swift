import AppKit
import Carbon.HIToolbox
import Combine

/// Owns the status item and global shortcuts, and switches between the modes: frozen zoom and
/// drawing, live zoom, break timer and recording.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let prefs = Preferences.shared
    private let settings = SettingsWindowController()
    private let live = LiveZoomController()
    private let liveInput = LiveZoomInput()
    private let recording = RecordingController()
    private var cancellables = Set<AnyCancellable>()

    private var statusItem: NSStatusItem?
    private var actionItems: [Action: NSMenuItem] = [:]
    private var pauseItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var recordingTicker: Timer?

    private var overlayWindow: OverlayWindow?
    private var zoomView: ZoomDrawView?
    private var breakWindow: OverlayWindow?
    private var breakView: BreakTimerView?
    private var focus = FocusRestorer()
    private var capturing = false

    private var hotKeyIDs: [HotKeyCenter.ID] = []
    private var liveHotKeyIDs: [HotKeyCenter.ID] = []
    private var pauseHotKeyID: HotKeyCenter.ID?

    /// While recording, the screen is always in live zoom with click-to-zoom.
    private var recordingActive = false
    /// Whether live zoom was opened by the recording (and should close with it).
    private var liveStartedByRecording = false

    /// Pause/resume while recording: the record shortcut plus ⇧ (⌃⇧5 by default).
    private var pauseShortcut: Shortcut? { prefs.shortcuts[.record]?.addingShift }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpEditMenu()
        setUpStatusItem()
        registerHotKeys(prefs.shortcuts)
        prefs.$shortcuts
            .dropFirst()
            .sink { [weak self] shortcuts in
                self?.registerHotKeys(shortcuts)
                self?.updateMenuShortcuts(shortcuts)
            }
            .store(in: &cancellables)
        settings.recorder.onBegin = { [weak self] in self?.unregisterHotKeys() }
        settings.recorder.onEnd = { [weak self] in
            guard let self else { return }
            registerHotKeys(prefs.shortcuts)
        }
        live.onStop = { [weak self] in
            guard let self else { return }
            unregisterLiveHotKeys()
            recording.liveZoomActive = false
        }
        recording.shortcutLabel = { [weak self] in self?.prefs.shortcuts[.record]?.displayString ?? "" }
        recording.pauseShortcutLabel = { [weak self] in self?.pauseShortcut?.displayString ?? "" }
        recording.onChange = { [weak self] in self?.updateRecordingState() }
        requestScreenCaptureIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemCursor.show()
    }

    // MARK: - Menu bar

    /// An accessory app has no menu bar of its own, so ⌘C/⌘V never reach text fields. A hidden
    /// main menu with the standard Edit items restores them.
    private func setUpEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Lupa")
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(
            withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        )
        edit.addItem(
            withTitle: String(localized: "Close Window"), action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.idleIcon

        let menu = NSMenu()
        menu.delegate = self
        for action in Action.allCases {
            let entry = NSMenuItem(title: action.title, action: #selector(menuAction(_:)), keyEquivalent: "")
            entry.representedObject = action.rawValue
            entry.target = self
            menu.addItem(entry)
            actionItems[action] = entry
        }
        let pause = menuItem(String(localized: "Pause Recording"), #selector(togglePause))
        pause.isHidden = true
        menu.addItem(pause)
        pauseItem = pause
        menu.addItem(menuItem(String(localized: "Open Recordings Folder"), #selector(openRecordingsFolder)))
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Settings…"), #selector(openSettings), key: ","))
        let login = menuItem(String(localized: "Open at Login"), #selector(toggleLogin))
        menu.addItem(login)
        loginItem = login
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "About Lupa"), #selector(showAbout)))
        menu.addItem(
            NSMenuItem(
                title: String(localized: "Quit Lupa"), action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )

        item.menu = menu
        statusItem = item
        updateMenuShortcuts(prefs.shortcuts)
    }

    private static var idleIcon: NSImage? {
        let image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Lupa")
        image?.isTemplate = true
        return image
    }

    private func menuItem(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    private func updateMenuShortcuts(_ shortcuts: [Action: Shortcut]) {
        for (action, item) in actionItems {
            if let shortcut = shortcuts[action], let key = KeyNames.keyEquivalent(for: shortcut.keyCode) {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = shortcut.flags
            } else {
                item.keyEquivalent = ""
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem?.state = LoginItem.isEnabled ? .on : .off
    }

    /// The menu is still fading out when the action arrives; wait so it is not in the screenshot.
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = Action(rawValue: raw) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.perform(action) }
    }

    @objc private func togglePause() {
        recording.togglePause()
    }

    @objc private func openRecordingsFolder() {
        let folder = ScreenRecorder.folder(for: prefs.recording)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func toggleLogin() {
        LoginItem.set(!LoginItem.isEnabled)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Lupa",
            .credits: NSAttributedString(
                string: String(
                    localized: "Zoom, annotation, break timer and screen recording for presenters on the Mac.")
                    + "\ngithub.com/pauloFroes/lupa"
            ),
        ])
    }

    // MARK: - Recording state

    /// While recording, the status icon becomes a red dot with the elapsed time and the record item
    /// turns into "Stop".
    private func updateRecordingState() {
        let state = recording.state
        let active = state == .recording || state == .paused
        actionItems[.record]?.title = active ? String(localized: "Stop Recording") : Action.record.title
        pauseItem?.isHidden = !active
        pauseItem?.title =
            state == .paused ? String(localized: "Resume Recording") : String(localized: "Pause Recording")
        recordingTicker?.invalidate()
        recordingTicker = nil
        if active {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshStatusButton() }
            RunLoop.main.add(timer, forMode: .common)
            recordingTicker = timer
        }
        refreshStatusButton()
        syncLiveWithRecording()
    }

    private func refreshStatusButton() {
        guard let item = statusItem, let button = item.button else { return }
        let state = recording.state
        guard state == .recording || state == .paused else {
            item.length = NSStatusItem.squareLength
            button.title = ""
            button.image = Self.idleIcon
            return
        }
        item.length = NSStatusItem.variableLength
        let symbol = state == .paused ? "pause.circle.fill" : "record.circle.fill"
        let config = NSImage.SymbolConfiguration(paletteColors: [state == .paused ? Theme.ink300 : Theme.danger])
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: String(localized: "Recording"))?
            .withSymbolConfiguration(config)
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(
            string: " " + RecordingController.format(recording.elapsed),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)]
        )
    }

    private func syncLiveWithRecording() {
        let active = recording.isRecording
        guard active != recordingActive else { return }
        recordingActive = active
        if let pauseHotKeyID { HotKeyCenter.shared.unregister(pauseHotKeyID) }
        pauseHotKeyID = nil
        if active, let shortcut = pauseShortcut {
            pauseHotKeyID = HotKeyCenter.shared.register(shortcut) { [weak self] in self?.recording.togglePause() }
        }
        if active {
            if live.isActive {
                live.setAutoZoom(true, level: prefs.initialZoom)
                registerLiveHotKeys()
                recording.liveZoomActive = true
            } else {
                liveStartedByRecording = true
                startLive()
            }
        } else {
            if liveStartedByRecording {
                if zoomView?.isLive == true { closeOverlay() }
                live.stop(animated: true)
            } else if live.isActive {
                live.setAutoZoom(false, level: prefs.initialZoom)
                registerLiveHotKeys()
            }
            liveStartedByRecording = false
        }
    }

    /// Zoom, drawing and the break timer close live zoom; when they end mid-recording, go back to it.
    private func resumeLiveForRecording() {
        guard recordingActive, !live.isActive else { return }
        liveStartedByRecording = true
        startLive()
    }

    // MARK: - Shortcuts

    private func registerHotKeys(_ shortcuts: [Action: Shortcut]) {
        unregisterHotKeys()
        for (action, shortcut) in shortcuts {
            if let id = HotKeyCenter.shared.register(shortcut, handler: { [weak self] in self?.perform(action) }) {
                hotKeyIDs.append(id)
            }
        }
    }

    private func unregisterHotKeys() {
        HotKeyCenter.shared.unregister(&hotKeyIDs)
    }

    /// Live zoom never takes keyboard focus, so its keys are global hot keys that only exist while
    /// it runs. That includes Esc, which goes back to the apps as soon as live zoom ends.
    private func registerLiveHotKeys() {
        unregisterLiveHotKeys()
        let control = NSEvent.ModifierFlags.control.rawValue
        let controlShift = control | NSEvent.ModifierFlags.shift.rawValue
        // ⌃⇧= as well, because "+" is ⇧= on most layouts and that is where the hand goes.
        var bindings: [(key: Int, modifiers: UInt, handler: () -> Void)] = [
            (kVK_ANSI_Equal, control, { [weak self] in self?.live.adjust(by: 1.25) }),
            (kVK_ANSI_Equal, controlShift, { [weak self] in self?.live.adjust(by: 1.25) }),
            (kVK_ANSI_KeypadPlus, control, { [weak self] in self?.live.adjust(by: 1.25) }),
            (kVK_ANSI_Minus, control, { [weak self] in self?.live.adjust(by: 0.8) }),
            (kVK_ANSI_KeypadMinus, control, { [weak self] in self?.live.adjust(by: 0.8) }),
            (kVK_ANSI_0, control, { [weak self] in self?.live.reset() }),
        ]
        // While recording, Esc stays with the apps (it is common in what is being recorded); live
        // zoom is left through its own shortcut instead.
        if !live.autoZoom {
            bindings.append((kVK_Escape, 0, { [weak self] in self?.live.stop(animated: true) }))
        }
        for binding in bindings {
            let shortcut = Shortcut(keyCode: UInt32(binding.key), modifiers: binding.modifiers)
            if let id = HotKeyCenter.shared.register(shortcut, handler: binding.handler) {
                liveHotKeyIDs.append(id)
            }
        }
        liveInput.onZoom = { [weak self] factor in self?.live.adjust(by: factor) }
        liveInput.start()
        Log.liveZoom.info(
            "Gestures \(self.liveInput.consumesGestures ? "consumed by an event tap" : "observed by a global monitor", privacy: .public)"
        )
        live.setGestureNote(
            liveInput.consumesGestures
                ? nil : String(localized: "allow Lupa in Accessibility so pinch does not reach the app below")
        )
        let askedKey = "askedAccessibilityForLiveZoom"
        if !liveInput.consumesGestures, !UserDefaults.standard.bool(forKey: askedKey) {
            UserDefaults.standard.set(true, forKey: askedKey)
            LiveZoomInput.requestAccessibility()
        }
    }

    private func unregisterLiveHotKeys() {
        HotKeyCenter.shared.unregister(&liveHotKeyIDs)
        liveInput.stop()
    }

    // MARK: - Modes

    func perform(_ action: Action) {
        switch action {
        case .zoom:
            if zoomView != nil { closeOverlay() } else { startOverlay(.zoom) }
        case .draw:
            if let view = zoomView {
                if view.mode == .zoom { view.switchToDraw() } else { closeOverlay() }
            } else if live.isLive {
                startLiveDraw()
            } else {
                startOverlay(.draw)
            }
        case .breakTimer:
            if breakView != nil { closeBreak() } else { startBreak() }
        case .liveZoom:
            if live.isActive {
                if zoomView?.isLive == true { closeOverlay() }
                live.stop(animated: true)
            } else {
                startLive()
            }
        case .record:
            recording.toggle()
        }
    }

    private func startOverlay(_ mode: ZoomDrawView.Mode) {
        guard !capturing else { return }
        live.stop()
        closeBreak()
        capturing = true
        let screen = ScreenCapture.screenUnderMouse()
        focus.remember()
        Task { @MainActor in
            defer { self.capturing = false }
            do {
                let image = try await ScreenCapture.capture(screen: screen)
                self.presentOverlay(image: image, screen: screen, mode: mode)
            } catch {
                self.showCaptureError(error)
            }
        }
    }

    /// Live drawing: a transparent window over live zoom, which keeps streaming the screen (videos
    /// playing, text cursors blinking). A recording captures both together.
    private func startLiveDraw() {
        guard let screen = live.screen else { return }
        // Live zoom's keys (Esc, ⌃+, ⌃-) and pinch belong to the drawing while it is open.
        unregisterLiveHotKeys()
        live.setDrawing(true)
        focus.remember()
        presentOverlay(image: nil, screen: screen, mode: .draw)
        overlayWindow?.ignoresMouseEvents = false
    }

    private func presentOverlay(image: CGImage?, screen: NSScreen, mode: ZoomDrawView.Mode) {
        let window = OverlayWindow(screen: screen)
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - screen.frame.minX, y: mouse.y - screen.frame.minY)
        let view = ZoomDrawView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            snapshot: image,
            mode: mode,
            initialZoom: prefs.initialZoom,
            penIndex: prefs.pen,
            mouse: local
        )
        view.onExit = { [weak self] in
            self?.closeOverlay()
            self?.resumeLiveForRecording()
        }
        window.contentView = view
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        overlayWindow = window
        zoomView = view
    }

    private func closeOverlay() {
        guard let window = overlayWindow else { return }
        let wasLive = zoomView?.isLive == true
        zoomView?.stop()
        window.orderOut(nil)
        overlayWindow = nil
        zoomView = nil
        focus.restore()
        if wasLive, live.isActive {
            live.setDrawing(false)
            registerLiveHotKeys()
        }
    }

    private func startBreak() {
        live.stop()
        closeOverlay()
        let screen = ScreenCapture.screenUnderMouse()
        focus.remember()
        let window = OverlayWindow(screen: screen)
        let view = BreakTimerView(frame: NSRect(origin: .zero, size: screen.frame.size), duration: prefs.breakDuration)
        view.onExit = { [weak self] in
            self?.closeBreak()
            self?.resumeLiveForRecording()
        }
        window.contentView = view
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        breakWindow = window
        breakView = view
    }

    private func closeBreak() {
        guard let window = breakWindow else { return }
        breakView?.stop()
        window.orderOut(nil)
        breakWindow = nil
        breakView = nil
        focus.restore()
    }

    private func startLive() {
        guard !capturing else { return }
        closeOverlay()
        closeBreak()
        capturing = true
        let auto = recording.isRecording
        let screen = auto ? (recording.screen ?? ScreenCapture.screenUnderMouse()) : ScreenCapture.screenUnderMouse()
        Task { @MainActor in
            defer { self.capturing = false }
            do {
                try await self.live.start(on: screen, zoom: self.prefs.initialZoom, autoZoom: auto)
                self.registerLiveHotKeys()
                self.recording.liveZoomActive = auto
            } catch {
                self.showCaptureError(error)
            }
        }
    }

    // MARK: - Permission

    /// macOS only prompts once per authorization. After a reset (for example, a new code signature)
    /// asking at launch puts Lupa back in the list instead of waiting for the first shortcut.
    private func requestScreenCaptureIfNeeded() {
        if !ScreenCapture.hasPermission { CGRequestScreenCaptureAccess() }
    }

    private func showCaptureError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if ScreenCapture.hasPermission {
            alert.messageText = String(localized: "Could not capture the screen")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        alert.messageText = String(localized: "Lupa needs to see your screen")
        alert.informativeText = String(
            localized: """
                To zoom and draw, Lupa takes a screenshot when you press the shortcut. Nothing is saved to disk or leaves your Mac.

                Turn Lupa on in System Settings › Privacy & Security › Screen & System Audio Recording, then open Lupa again.

                If Lupa is already on, the permission belongs to an older build: select Lupa in the list, click −, and open Lupa again.
                """
        )
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        if alert.runModal() == .alertFirstButtonReturn {
            CGRequestScreenCaptureAccess()
            ScreenCapture.openPrivacySettings()
        }
    }
}
