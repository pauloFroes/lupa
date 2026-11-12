import AppKit

@main
enum LupaApp {
    static func main() {
        let app = NSApplication.shared
        // `NSApplication.delegate` is weak; this local lives as long as `run()`, which never returns.
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
