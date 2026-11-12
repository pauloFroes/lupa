import AppKit

/// Pinch and ⌃-scroll while live zoom is on.
///
/// The live zoom window lets the mouse through to the apps below, so gestures have to be picked
/// up globally. With the Accessibility permission an event tap swallows them and the app below
/// does not zoom along; without it a global monitor can only listen.
final class LiveZoomInput {
    var onZoom: ((CGFloat) -> Void)?

    private let tap = EventTap()
    private var monitor: Any?

    /// Whether gestures are swallowed (event tap) or merely observed (global monitor).
    var consumesGestures: Bool { tap.isRunning }

    // `NSEvent.EventType.gesture` and `.magnify`; a pinch arrives as one of these.
    private static let gestureTypes: CGEventMask = (1 << 29) | (1 << 30)

    func start() {
        stop()
        let mask = EventTap.mask(.scrollWheel) | Self.gestureTypes
        let tapped = tap.start(mask: mask, mode: .filter) { [weak self] _, event in
            guard let self, let nsEvent = NSEvent(cgEvent: event) else { return false }
            return self.handle(nsEvent)
        }
        if tapped { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            _ = self?.handle(event)
        }
    }

    func stop() {
        tap.stop()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Returns `true` when the event became a zoom step and should be swallowed.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .magnify:
            guard event.magnification != 0 else { return true }
            onZoom?(1 + event.magnification)
            return true
        case .scrollWheel:
            guard event.modifierFlags.contains(.control), event.scrollingDeltaY != 0 else { return false }
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 30 : event.scrollingDeltaY
            onZoom?(pow(1.12, step))
            return true
        default:
            return false
        }
    }
}
