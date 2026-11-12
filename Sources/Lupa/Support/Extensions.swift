import AppKit

extension Comparable {
    func clamped(_ lower: Self, _ upper: Self) -> Self {
        min(max(self, lower), upper)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension CGFloat {
    /// A zoom factor for display, using the current locale's decimal separator ("1.5×", "1,5×").
    var zoomLabel: String {
        Double(self).formatted(.number.precision(.fractionLength(0...1))) + "×"
    }
}

enum FileNames {
    /// "Lupa 2026-11-12 at 14.03.22.mov": sortable, and safe on every file system.
    static func timestamped(_ ext: String, date: Date = Date()) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH.mm.ss"
        let stem = String(localized: "Lupa \(day.string(from: date)) at \(time.string(from: date))")
        return "\(stem).\(ext)"
    }
}

enum SystemSettings {
    /// Opens a pane under System Settings › Privacy & Security, e.g. `Privacy_ScreenCapture`.
    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
