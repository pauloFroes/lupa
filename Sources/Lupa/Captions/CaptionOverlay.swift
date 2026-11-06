import AppKit
import SwiftUI

final class CaptionModel: ObservableObject {
    // Texto já fechado pela OpenAI e o trecho que ainda está sendo dito (pode mudar).
    @Published var text = ""
    @Published var pending = ""
    @Published var visible = false
    @Published var fontSize: CGFloat = 30
    // Aviso curto (erro): aparece no lugar da legenda, em tom apagado.
    @Published var notice: String?
}

// Legenda no Eduliv Design System: cartão de tinta (ink 900) com borda ink 700, filete lime à
// esquerda, Manrope semibold em papel. O trecho ainda em fala aparece em ink 300 e clareia quando
// a OpenAI o fecha.
struct CaptionView: View {
    @ObservedObject var model: CaptionModel

    private var caption: Text {
        let finished = Text(model.text).foregroundColor(Color(nsColor: Theme.paper50))
        guard !model.pending.isEmpty else { return finished }
        let gap = model.text.isEmpty ? "" : " "
        return finished + Text(gap + model.pending).foregroundColor(Color(nsColor: Theme.ink300))
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if model.visible, model.notice != nil || !(model.text.isEmpty && model.pending.isEmpty) {
                HStack(alignment: .center, spacing: model.fontSize * 0.55) {
                    Capsule()
                        .fill(Color(nsColor: model.notice == nil ? Theme.lime : Theme.danger))
                        .frame(width: max(4, model.fontSize * 0.14))
                        .frame(maxHeight: .infinity)
                    Group {
                        if let notice = model.notice {
                            Text(notice).foregroundColor(Color(nsColor: Theme.ink200))
                                .font(Font(Theme.text(model.fontSize * 0.62, .semibold) as CTFont))
                        } else {
                            caption.font(Font(Theme.text(model.fontSize, .semibold) as CTFont))
                        }
                    }
                    .tracking(-0.2)
                    .lineSpacing(model.fontSize * 0.12)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, model.fontSize * 0.5)
                .padding(.trailing, model.fontSize * 0.8)
                .padding(.vertical, model.fontSize * 0.45)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(nsColor: Theme.ink900).opacity(0.94))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(nsColor: Theme.ink700), lineWidth: 1)
                )
                .shadow(color: Color(nsColor: Theme.ink1000).opacity(0.45), radius: 18, y: 8)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: model.visible)
        .animation(.easeOut(duration: 0.25), value: model.pending.isEmpty)
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
        let height = fontSize * 3.6 + 60
        let bottom = max(24, rect.height * 0.06)
        setFrame(CGRect(x: rect.midX - width / 2, y: rect.minY + bottom, width: width, height: height), display: true)
    }
}
