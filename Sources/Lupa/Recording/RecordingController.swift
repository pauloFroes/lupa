import AVFoundation
import AppKit
import SwiftUI

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// Orquestra a gravação: painel de opções → área (se for o caso) → contagem → gravação →
// aviso de pronto. O estado aparece na barra de menus pelo `onChange`.
final class RecordingController {
    enum State {
        case idle
        case preparing
        case recording
        case paused
    }

    private(set) var state: State = .idle {
        didSet {
            updateControlBar()
            onChange?()
        }
    }

    var onChange: (() -> Void)?
    // Tela gravada, para o Ao vivo abrir nela.
    private(set) var screen: NSScreen?
    // Área gravada, em pontos da tela (nil = tela inteira).
    private(set) var area: CGRect?
    var onStarted: (() -> Void)?
    var onFinished: ((URL, TimeInterval) -> Void)?
    var isRecording: Bool { state == .recording || state == .paused }
    var liveZoomActive = false {
        didSet { recorder?.setLiveCursor(liveZoomActive) }
    }
    var shortcutLabel: () -> String = { "" }
    var pauseShortcutLabel: () -> String = { "" }

    private let prefs = Preferences.shared
    private let camera = CameraBubble()
    private var recorder: ScreenRecorder?
    private let controlBar = RecordingControlBar()
    private var controlTimer: Timer?
    private var panel: NSPanel?
    private var donePanel: NSPanel?
    private var selectorWindow: OverlayWindow?
    private var countdownWindow: OverlayWindow?
    private var countdownTimer: Timer?
    private var previousApp: NSRunningApplication?

    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        let pausedNow = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        return max(0, Date().timeIntervalSince(startedAt) - pausedTotal - pausedNow)
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        let hours = seconds / 3600
        let rest = String(format: "%02d:%02d", (seconds % 3600) / 60, seconds % 60)
        return hours > 0 ? "\(hours):\(rest)" : rest
    }

    func toggle() {
        switch state {
        case .idle: panel == nil ? showPanel() : closePanel()
        case .preparing: cancelPreparation()
        case .recording, .paused: stop()
        }
    }

    func togglePause() {
        switch state {
        case .recording:
            recorder?.pause()
            pausedAt = Date()
            state = .paused
        case .paused:
            recorder?.resume()
            if let pausedAt { pausedTotal += Date().timeIntervalSince(pausedAt) }
            pausedAt = nil
            state = .recording
        default:
            break
        }
    }

    // MARK: - Painel

    private func showPanel() {
        closeDonePanel()
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }

        let view = RecordPanelView(
            prefs: prefs,
            microphones: Microphone.available(),
            shortcut: shortcutLabel(),
            onRecord: { [weak self] in self?.beginFromPanel() },
            onCancel: { [weak self] in self?.closePanel(restoreFocus: true) }
        )
        let panel = makePanel(rootView: view)
        let screen = ScreenCapture.screenUnderMouse()
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    private func makePanel(rootView: some View) -> NSPanel {
        let host = NSHostingView(rootView: rootView)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        return panel
    }

    private func closePanel(restoreFocus: Bool = false) {
        panel?.orderOut(nil)
        panel = nil
        if restoreFocus { restoreFrontApp() }
    }

    private func beginFromPanel() {
        closePanel()
        state = .preparing
        let screen = ScreenCapture.screenUnderMouse()
        Task { @MainActor in
            guard await self.requestDevicePermissions() else {
                self.state = .idle
                self.restoreFrontApp()
                return
            }
            if self.prefs.recording.source == .area {
                self.selectArea(on: screen)
            } else {
                self.countdown(screen: screen, area: nil)
            }
        }
    }

    private func requestDevicePermissions() async -> Bool {
        let options = prefs.recording
        if options.microphone, await !Self.ensureAccess(.audio) {
            showDeviceAlert("microfone", pane: "Privacy_Microphone")
            return false
        }
        if options.camera, await !Self.ensureAccess(.video) {
            showDeviceAlert("câmera", pane: "Privacy_Camera")
            return false
        }
        return true
    }

    private static func ensureAccess(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    private func showDeviceAlert(_ device: String, pane: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "A Lupa não tem acesso à \(device)"
        alert.informativeText = "Ligue a Lupa em Ajustes do Sistema › Privacidade e Segurança e tente de novo, ou desligue essa opção no painel de gravação."
        alert.addButton(withTitle: "Abrir Ajustes do Sistema")
        alert.addButton(withTitle: "Agora não")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Área e contagem

    private func selectArea(on screen: NSScreen) {
        let window = OverlayWindow(screen: screen)
        let view = AreaSelectorView(frame: NSRect(origin: .zero, size: screen.frame.size), previous: prefs.recording.lastArea)
        view.onFinish = { [weak self] rect in
            self?.selectorWindow?.orderOut(nil)
            self?.selectorWindow = nil
            guard let rect else {
                self?.cancelPreparation()
                return
            }
            if rect != view.bounds { self?.prefs.recording.lastArea = rect }
            self?.countdown(screen: screen, area: rect == view.bounds ? nil : rect)
        }
        window.contentView = view
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        selectorWindow = window
    }

    private func countdown(screen: NSScreen, area: CGRect?) {
        if prefs.recording.camera {
            camera.onMove = { [weak self] origin in self?.prefs.recording.cameraOrigin = origin }
            try? camera.show(on: screen, at: prefs.recording.cameraOrigin)
        }
        let window = OverlayWindow(screen: screen)
        window.ignoresMouseEvents = true
        let view = CountdownView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = view
        window.orderFrontRegardless()
        countdownWindow = window
        restoreFrontApp()

        var remaining = 3
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            remaining -= 1
            if remaining > 0 {
                view.value = remaining
                return
            }
            timer.invalidate()
            self?.countdownWindow?.orderOut(nil)
            self?.countdownWindow = nil
            // Um respiro para a janela da contagem sumir da tela antes do primeiro quadro.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.startRecording(screen: screen, area: area)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func cancelPreparation() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownWindow?.orderOut(nil)
        countdownWindow = nil
        selectorWindow?.orderOut(nil)
        selectorWindow = nil
        camera.hide()
        state = .idle
        restoreFrontApp()
    }

    // MARK: - Gravação

    private func startRecording(screen: NSScreen, area: CGRect?) {
        guard state == .preparing else { return }
        let recorder = ScreenRecorder()
        recorder.onFailure = { [weak self] error in self?.fail(error) }
        self.recorder = recorder
        let options = prefs.recording
        controlBar.show(
            on: screen,
            shortcut: shortcutLabel(),
            pauseShortcut: pauseShortcutLabel(),
            onPause: { [weak self] in self?.togglePause() },
            onStop: { [weak self] in self?.stop() }
        )
        let excluded = controlBar.windowID.map { [$0] } ?? []
        Task { @MainActor in
            do {
                // Um respiro para o macOS listar a barra antes do filtro que a exclui.
                try? await Task.sleep(nanoseconds: 100_000_000)
                try await recorder.start(screen: screen, area: area, options: options, excluding: excluded)
                recorder.setLiveCursor(self.liveZoomActive)
                self.screen = screen
                self.area = area
                self.startedAt = Date()
                self.pausedAt = nil
                self.pausedTotal = 0
                self.state = .recording
                self.onStarted?()
            } catch {
                self.fail(error)
            }
        }
    }

    private func stop() {
        guard let recorder else { return }
        let duration = elapsed
        self.recorder = nil
        state = .preparing
        Task { @MainActor in
            do {
                let url = try await recorder.stop()
                self.camera.hide()
                self.resetClock()
                self.state = .idle
                self.onFinished?(url, duration)
                self.showDonePanel(url: url, duration: duration)
            } catch {
                self.fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        let recorder = recorder
        self.recorder = nil
        camera.hide()
        resetClock()
        state = .idle
        Task { @MainActor in
            _ = try? await recorder?.stop()
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "a gravação parou"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func updateControlBar() {
        controlTimer?.invalidate()
        controlTimer = nil
        switch state {
        case .recording, .paused:
            controlBar.model.paused = state == .paused
            controlBar.model.time = Self.format(elapsed)
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.controlBar.model.time = Self.format(self.elapsed)
            }
            RunLoop.main.add(timer, forMode: .common)
            controlTimer = timer
        case .idle:
            controlBar.hide()
        case .preparing:
            if recorder == nil { controlBar.hide() }
        }
    }

    private func resetClock() {
        startedAt = nil
        pausedAt = nil
        pausedTotal = 0
    }

    private func restoreFrontApp() {
        previousApp?.activate(options: [])
        previousApp = nil
    }

    // MARK: - Pronto

    private func showDonePanel(url: URL, duration: TimeInterval) {
        closeDonePanel()
        let view = RecordingDoneView(
            fileName: url.lastPathComponent,
            folder: ScreenRecorder.label(for: url.deletingLastPathComponent()),
            duration: Self.format(duration),
            onOpen: { [weak self] in
                NSWorkspace.shared.open(url)
                self?.closeDonePanel()
            },
            onReveal: { [weak self] in
                NSWorkspace.shared.activateFileViewerSelecting([url])
                self?.closeDonePanel()
            },
            onClose: { [weak self] in self?.closeDonePanel() }
        )
        let panel = makePanel(rootView: view)
        let screen = ScreenCapture.screenUnderMouse().visibleFrame
        panel.setFrameOrigin(CGPoint(x: screen.maxX - panel.frame.width - 24, y: screen.maxY - panel.frame.height - 16))
        panel.orderFrontRegardless()
        donePanel = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak panel] in
            if let panel, self?.donePanel === panel { self?.closeDonePanel() }
        }
    }

    private func closeDonePanel() {
        donePanel?.orderOut(nil)
        donePanel = nil
    }
}
