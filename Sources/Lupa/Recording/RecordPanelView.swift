import AVFoundation
import AppKit
import SwiftUI

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

struct RecordPanelView: View {
    @ObservedObject var prefs: Preferences
    let microphones: [Microphone]
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("gravar a tela")
                    .font(Font(Theme.display(28, .semibold) as CTFont))
                    .tracking(-0.6)
                Spacer()
                Text(shortcut)
                    .font(.lupaMono(13))
                    .foregroundColor(Palette.lime)
            }
            Segmented(options: ["Tela inteira", "Área"], selection: sourceIndex, onInk: true)

            VStack(spacing: 0) {
                toggleRow("Som do sistema", "O que toca no Mac, sem o som da Lupa.", isOn: $prefs.recording.systemAudio)
                divider
                toggleRow("Microfone", "Sua voz numa faixa separada.", isOn: $prefs.recording.microphone)
                if prefs.recording.microphone {
                    Picker("", selection: microphoneID) {
                        Text("Padrão do sistema").tag("")
                        ForEach(microphones) { mic in Text(mic.name).tag(mic.id) }
                    }
                    .labelsHidden()
                    .padding(.bottom, 10)
                }
                divider
                toggleRow("Câmera em bolha", "Arraste a bolha para onde quiser.", isOn: $prefs.recording.camera)
                divider
                toggleRow("Mostrar cliques", "Um anel marca cada clique no vídeo.", isOn: $prefs.recording.showClicks)
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.inkRaised))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.inkBorder, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                eyebrow("QUALIDADE")
                Segmented(options: RecordingOptions.Quality.allCases.map(\.label), selection: qualityIndex, onInk: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                eyebrow("QUADROS POR SEGUNDO")
                Segmented(options: ["30 fps", "60 fps"], selection: fpsIndex, onInk: true)
            }

            HStack(spacing: 10) {
                Text("salva em Filmes › Lupa")
                    .font(.lupaText(12))
                    .foregroundColor(Palette.onInkMuted)
                Spacer()
                Button("Cancelar", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(GhostOnInkStyle())
                Button(action: onRecord) {
                    HStack(spacing: 8) {
                        Circle().fill(Color(nsColor: Theme.danger)).frame(width: 10, height: 10)
                        Text("Gravar")
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

    private var divider: some View {
        Rectangle().fill(Palette.inkBorder).frame(height: 1)
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.lupaMono(11, .medium))
            .tracking(1.3)
            .foregroundColor(Palette.onInkMuted)
    }

    private func toggleRow(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.lupaText(14, .semibold))
                Text(detail).font(.lupaText(12)).foregroundColor(Palette.onInkMuted)
            }
            Spacer()
            LimeToggle(isOn: isOn.wrappedValue) { isOn.wrappedValue.toggle() }
        }
        .padding(.vertical, 10)
    }
}

private struct GhostOnInkStyle: ButtonStyle {
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

// CTA lime com a sombra dura olive: no clique ela cai de 6 para 2 px e o botão "afunda".
private struct PrimaryOnInkStyle: ButtonStyle {
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

struct RecordingDoneView: View {
    let fileName: String
    let duration: String
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("pronto. \(duration) gravados.")
                    .font(Font(Theme.display(20, .semibold) as CTFont))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(Palette.onInkMuted)
                .accessibilityLabel("Fechar")
            }
            Text(fileName)
                .font(.lupaMono(12))
                .foregroundColor(Palette.onInkText)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 10) {
                Button("Mostrar no Finder", action: onReveal).buttonStyle(GhostOnInkStyle())
                Button("Abrir", action: onOpen).buttonStyle(PrimaryOnInkStyle())
            }
        }
        .padding(20)
        .frame(width: 380)
        .foregroundColor(Palette.paper)
        .background(RoundedRectangle(cornerRadius: 18).fill(Palette.ink))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.inkBorder, lineWidth: 1))
    }
}
