import AppKit
import Carbon.HIToolbox
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let prefs = Preferences.shared
    private let settings = SettingsWindowController()
    private let live = LiveZoomController()
    private let recording = RecordingController()
    private var pauseItem: NSMenuItem?
    private var recordingTicker: Timer?

    private var statusItem: NSStatusItem?
    private var actionItems: [Action: NSMenuItem] = [:]
    private var loginItem: NSMenuItem?

    private var overlayWindow: OverlayWindow?
    private var zoomView: ZoomDrawView?
    private var breakWindow: OverlayWindow?
    private var breakView: BreakTimerView?
    private var previousApp: NSRunningApplication?
    private var capturing = false

    private var hotKeyIDs: [UInt32] = []
    private var liveHotKeyIDs: [UInt32] = []
    private var liveScrollMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
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
        live.onStop = { [weak self] in self?.unregisterLiveHotKeys() }
        recording.shortcutLabel = { [weak self] in self?.prefs.shortcuts[.record]?.displayString ?? "" }
        recording.onChange = { [weak self] in self?.updateRecordingState() }
        requestPermissionIfNeeded()
    }

    // MARK: - Barra de menus

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Lupa")
        image?.isTemplate = true
        item.button?.image = image

        let menu = NSMenu()
        menu.delegate = self
        for action in Action.allCases {
            let entry = NSMenuItem(title: action.title, action: #selector(menuAction(_:)), keyEquivalent: "")
            entry.representedObject = action.rawValue
            entry.target = self
            menu.addItem(entry)
            actionItems[action] = entry
        }
        let pause = menuItem("Pausar gravação", #selector(togglePause))
        pause.isHidden = true
        menu.addItem(pause)
        pauseItem = pause
        menu.addItem(.separator())
        menu.addItem(menuItem("Ajustes…", #selector(openSettings), key: ","))
        let login = menuItem("Abrir ao iniciar sessão", #selector(toggleLogin))
        menu.addItem(login)
        loginItem = login
        menu.addItem(.separator())
        menu.addItem(menuItem("Sobre a Lupa", #selector(showAbout)))
        let quit = NSMenuItem(title: "Sair da Lupa", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        updateMenuShortcuts(prefs.shortcuts)
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

    @objc private func togglePause() {
        recording.togglePause()
    }

    // Gravando, o ícone vira um ponto vermelho com o tempo corrido, e o item do menu vira "Parar".
    private func updateRecordingState() {
        let state = recording.state
        let active = state == .recording || state == .paused
        actionItems[.record]?.title = active ? "Parar gravação" : Action.record.title
        pauseItem?.isHidden = !active
        pauseItem?.title = state == .paused ? "Retomar gravação" : "Pausar gravação"
        recordingTicker?.invalidate()
        recordingTicker = nil
        if active {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshStatusButton() }
            RunLoop.main.add(timer, forMode: .common)
            recordingTicker = timer
        }
        refreshStatusButton()
    }

    private func refreshStatusButton() {
        guard let item = statusItem, let button = item.button else { return }
        let state = recording.state
        guard state == .recording || state == .paused else {
            item.length = NSStatusItem.squareLength
            button.title = ""
            let image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Lupa")
            image?.isTemplate = true
            button.image = image
            return
        }
        item.length = NSStatusItem.variableLength
        let symbol = state == .paused ? "pause.circle.fill" : "record.circle.fill"
        let config = NSImage.SymbolConfiguration(paletteColors: [state == .paused ? Theme.ink300 : Theme.danger])
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Gravando")?.withSymbolConfiguration(config)
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(
            string: " " + RecordingController.format(recording.elapsed),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)]
        )
    }

    // O menu ainda está sumindo quando a ação chega: espera um instante para ele não sair na foto.
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = Action(rawValue: raw) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.perform(action) }
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
            .credits: NSAttributedString(string: "Zoom, desenho e cronômetro de intervalo para quem apresenta no Mac.\ngithub.com/pauloFroes/lupa"),
        ])
    }

    // MARK: - Atalhos

    private func registerHotKeys(_ shortcuts: [Action: Shortcut]) {
        unregisterHotKeys()
        for (action, shortcut) in shortcuts {
            if let id = HotKeyCenter.shared.register(shortcut, handler: { [weak self] in self?.perform(action) }) {
                hotKeyIDs.append(id)
            }
        }
    }

    private func unregisterHotKeys() {
        hotKeyIDs.forEach { HotKeyCenter.shared.unregister($0) }
        hotKeyIDs.removeAll()
    }

    // No zoom ao vivo a Lupa não tem o teclado: estes atalhos valem só enquanto ele está ligado.
    // O esc global também; fora do zoom ao vivo ele volta para os apps.
    private func registerLiveHotKeys() {
        unregisterLiveHotKeys()
        let control = NSEvent.ModifierFlags.control.rawValue
        let bindings: [(Int, UInt, () -> Void)] = [
            (kVK_ANSI_Equal, control, { [weak self] in self?.live.adjust(by: 1.25) }),
            (kVK_ANSI_KeypadPlus, control, { [weak self] in self?.live.adjust(by: 1.25) }),
            (kVK_ANSI_Minus, control, { [weak self] in self?.live.adjust(by: 0.8) }),
            (kVK_ANSI_KeypadMinus, control, { [weak self] in self?.live.adjust(by: 0.8) }),
            (kVK_ANSI_0, control, { [weak self] in self?.live.reset() }),
            (kVK_Escape, 0, { [weak self] in self?.live.stop() }),
        ]
        for (key, modifiers, handler) in bindings {
            if let id = HotKeyCenter.shared.register(Shortcut(keyCode: UInt32(key), modifiers: modifiers), handler: handler) {
                liveHotKeyIDs.append(id)
            }
        }
        // Monitor global de rolagem não pede Acessibilidade; o app embaixo também recebe a rolagem.
        liveScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard event.modifierFlags.contains(.control), event.scrollingDeltaY != 0 else { return }
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 30 : event.scrollingDeltaY
            self?.live.adjust(by: pow(1.12, step))
        }
    }

    private func unregisterLiveHotKeys() {
        liveHotKeyIDs.forEach { HotKeyCenter.shared.unregister($0) }
        liveHotKeyIDs.removeAll()
        if let liveScrollMonitor { NSEvent.removeMonitor(liveScrollMonitor) }
        liveScrollMonitor = nil
    }

    // MARK: - Modos

    func perform(_ action: Action) {
        switch action {
        case .zoom:
            if zoomView != nil { closeOverlay() } else { startOverlay(.zoom) }
        case .draw:
            if let view = zoomView {
                if view.mode == .zoom { view.switchToDraw() } else { closeOverlay() }
            } else {
                startOverlay(.draw)
            }
        case .breakTimer:
            if breakView != nil { closeBreak() } else { startBreak() }
        case .liveZoom:
            if live.isActive { live.stop() } else { startLive() }
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
        rememberFrontApp()
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

    private func presentOverlay(image: CGImage, screen: NSScreen, mode: ZoomDrawView.Mode) {
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
        view.onExit = { [weak self] in self?.closeOverlay() }
        window.contentView = view
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        overlayWindow = window
        zoomView = view
    }

    private func closeOverlay() {
        guard let window = overlayWindow else { return }
        zoomView?.stop()
        window.orderOut(nil)
        overlayWindow = nil
        zoomView = nil
        restoreFrontApp()
    }

    private func startBreak() {
        live.stop()
        closeOverlay()
        let screen = ScreenCapture.screenUnderMouse()
        rememberFrontApp()
        let window = OverlayWindow(screen: screen)
        let view = BreakTimerView(frame: NSRect(origin: .zero, size: screen.frame.size), duration: prefs.breakDuration)
        view.onExit = { [weak self] in self?.closeBreak() }
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
        restoreFrontApp()
    }

    private func startLive() {
        guard !capturing else { return }
        closeOverlay()
        closeBreak()
        capturing = true
        let screen = ScreenCapture.screenUnderMouse()
        Task { @MainActor in
            defer { self.capturing = false }
            do {
                try await self.live.start(on: screen, zoom: self.prefs.initialZoom)
                self.registerLiveHotKeys()
            } catch {
                self.showCaptureError(error)
            }
        }
    }

    private func rememberFrontApp() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
    }

    private func restoreFrontApp() {
        previousApp?.activate(options: [])
        previousApp = nil
    }

    // MARK: - Permissão

    // O macOS só mostra o pedido uma vez por autorização; depois de zerada (assinatura nova),
    // pedir de novo na abertura recoloca a Lupa na lista em vez de esperar o primeiro atalho.
    private func requestPermissionIfNeeded() {
        if !ScreenCapture.hasPermission { CGRequestScreenCaptureAccess() }
    }

    private func showCaptureError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if ScreenCapture.hasPermission {
            alert.messageText = "não deu para capturar a tela"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        alert.messageText = "A Lupa precisa ver a sua tela"
        alert.informativeText = """
        Para aproximar e desenhar, a Lupa tira uma foto da tela na hora do atalho. Nada é gravado em disco nem sai do seu Mac.

        Ligue a Lupa em Ajustes do Sistema › Privacidade e Segurança › Gravação de Tela e Áudio do Sistema e abra a Lupa de novo.

        Se ela já aparece ligada, a autorização é de uma versão anterior: selecione a Lupa na lista, clique em − e abra a Lupa de novo.
        """
        alert.addButton(withTitle: "Abrir Ajustes do Sistema")
        alert.addButton(withTitle: "Agora não")
        if alert.runModal() == .alertFirstButtonReturn {
            CGRequestScreenCaptureAccess()
            ScreenCapture.openPrivacySettings()
        }
    }
}
