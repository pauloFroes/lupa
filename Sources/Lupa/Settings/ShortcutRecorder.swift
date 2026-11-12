import AppKit
import Carbon.HIToolbox
import Combine

/// Captures a new key combination for an action in Settings.
///
/// Global hot keys are unregistered while recording (`onBegin`/`onEnd`); otherwise Carbon would
/// swallow the combination before the local monitor sees it.
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var recording: Action?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    private var monitor: Any?

    func toggle(_ action: Action) {
        if recording == action { cancel() } else { begin(action) }
    }

    func cancel() {
        guard recording != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        onEnd?()
    }

    private func begin(_ action: Action) {
        cancel()
        recording = action
        onBegin?()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard let action = recording else { return }
        if Int(event.keyCode) == kVK_Escape {
            cancel()
            return
        }
        let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags.rawValue)
        let hasModifier = !shortcut.flags.intersection([.control, .option, .command]).isEmpty
        let prefs = Preferences.shared
        let taken = prefs.shortcuts.contains { $0.key != action && $0.value == shortcut }
        guard hasModifier, !taken else {
            NSSound.beep()
            return
        }
        prefs.shortcuts[action] = shortcut
        cancel()
    }
}
