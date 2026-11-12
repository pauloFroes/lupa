import CoreGraphics

/// Everything the recording panel lets you choose. Persisted as JSON in `UserDefaults`, so new
/// fields must be optional or have a default to keep decoding older data.
struct RecordingOptions: Codable, Equatable {
    enum Source: String, Codable { case display, area }

    enum Quality: String, Codable, CaseIterable {
        case hevc
        case h264
        case prores

        var label: String {
            switch self {
            case .hevc: String(localized: "High · HEVC")
            case .h264: String(localized: "Compatible · H.264")
            case .prores: String(localized: "Maximum · ProRes")
            }
        }
    }

    var source: Source = .display
    var systemAudio = true
    var microphone = false
    var microphoneID: String?
    var camera = false
    /// `AVCaptureDevice.uniqueID` of the bubble camera; `nil` picks automatically (built-in first).
    var cameraID: String?
    var showClicks = true
    /// Optional only for decoding settings saved before this option existed (`nil` = off).
    var clickSounds: Bool?
    var recordsClickSounds: Bool {
        get { clickSounds ?? false }
        set { clickSounds = newValue }
    }
    var quality: Quality = .hevc
    var framesPerSecond = 60
    /// Last area and camera bubble position, in screen points (bottom-left origin), restored on
    /// the next recording.
    var lastArea: CGRect?
    var cameraOrigin: CGPoint?
    /// Output folder; `nil` means `~/Movies/Lupa`.
    var folderPath: String?
}
