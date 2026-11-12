import AppKit

/// Observes every mouse button press in the session without consuming it: through a listen-only
/// event tap when Accessibility is granted, or a global `NSEvent` monitor otherwise.
final class ClickListener {
    private let tap = EventTap()
    private var monitor: Any?

    func start(onClick: @escaping () -> Void) {
        stop()
        let mask = EventTap.mask(.leftMouseDown, .rightMouseDown, .otherMouseDown)
        let tapped = tap.start(mask: mask, mode: .listenOnly) { _, _ in
            onClick()
            return false
        }
        if tapped { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
            onClick()
        }
    }

    func stop() {
        tap.stop()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
