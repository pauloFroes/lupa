import AppKit

/// A borderless, screen-sized window above everything, including full-screen apps.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }

    // Borderless windows refuse key status by default, which would leave Esc and the drawing
    // keys with nowhere to go.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
