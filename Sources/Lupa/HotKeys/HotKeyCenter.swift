import AppKit
import Carbon.HIToolbox

/// System-wide hot keys through Carbon's `RegisterEventHotKey`.
///
/// Unlike a global `NSEvent` keyboard monitor, this API needs no Accessibility permission and
/// consumes the key combination, so the frontmost app never sees it.
final class HotKeyCenter {
    typealias ID = UInt32

    static let shared = HotKeyCenter()

    private static let signature: OSType = 0x4C55_5041  // "LUPA"

    private var refs: [ID: EventHotKeyRef] = [:]
    private var handlers: [ID: () -> Void] = [:]
    private var nextID: ID = 1
    private var eventHandler: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                // Carbon already delivers on the main thread. Calling straight through, instead of
                // hopping onto the main queue, keeps hot keys alive even if that queue is wedged.
                HotKeyCenter.shared.fire(hotKeyID.id)
                return noErr
            },
            1,
            &spec,
            nil,
            &eventHandler
        )
    }

    /// Returns `nil` when the combination is already taken by the system or another app.
    @discardableResult
    func register(_ shortcut: Shortcut, handler: @escaping () -> Void) -> ID? {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            Log.hotKeys.error(
                "Could not register \(shortcut.displayString, privacy: .public) (OSStatus \(status, privacy: .public))"
            )
            return nil
        }
        Log.hotKeys.debug("Registered \(shortcut.displayString, privacy: .public) as #\(id, privacy: .public)")
        refs[id] = ref
        handlers[id] = handler
        return id
    }

    func unregister(_ id: ID) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers[id] = nil
    }

    func unregister(_ ids: inout [ID]) {
        for id in ids { unregister(id) }
        ids.removeAll()
    }

    private func fire(_ id: ID) {
        Log.hotKeys.debug("Hot key #\(id, privacy: .public) fired")
        handlers[id]?()
    }
}
