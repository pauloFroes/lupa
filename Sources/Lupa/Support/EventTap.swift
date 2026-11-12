import AppKit
import ApplicationServices

/// A session-wide `CGEventTap` serviced on the main run loop.
///
/// Event taps need the Accessibility permission. macOS silently disables a tap whose callback is
/// slow or that loses to user input; this wrapper turns it back on so callers never go deaf.
final class EventTap {
    enum Mode {
        /// Observes events without being able to drop them. Appended at the tail of the chain.
        case listenOnly
        /// Can swallow events by returning `true` from the handler. Inserted at the head.
        case filter
    }

    /// Returns `true` to swallow the event. Ignored in `.listenOnly` mode.
    typealias Handler = (CGEventType, CGEvent) -> Bool

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: Handler?
    private var mode = Mode.listenOnly

    var isRunning: Bool { tap != nil }

    static func mask(_ types: CGEventType...) -> CGEventMask {
        types.reduce(0) { $0 | (1 << $1.rawValue) }
    }

    deinit {
        stop()
    }

    /// Returns `false` when the process is not trusted for Accessibility or macOS refuses the tap.
    @discardableResult
    func start(mask: CGEventMask, mode: Mode, handler: @escaping Handler) -> Bool {
        stop()
        guard AXIsProcessTrusted() else { return false }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: mode == .filter ? .headInsertEventTap : .tailAppendEventTap,
                options: mode == .filter ? .defaultTap : .listenOnly,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        self.handler = handler
        self.mode = mode
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        handler = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let swallow = handler?(type, event) ?? false
        return swallow && mode == .filter ? nil : Unmanaged.passUnretained(event)
    }
}
