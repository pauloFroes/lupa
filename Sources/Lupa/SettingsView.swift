import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSSound.beep()
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

// Enquanto grava, os atalhos globais saem do ar: senão o Carbon engoliria a combinação
// antes de ela chegar ao monitor local.
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var recording: Action?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    private var monitor: Any?

    func toggle(_ action: Action) {
        if recording == action { cancel() } else { begin(action) }
    }

    func cancel() {
        guard recording != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        onEnd?()
    }

    private func begin(_ action: Action) {
        cancel()
        recording = action
        onBegin?()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard let action = recording else { return }
        if Int(event.keyCode) == kVK_Escape {
            cancel()
            return
        }
        let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags.rawValue)
        let hasModifier = !shortcut.flags.intersection([.control, .option, .command]).isEmpty
        let prefs = Preferences.shared
        let taken = prefs.shortcuts.contains { $0.key != action && $0.value == shortcut }
        guard hasModifier, !taken else {
            NSSound.beep()
            return
        }
        prefs.shortcuts[action] = shortcut
        cancel()
    }
}

enum Palette {
    static let ink = Color(nsColor: Theme.ink900)
    static let inkDeep = Color(nsColor: Theme.ink1000)
    static let inkRaised = Color(nsColor: Theme.ink800)
    static let inkBorder = Color(nsColor: Theme.ink700)
    static let onInkMuted = Color(nsColor: Theme.ink300)
    static let onInkText = Color(nsColor: Theme.ink200)
    static let olive = Color(nsColor: Theme.olive)
    static let muted = Color(nsColor: Theme.ink500)
    static let border = Color(nsColor: Theme.ink100)
    static let borderStrong = Color(nsColor: Theme.ink200)
    static let paper = Color(nsColor: Theme.paper100)
    static let surface = Color(nsColor: Theme.paper50)
    static let sunken = Color(nsColor: Theme.paper200)
    static let lime = Color(nsColor: Theme.lime)
    static let success = Color(nsColor: Theme.success)
    static let successSoft = Color(nsColor: Theme.successSoft)
    static let danger = Color(nsColor: Theme.danger)
    static let dangerSoft = Color(nsColor: Theme.dangerSoft)
}

extension Font {
    static func lupaText(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font {
        Font(Theme.text(size, weight) as CTFont)
    }

    static func lupaMono(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> Font {
        Font(Theme.mono(size, weight) as CTFont)
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var recorder: ShortcutRecorder
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var permission = ScreenCapture.hasPermission
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("ATALHOS GLOBAIS") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    ForEach(Action.allCases) { action in
                        shortcutRow(action)
                    }
                }
                Text("Clique num atalho e pressione a nova combinação. Esc cancela.")
                    .font(.lupaText(12))
                    .foregroundColor(Palette.muted)
            }
            section("ZOOM INICIAL") {
                Segmented(options: Preferences.zoomLabels, selection: $prefs.zoomIndex)
            }
            section("COR INICIAL DA CANETA") {
                HStack(spacing: 10) {
                    ForEach(Pens.all.indices, id: \.self) { index in
                        swatch(index)
                    }
                    Text("\(Pens.all[prefs.pen].name) (\(Pens.all[prefs.pen].key))")
                        .font(.lupaText(13))
                        .foregroundColor(Palette.muted)
                        .padding(.leading, 6)
                }
            }
            HStack(alignment: .top, spacing: 24) {
                section("CURSOR NO ZOOM AO VIVO") {
                    Segmented(options: Preferences.cursorSizeLabels, selection: $prefs.cursorSizeIndex)
                }
                section("SUAVIDADE DO CURSOR") {
                    Segmented(options: Preferences.cursorSmoothingLabels, selection: $prefs.cursorSmoothingIndex)
                }
            }
            section("INTERVALO PADRÃO") {
                Segmented(options: Preferences.breakMinutes.map { "\($0) min" }, selection: $prefs.breakIndex)
            }
            CaptionSettings(prefs: prefs)
            Rectangle().fill(Palette.border).frame(height: 1)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Abrir ao iniciar sessão").font(.lupaText(14, .semibold))
                    Text("A Lupa fica na barra de menus, sem ícone no Dock.")
                        .font(.lupaText(12))
                        .foregroundColor(Palette.muted)
                }
                Spacer()
                LimeToggle(isOn: loginEnabled) {
                    LoginItem.set(!loginEnabled)
                    loginEnabled = LoginItem.isEnabled
                }
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gravação de Tela").font(.lupaText(14, .semibold))
                    PermissionPill(granted: permission)
                }
                Spacer()
                Button("Abrir Ajustes do Sistema") { ScreenCapture.openPrivacySettings() }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(width: 680)
        .background(Palette.paper)
        .foregroundColor(Palette.ink)
        .onReceive(refresh) { _ in
            permission = ScreenCapture.hasPermission
            loginEnabled = LoginItem.isEnabled
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.lupaMono(11, .medium))
                .tracking(1.3)
                .foregroundColor(Palette.muted)
            content()
        }
    }

    private func shortcutRow(_ action: Action) -> some View {
        let isRecording = recorder.recording == action
        return HStack {
            Text(action.title).font(.lupaText(14, .semibold))
            Spacer()
            Button {
                recorder.toggle(action)
            } label: {
                Text(isRecording ? "pressione…" : (prefs.shortcuts[action]?.displayString ?? "—"))
                    .font(.lupaMono(13))
                    .frame(minWidth: 52)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
            }
            .buttonStyle(KeyCapStyle(active: isRecording))
            .accessibilityLabel("Gravar atalho de \(action.title)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border, lineWidth: 1))
    }

    private func swatch(_ index: Int) -> some View {
        let pen = Pens.all[index]
        let selected = prefs.pen == index
        return Button {
            prefs.penIndex = index
        } label: {
            Circle()
                .fill(Color(nsColor: pen.color))
                .frame(width: 32, height: 32)
                .overlay(Circle().stroke(selected ? Palette.paper : Palette.ink.opacity(0.2), lineWidth: selected ? 3 : 1))
                .overlay(Circle().stroke(selected ? Palette.ink : .clear, lineWidth: 2).padding(-2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pen.name)
        .help("\(pen.name) (\(pen.key))")
    }
}

struct Segmented: View {
    let options: [String]
    @Binding var selection: Int
    var onInk = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                let active = selection == index
                Button {
                    selection = index
                } label: {
                    Text(options[index])
                        .font(.lupaText(13, .semibold))
                        .foregroundColor(labelColor(active))
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(active ? (onInk ? Palette.lime : Palette.surface) : .clear)
                                .shadow(color: active && !onInk ? Palette.ink.opacity(0.08) : .clear, radius: 1, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12).fill(onInk ? Palette.inkRaised : Palette.sunken))
    }

    private func labelColor(_ active: Bool) -> Color {
        if onInk { return active ? Palette.inkDeep : Palette.onInkMuted }
        return active ? Palette.ink : Palette.muted
    }
}

private struct KeyCapStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(active ? Palette.inkDeep : Palette.ink)
            .background(RoundedRectangle(cornerRadius: 8).fill(active ? Palette.lime : Palette.paper))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? Palette.ink : Palette.borderStrong, lineWidth: active ? 2 : 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lupaText(13, .semibold))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 12).fill(configuration.isPressed ? Palette.sunken : .clear))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.borderStrong, lineWidth: 1))
    }
}

struct LimeToggle: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Palette.lime : Palette.borderStrong)
                    .overlay(Capsule().stroke(isOn ? Palette.ink : .clear, lineWidth: 2))
                    .frame(width: 46, height: 28)
                Circle()
                    .fill(Palette.ink)
                    .frame(width: 22, height: 22)
                    .padding(3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Abrir ao iniciar sessão")
        .accessibilityValue(isOn ? "ligado" : "desligado")
    }
}

private struct PermissionPill: View {
    let granted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(granted ? Palette.success : Palette.danger)
                .frame(width: 6, height: 6)
            Text(granted ? "permitida" : "não permitida")
                .font(.lupaText(12, .semibold))
        }
        .foregroundColor(granted ? Palette.success : Palette.danger)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(granted ? Palette.successSoft : Palette.dangerSoft))
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    let recorder = ShortcutRecorder()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let content = SettingsView(prefs: .shared, recorder: recorder)
            // A altura natural dos Ajustes passa da tela num notebook: a janela fica do tamanho
            // que cabe e o conteúdo rola. Pode ser esticada até a altura natural.
            let probe = NSHostingView(rootView: content)
            let natural = probe.fittingSize
            let host = NSHostingController(rootView: ScrollView { content }.background(Palette.paper))
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = "Ajustes da Lupa"
            window.styleMask = [.titled, .closable, .resizable]
            window.backgroundColor = Theme.paper100
            // Os Ajustes são desenhados em papel claro: com o Mac no modo escuro, campos e menus
            // nativos ficariam escuros (texto branco no fundo claro).
            window.appearance = NSAppearance(named: .aqua)
            let available = (NSScreen.main?.visibleFrame.height ?? 800) - 80
            window.setContentSize(NSSize(width: natural.width, height: min(natural.height, available)))
            window.contentMinSize = NSSize(width: natural.width, height: min(360, natural.height))
            window.contentMaxSize = NSSize(width: natural.width, height: natural.height)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        recorder.cancel()
    }
}

// Legenda e transcrição: a chave da OpenAI (no chaveiro), o idioma, o tamanho e quando ligar.
struct CaptionSettings: View {
    @ObservedObject var prefs: Preferences
    @State private var keyField = ""
    @State private var savedKey = OpenAIKey.masked
    @State private var status: KeyStatus = .idle

    enum KeyStatus: Equatable {
        case idle, checking, valid, invalid(String)
    }

    private var sizeIndex: Binding<Int> {
        Binding(
            get: { CaptionOptions.Size.allCases.firstIndex(of: prefs.captions.size) ?? 1 },
            set: { prefs.captions.size = CaptionOptions.Size.allCases[$0] }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LEGENDA E TRANSCRIÇÃO AO VIVO")
                .font(.lupaMono(11, .medium))
                .tracking(1.3)
                .foregroundColor(Palette.muted)
            HStack(spacing: 10) {
                SecureField(savedKey.map { "chave salva: \($0)" } ?? "Cole a chave da OpenAI (sk-…)", text: $keyField)
                    .textFieldStyle(.roundedBorder)
                    .font(.lupaMono(12))
                    .onSubmit(saveKey)
                Button("Salvar", action: saveKey)
                    .disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty)
                if savedKey != nil {
                    Button("Remover") {
                        OpenAIKey.save("")
                        savedKey = nil
                        status = .idle
                    }
                }
            }
            keyStatus
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Idioma da fala").font(.lupaText(12, .semibold)).foregroundColor(Palette.muted)
                    Picker("", selection: $prefs.captions.language) {
                        ForEach(CaptionLanguage.all) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tamanho da legenda").font(.lupaText(12, .semibold)).foregroundColor(Palette.muted)
                    Segmented(options: CaptionOptions.Size.allCases.map(\.label), selection: sizeIndex)
                }
            }
            HStack(spacing: 10) {
                Text("Termos").font(.lupaText(12, .semibold)).foregroundColor(Palette.muted)
                TextField("nomes e siglas que a transcrição deve acertar, separados por vírgula", text: $prefs.captions.vocabulary)
                    .textFieldStyle(.roundedBorder)
                    .font(.lupaText(12))
            }
            toggleRow("Ligar ao entrar no Ao vivo", "Vale também para a gravação. A qualquer momento, \(prefs.shortcuts[.captions]?.displayString ?? "o atalho") liga e desliga.", isOn: prefs.captions.onLive) {
                prefs.captions.onLive.toggle()
            }
            toggleRow("Salvar a transcrição", "Texto em Filmes › Lupa › Transcrições e, na gravação, legenda .srt ao lado do vídeo.", isOn: prefs.captions.saveTranscript) {
                prefs.captions.saveTranscript.toggle()
            }
        }
    }

    @ViewBuilder private var keyStatus: some View {
        switch status {
        case .idle:
            Text(savedKey == nil
                ? "A chave fica no chaveiro do Mac. A transcrição é cobrada na sua conta da OpenAI."
                : "Chave guardada no chaveiro do Mac.")
                .font(.lupaText(12)).foregroundColor(Palette.muted)
        case .checking:
            Text("conferindo a chave…").font(.lupaText(12)).foregroundColor(Palette.muted)
        case .valid:
            Text("chave salva e aceita pela OpenAI").font(.lupaText(12, .semibold)).foregroundColor(Palette.success)
        case let .invalid(reason):
            Text(reason).font(.lupaText(12, .semibold)).foregroundColor(Palette.danger)
        }
    }

    private func toggleRow(_ title: String, _ detail: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.lupaText(14, .semibold))
                Text(detail).font(.lupaText(12)).foregroundColor(Palette.muted)
            }
            Spacer()
            LimeToggle(isOn: isOn, action: action)
        }
    }

    private func saveKey() {
        let key = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard OpenAIKey.save(key) else {
            status = .invalid("não consegui guardar a chave no chaveiro")
            return
        }
        keyField = ""
        savedKey = OpenAIKey.masked
        status = .checking
        Task { @MainActor in
            status = await Self.check(key)
        }
    }

    // Uma chamada barata (lista de modelos) só para saber se a chave é aceita.
    private static func check(_ key: String) async -> KeyStatus {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return .valid
            case 401: return .invalid("a OpenAI recusou esta chave")
            default: return .invalid("a OpenAI respondeu \(code); a chave foi salva mesmo assim")
            }
        } catch {
            return .invalid("sem conexão para conferir; a chave foi salva")
        }
    }
}
