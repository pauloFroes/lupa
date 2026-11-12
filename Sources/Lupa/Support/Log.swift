import OSLog

/// Unified logging categories. Inspect them with:
///
///     log stream --predicate 'subsystem == "io.github.paulofroes.lupa"' --level debug
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.paulofroes.lupa"

    static let hotKeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let liveZoom = Logger(subsystem: subsystem, category: "live-zoom")
    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let cursor = Logger(subsystem: subsystem, category: "cursor")
}
