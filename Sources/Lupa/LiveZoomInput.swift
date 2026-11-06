import AppKit
import ApplicationServices

// Pinça e ⌃+rolar no zoom ao vivo. A janela do zoom deixa o mouse passar para os apps, então os
// gestos chegam por um event tap. Com a permissão de Acessibilidade o tap é ativo e consome o
// gesto, e o app embaixo não aproxima junto; sem ela, um monitor global só escuta.
final class LiveZoomInput {
    var onZoom: ((CGFloat) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var monitor: Any?
    private(set) var consumesGestures = false

    func start() {
        stop()
        if AXIsProcessTrusted(), installTap() {
            consumesGestures = true
            return
        }
        consumesGestures = false
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            _ = self?.handle(event)
        }
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // Devolve true quando o evento virou zoom (e o tap ativo o consome).
    fileprivate func handle(_ event: NSEvent) -> Bool {
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

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func installTap() -> Bool {
        // 29 e 30 são os eventos de gesto do trackpad (a pinça chega como um deles).
        let mask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue) | (1 << 29) | (1 << 30)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let input = Unmanaged<LiveZoomInput>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                input.reenable()
                return Unmanaged.passUnretained(event)
            }
            guard let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
            return input.handle(nsEvent) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }
}
