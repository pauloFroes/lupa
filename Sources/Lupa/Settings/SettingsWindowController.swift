import AppKit
import SwiftUI

/// Owns the Settings window, created lazily and kept around once opened.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let recorder = ShortcutRecorder()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let content = SettingsView(prefs: .shared, recorder: recorder)
            // On a laptop the natural height of Settings exceeds the screen: size the window to
            // what fits and let the content scroll. It can be stretched up to the natural height.
            let probe = NSHostingView(rootView: content)
            let natural = probe.fittingSize
            let host = NSHostingController(rootView: ScrollView { content }.background(Palette.paper))
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = String(localized: "Lupa Settings")
            window.styleMask = [.titled, .closable, .resizable]
            window.backgroundColor = Theme.paper100
            // Settings are drawn on light paper. In Dark Mode, native controls would turn dark
            // and show white text on a light background.
            window.appearance = NSAppearance(named: .aqua)
            let available = (NSScreen.main?.visibleFrame.height ?? 800) - 80
            window.setContentSize(NSSize(width: natural.width, height: min(natural.height, available)))
            window.contentMinSize = NSSize(width: natural.width, height: min(360, natural.height))
            window.contentMaxSize = NSSize(width: natural.width, height: natural.height)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        recorder.cancel()
    }
}
