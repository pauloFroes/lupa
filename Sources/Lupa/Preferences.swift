import AppKit
import Combine

final class Preferences: ObservableObject {
    static let shared = Preferences()

    static let zoomLevels: [CGFloat] = [1.5, 2, 3, 4]
    static let zoomLabels = ["1,5×", "2×", "3×", "4×"]
    static let breakMinutes = [5, 10, 15, 30]
    static let cursorSizes: [CGFloat] = [1.5, 2, 2.5, 3]
    static let cursorSizeLabels = ["1,5×", "2×", "2,5×", "3×"]
    static let cursorSmoothingLabels = ["Leve", "Média", "Forte"]
    static let cursorSmoothings: [LiveCursor.Smoothing] = [
        .init(stiffness: 700, damping: 48),
        .init(stiffness: 320, damping: 29),
        .init(stiffness: 170, damping: 22),
    ]

    private enum Keys {
        static let shortcuts = "shortcuts"
        static let zoom = "initialZoomIndex"
        static let pen = "penIndex"
        static let breakLength = "breakIndex"
        static let recording = "recordingOptions"
        static let cursorSize = "liveCursorSizeIndex"
        static let cursorSmoothing = "liveCursorSmoothingIndex"
        static let captions = "captionOptions"
    }

    private let defaults = UserDefaults.standard

    @Published var shortcuts: [Action: Shortcut] {
        didSet { saveShortcuts() }
    }

    @Published var zoomIndex: Int {
        didSet { defaults.set(zoomIndex, forKey: Keys.zoom) }
    }

    @Published var penIndex: Int {
        didSet { defaults.set(penIndex, forKey: Keys.pen) }
    }

    @Published var breakIndex: Int {
        didSet { defaults.set(breakIndex, forKey: Keys.breakLength) }
    }

    @Published var cursorSizeIndex: Int {
        didSet { defaults.set(cursorSizeIndex, forKey: Keys.cursorSize) }
    }

    @Published var cursorSmoothingIndex: Int {
        didSet { defaults.set(cursorSmoothingIndex, forKey: Keys.cursorSmoothing) }
    }

    @Published var recording: RecordingOptions {
        didSet {
            if let data = try? JSONEncoder().encode(recording) { defaults.set(data, forKey: Keys.recording) }
        }
    }

    @Published var captions: CaptionOptions {
        didSet {
            if let data = try? JSONEncoder().encode(captions) { defaults.set(data, forKey: Keys.captions) }
        }
    }

    var initialZoom: CGFloat {
        Self.zoomLevels[zoomIndex.clamped(0, Self.zoomLevels.count - 1)]
    }

    var breakDuration: TimeInterval {
        TimeInterval(Self.breakMinutes[breakIndex.clamped(0, Self.breakMinutes.count - 1)] * 60)
    }

    var cursorSize: CGFloat {
        Self.cursorSizes[cursorSizeIndex.clamped(0, Self.cursorSizes.count - 1)]
    }

    var cursorSmoothing: LiveCursor.Smoothing {
        Self.cursorSmoothings[cursorSmoothingIndex.clamped(0, Self.cursorSmoothings.count - 1)]
    }

    var pen: Int { penIndex.clamped(0, Pens.all.count - 1) }

    private init() {
        zoomIndex = defaults.object(forKey: Keys.zoom) as? Int ?? 1
        penIndex = defaults.object(forKey: Keys.pen) as? Int ?? 0
        breakIndex = defaults.object(forKey: Keys.breakLength) as? Int ?? 1
        cursorSizeIndex = defaults.object(forKey: Keys.cursorSize) as? Int ?? 1
        cursorSmoothingIndex = defaults.object(forKey: Keys.cursorSmoothing) as? Int ?? 1
        shortcuts = Self.loadShortcuts(from: defaults)
        recording = defaults.data(forKey: Keys.recording)
            .flatMap { try? JSONDecoder().decode(RecordingOptions.self, from: $0) } ?? RecordingOptions()
        captions = defaults.data(forKey: Keys.captions)
            .flatMap { try? JSONDecoder().decode(CaptionOptions.self, from: $0) } ?? CaptionOptions()
    }

    private static func loadShortcuts(from defaults: UserDefaults) -> [Action: Shortcut] {
        var result = Dictionary(uniqueKeysWithValues: Action.allCases.map { ($0, $0.defaultShortcut) })
        guard
            let data = defaults.data(forKey: Keys.shortcuts),
            let stored = try? JSONDecoder().decode([String: Shortcut].self, from: data)
        else { return result }
        for (raw, shortcut) in stored {
            if let action = Action(rawValue: raw) { result[action] = shortcut }
        }
        return result
    }

    private func saveShortcuts() {
        let stored = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Keys.shortcuts)
        }
    }
}
