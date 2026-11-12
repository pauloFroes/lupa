import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound
    case cannotExcludeSelf

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            String(localized: "Could not find the display under the pointer.")
        case .cannotExcludeSelf:
            String(localized: "Could not exclude Lupa from the capture; live zoom would film itself.")
        }
    }
}

enum ScreenCapture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func openPrivacySettings() {
        SystemSettings.openPrivacyPane("Privacy_ScreenCapture")
    }

    static func screenUnderMouse() -> NSScreen {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.uint32Value ?? CGMainDisplayID()
    }

    /// A filter for `screen` that leaves Lupa's own windows out; otherwise live zoom would capture
    /// its own output and zoom into itself forever.
    ///
    /// The shareable content is fetched with `onScreenWindowsOnly: false` on purpose: a menu bar
    /// app may be missing from the on-screen application list, and then nothing gets excluded.
    static func filter(for screen: NSScreen, requireExclusion: Bool = false) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let id = displayID(of: screen)
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.displayNotFound
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        if requireExclusion, ownApps.isEmpty { throw CaptureError.cannotExcludeSelf }
        return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
    }

    static func configuration(for screen: NSScreen) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        configuration.width = Int(screen.frame.width * scale)
        configuration.height = Int(screen.frame.height * scale)
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return configuration
    }

    static func capture(screen: NSScreen) async throws -> CGImage {
        let filter = try await filter(for: screen)
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration(for: screen)
        )
    }
}
