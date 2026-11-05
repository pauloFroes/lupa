import AppKit
import SwiftUI

final class RecordingControlModel: ObservableObject {
    @Published var time = "00:00"
    @Published var paused = false
}

// Barra flutuante durante a gravação: tempo, pausar e parar. Fica fora do vídeo (o gravador a
// exclui) e não rouba o foco do app que está sendo gravado.
final class RecordingControlBar {
    let model = RecordingControlModel()
    private var panel: NSPanel?

    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    func show(on screen: NSScreen, shortcut: String, onPause: @escaping () -> Void, onStop: @escaping () -> Void) {
        hide()
        model.time = "00:00"
        model.paused = false
        let view = RecordingControlView(model: model, shortcut: shortcut, onPause: onPause, onStop: onStop)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        let frame = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 12))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct RecordingControlView: View {
    @ObservedObject var model: RecordingControlModel
    let shortcut: String
    let onPause: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.paused ? Palette.onInkMuted : Palette.danger)
                .frame(width: 10, height: 10)
            Text(model.paused ? "pausado" : "gravando")
                .font(.lupaText(13, .semibold))
            Text(model.time)
                .font(.lupaMono(13))
                .foregroundColor(Palette.onInkText)
                .frame(minWidth: 48, alignment: .leading)
            Button(action: onPause) {
                Image(systemName: model.paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 32, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(Palette.inkBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(model.paused ? "Retomar" : "Pausar")
            Button(action: onStop) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                    Text("Parar").font(.lupaText(13, .bold))
                    if !shortcut.isEmpty {
                        Text(shortcut).font(.lupaMono(11)).opacity(0.7)
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.danger))
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(Palette.paper)
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .frame(height: 44)
        .background(Capsule().fill(Palette.ink))
        .overlay(Capsule().stroke(Palette.inkBorder, lineWidth: 1))
    }
}
