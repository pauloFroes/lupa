import AppKit
import SwiftUI

final class CaptionModel: ObservableObject {
    @Published var text = ""
    @Published var visible = false
    @Published var fontSize: CGFloat = 30
    // Aviso curto (conectando, erro): aparece no lugar da legenda, em tom apagado.
    @Published var notice: String?
}

struct CaptionView: View {
    @ObservedObject var model: CaptionModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if model.visible, let content = model.notice ?? (model.text.isEmpty ? nil : model.text) {
                Text(content)
                    .font(Font(Theme.text(model.notice == nil ? model.fontSize : model.fontSize * 0.6, .semibold) as CTFont))
                    .foregroundColor(model.notice == nil ? .white : Color(nsColor: Theme.ink200))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .lineSpacing(2)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(nsColor: Theme.ink1000).opacity(0.78))
                    )
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: model.visible)
    }
}

// Faixa da legenda, por cima de tudo (inclusive do Ao vivo e do desenho) e sem receber clique.
// Fica fora do zoom ao vivo (que exclui as janelas da Lupa) e entra na gravação.
final class CaptionWindow: NSPanel {
    init(model: CaptionModel) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: CaptionView(model: model))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Na base da tela (ou da área gravada), centralizada, com uma margem.
    func place(in rect: CGRect, fontSize: CGFloat) {
        let width = min(rect.width - 48, max(560, fontSize * 34))
        let height = fontSize * 3.4 + 24
        let bottom = max(24, rect.height * 0.06)
        setFrame(CGRect(x: rect.midX - width / 2, y: rect.minY + bottom, width: width, height: height), display: true)
    }
}
