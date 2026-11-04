import AppKit
import Combine

final class Preferences: ObservableObject {
    static let shared = Preferences()

    static let zoomLevels: [CGFloat] = [1.5, 2, 3, 4]
    static let zoomLabels = ["1,5×", "2×", "3×", "4×"]
    static let breakMinutes = [5, 10, 15, 30]

    private enum Keys {
        static let shortcuts = "shortcuts"
        static let zoom = "initialZoomIndex"
        static let pen = "penIndex"
        static let breakLength = "breakIndex"
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

    var initialZoom: CGFloat {
        Self.zoomLevels[zoomIndex.clamped(0, Self.zoomLevels.count - 1)]
    }

    var breakDuration: TimeInterval {
        TimeInterval(Self.breakMinutes[breakIndex.clamped(0, Self.breakMinutes.count - 1)] * 60)
    }

    var pen: Int { penIndex.clamped(0, Pens.all.count - 1) }

    private init() {
        zoomIndex = defaults.object(forKey: Keys.zoom) as? Int ?? 1
        penIndex = defaults.object(forKey: Keys.pen) as? Int ?? 0
        breakIndex = defaults.object(forKey: Keys.breakLength) as? Int ?? 1
        shortcuts = Self.loadShortcuts(from: defaults)
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
