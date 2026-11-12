import AVFoundation
import AppKit
import SwiftUI

struct RecordPanelView: View {
    @ObservedObject var prefs: Preferences
    let microphones: [Microphone]
    let cameras: [Camera]
    let shortcut: String
    let onRecord: () -> Void
    let onCancel: () -> Void

    private var sourceIndex: Binding<Int> {
        Binding(
            get: { prefs.recording.source == .display ? 0 : 1 },
            set: { prefs.recording.source = $0 == 0 ? .display : .area }
        )
    }

    private var qualityIndex: Binding<Int> {
        Binding(
            get: { RecordingOptions.Quality.allCases.firstIndex(of: prefs.recording.quality) ?? 0 },
            set: { prefs.recording.quality = RecordingOptions.Quality.allCases[$0] }
        )
    }

    private var fpsIndex: Binding<Int> {
        Binding(
            get: { prefs.recording.framesPerSecond == 30 ? 0 : 1 },
            set: { prefs.recording.framesPerSecond = $0 == 0 ? 30 : 60 }
        )
    }

    private var microphoneID: Binding<String> {
        Binding(
            get: { prefs.recording.microphoneID ?? "" },
            set: { prefs.recording.microphoneID = $0.isEmpty ? nil : $0 }
        )
    }

    private var cameraID: Binding<String> {
        Binding(
            get: { prefs.recording.cameraID ?? "" },
            set: { prefs.recording.cameraID = $0.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("record screen")
                    .font(Font(Theme.display(28, .semibold) as CTFont))
                    .tracking(-0.6)
                Spacer()
                Text(shortcut)
                    .font(.lupaMono(13))
                    .foregroundColor(Palette.lime)
            }
            Segmented(
                options: [String(localized: "Full screen"), String(localized: "Area")], selection: sourceIndex,
                onInk: true
            )

            VStack(spacing: 0) {
                toggleRow(
                    "System audio", "What plays on the Mac, minus Lupa's own sounds.",
                    isOn: $prefs.recording.systemAudio)
                divider
                toggleRow("Microphone", "Your voice, on a separate track.", isOn: $prefs.recording.microphone)
                if prefs.recording.microphone {
                    Picker("", selection: microphoneID) {
                        Text("System default").tag("")
                        ForEach(microphones) { mic in Text(mic.name).tag(mic.id) }
                    }
                    .labelsHidden()
                    MicrophoneMeter(deviceID: prefs.recording.microphoneID)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                }
                divider
                toggleRow(
                    "Camera bubble", "Dodges the mouse and comes back on its own. Hold ⌥ to drag it.",
                    isOn: $prefs.recording.camera)
                if prefs.recording.camera {
                    HStack(spacing: 14) {
                        CameraPreview(deviceID: prefs.recording.cameraID)
                            .frame(width: 104, height: 104)
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("", selection: cameraID) {
                                Text("Automatic (built-in camera)").tag("")
                                ForEach(cameras) { camera in Text(camera.name).tag(camera.id) }
                            }
                            .labelsHidden()
                            Text("Preview: this is how the bubble will look in the video.")
                                .font(.lupaText(12))
                                .foregroundColor(Palette.onInkMuted)
                        }
                    }
                    .padding(.bottom, 12)
                }
                divider
                toggleRow("Show clicks", "A ring marks every click in the video.", isOn: $prefs.recording.showClicks)
                divider
                toggleRow(
                    "Click sound", "Every click makes a “tick” in the video's audio.",
                    isOn: $prefs.recording.recordsClickSounds)
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.inkRaised))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.inkBorder, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                eyebrow("QUALITY")
                Segmented(options: RecordingOptions.Quality.allCases.map(\.label), selection: qualityIndex, onInk: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                eyebrow("FRAME RATE")
                Segmented(options: ["30 fps", "60 fps"], selection: fpsIndex, onInk: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                eyebrow("SAVE TO")
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Palette.onInkMuted)
                    Text(ScreenRecorder.label(for: folder))
                        .font(.lupaText(14, .semibold))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(folder.path)
                    Spacer()
                    if prefs.recording.folderPath != nil {
                        Button("Default") { prefs.recording.folderPath = nil }
                            .buttonStyle(.plain)
                            .font(.lupaText(12))
                            .foregroundColor(Palette.onInkMuted)
                            .help("Go back to Movies › Lupa")
                    }
                    Button("Change…", action: chooseFolder)
                        .buttonStyle(.plain)
                        .font(.lupaText(13, .semibold))
                        .foregroundColor(Palette.lime)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.inkRaised))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.inkBorder, lineWidth: 1))
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(GhostOnInkStyle())
                Button(action: onRecord) {
                    HStack(spacing: 8) {
                        Circle().fill(Color(nsColor: Theme.danger)).frame(width: 10, height: 10)
                        Text("Record")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PrimaryOnInkStyle())
            }
        }
        .padding(24)
        .frame(width: 520)
        .foregroundColor(Palette.paper)
        .background(RoundedRectangle(cornerRadius: 18).fill(Palette.ink))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.inkBorder, lineWidth: 1))
    }

    private var folder: URL { ScreenRecorder.folder(for: prefs.recording) }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Where to save recordings")
        panel.prompt = String(localized: "Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        // The recording panel floats, so the picker has to sit above it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.recording.folderPath = url.path == ScreenRecorder.defaultFolder.path ? nil : url.path
    }

    private var divider: some View {
        Rectangle().fill(Palette.inkBorder).frame(height: 1)
    }

    private func eyebrow(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.lupaMono(11, .medium))
            .tracking(1.3)
            .foregroundColor(Palette.onInkMuted)
    }

    private func toggleRow(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, isOn: Binding<Bool>) -> some View
    {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.lupaText(14, .semibold))
                Text(detail).font(.lupaText(12)).foregroundColor(Palette.onInkMuted)
            }
            Spacer()
            LimeToggle(label: title, isOn: isOn.wrappedValue) { isOn.wrappedValue.toggle() }
        }
        .padding(.vertical, 10)
    }
}

struct GhostOnInkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lupaText(14, .semibold))
            .foregroundColor(Palette.paper)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(configuration.isPressed ? Palette.inkRaised : .clear))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.inkBorder, lineWidth: 1))
    }
}

/// Lime call to action with a hard olive shadow that drops from 6 to 2 pt on press.
struct PrimaryOnInkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shadow: CGFloat = configuration.isPressed ? 2 : 6
        configuration.label
            .font(.lupaText(14, .bold))
            .foregroundColor(Palette.inkDeep)
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Palette.olive).offset(x: shadow, y: shadow)
                    RoundedRectangle(cornerRadius: 12).fill(Palette.lime)
                }
            )
            .offset(x: configuration.isPressed ? 4 : 0, y: configuration.isPressed ? 4 : 0)
    }
}
