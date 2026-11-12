import AppKit

/// Hides the system cursor while Lupa is *not* the active app.
///
/// - Important: This relies on private SkyLight (CoreGraphics Services) API, resolved at run time
///   with `dlsym`, to set the WindowServer connection property `SetsCursorInBackground`. Public API
///   cannot hide the cursor from a background app. If a symbol is missing on a future macOS, every
///   call degrades to a no-op and the system cursor simply stays visible.
///
/// The frontmost app may bring the cursor back at any time, so `enforce()` re-applies the hide.
/// Hides are reference-counted by the WindowServer; `show()` balances every one of them.
enum SystemCursor {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private typealias IsVisible = @convention(c) () -> Int32
    private typealias CursorCall = @convention(c) (Int32) -> Int32

    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
    private static var wanted = false
    private static var displayHides = 0
    private static var connectionHides = 0

    private static let connection: Int32? = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        guard let symbol = dlsym(defaultHandle, "_CGSDefaultConnection") else { return nil }
        return unsafeBitCast(symbol, to: DefaultConnection.self)()
    }()

    private static func call(_ name: String) -> Bool {
        guard let connection, let symbol = dlsym(defaultHandle, name) else { return false }
        return unsafeBitCast(symbol, to: CursorCall.self)(connection) == 0
    }

    private static var isVisible: Bool {
        guard connection != nil, let symbol = dlsym(defaultHandle, "CGCursorIsVisible") else { return false }
        return unsafeBitCast(symbol, to: IsVisible.self)() != 0
    }

    private static func allowBackgroundCursorControl() {
        guard let connection, let symbol = dlsym(defaultHandle, "CGSSetConnectionProperty") else { return }
        let setProperty = unsafeBitCast(symbol, to: SetProperty.self)
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    private static func apply() {
        allowBackgroundCursorControl()
        CGDisplayHideCursor(CGMainDisplayID())
        displayHides += 1
        if isVisible, call("CGSHideCursor") { connectionHides += 1 }
        Log.cursor.debug("Hidden (visible: \(Self.isVisible), hides: \(Self.displayHides)+\(Self.connectionHides))")
    }

    static func hide() {
        guard !wanted else { return }
        wanted = true
        apply()
    }

    static func enforce() {
        if wanted, isVisible { apply() }
    }

    static func show() {
        guard wanted else { return }
        wanted = false
        for _ in 0..<displayHides { CGDisplayShowCursor(CGMainDisplayID()) }
        for _ in 0..<connectionHides { _ = call("CGSShowCursor") }
        Log.cursor.debug("Restored (hides: \(Self.displayHides)+\(Self.connectionHides))")
        displayHides = 0
        connectionHides = 0
    }
}
