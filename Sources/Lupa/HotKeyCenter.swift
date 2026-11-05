import AppKit
import Carbon.HIToolbox
import os

// Atalhos globais pelo Carbon: o RegisterEventHotKey não pede a permissão de Acessibilidade,
// ao contrário de um monitor global de teclado.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x4C55_5041 // "LUPA"

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
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
            // O Carbon já entrega o evento na thread principal. Chamar direto, sem a fila: se algo
            // travar a fila principal (uma exceção num job dela), os atalhos continuam respondendo.
            HotKeyCenter.shared.fire(hotKeyID.id)
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    @discardableResult
    func register(_ shortcut: Shortcut, handler: @escaping () -> Void) -> UInt32? {
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
            Self.log.error("atalho \(shortcut.displayString, privacy: .public) não registrou (status \(status, privacy: .public))")
            return nil
        }
        Self.log.notice("atalho \(shortcut.displayString, privacy: .public) registrado como \(id, privacy: .public)")
        refs[id] = ref
        handlers[id] = handler
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers[id] = nil
    }

    static let log = Logger(subsystem: "io.github.paulofroes.lupa", category: "atalhos")

    private func fire(_ id: UInt32) {
        Self.log.notice("atalho \(id, privacy: .public) disparou")
        handlers[id]?()
    }
}
