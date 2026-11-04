import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound

    var errorDescription: String? {
        switch self {
        case .displayNotFound: "Não achei a tela onde está o cursor."
        }
    }
}

enum ScreenCapture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url { NSWorkspace.shared.open(url) }
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

    // As janelas da própria Lupa ficam fora da captura: sem isso o zoom ao vivo se filmaria.
    static func filter(for screen: NSScreen) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = displayID(of: screen)
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.displayNotFound
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
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
