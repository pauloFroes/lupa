import AVFoundation

/// Audio input offered in the recording panel.
struct Microphone: Identifiable, Hashable {
    let id: String
    let name: String

    static func available() -> [Microphone] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }
}

/// Video input offered in the recording panel.
struct Camera: Identifiable, Hashable {
    let id: String
    let name: String

    static func available() -> [Camera] {
        CameraBubble.devices().map { Camera(id: $0.uniqueID, name: $0.localizedName) }
    }
}
