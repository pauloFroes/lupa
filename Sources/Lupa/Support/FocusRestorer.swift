import AppKit

/// Remembers which app was frontmost before Lupa took keyboard focus, so it can be reactivated
/// when Lupa's overlay or panel goes away.
struct FocusRestorer {
    private var previous: NSRunningApplication?

    mutating func remember() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previous = front
        }
    }

    mutating func restore() {
        previous?.activate(options: [])
        previous = nil
    }
}
