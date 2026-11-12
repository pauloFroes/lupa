import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var recorder: ShortcutRecorder
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var permission = ScreenCapture.hasPermission
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("GLOBAL SHORTCUTS") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    ForEach(Action.allCases) { action in
                        shortcutRow(action)
                    }
                }
                Text("Click a shortcut and press the new combination. Esc cancels.")
                    .font(.lupaText(12))
                    .foregroundColor(Palette.muted)
            }
            section("INITIAL ZOOM") {
                Segmented(options: Preferences.zoomLabels, selection: $prefs.zoomIndex)
            }
            section("INITIAL PEN COLOR") {
                HStack(spacing: 10) {
                    ForEach(Pens.all.indices, id: \.self) { index in
                        swatch(index)
                    }
                    Text(verbatim: "\(Pens.all[prefs.pen].name) (\(Pens.all[prefs.pen].key))")
                        .font(.lupaText(13))
                        .foregroundColor(Palette.muted)
                        .padding(.leading, 6)
                }
            }
            HStack(alignment: .top, spacing: 24) {
                section("LIVE ZOOM CURSOR") {
                    Segmented(options: Preferences.cursorSizeLabels, selection: $prefs.cursorSizeIndex)
                }
                section("CURSOR SMOOTHING") {
                    Segmented(options: Preferences.cursorSmoothingLabels, selection: $prefs.cursorSmoothingIndex)
                }
            }
            section("DEFAULT BREAK") {
                Segmented(options: Preferences.breakMinutes.map { "\($0) min" }, selection: $prefs.breakIndex)
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at login").font(.lupaText(14, .semibold))
                    Text("Lupa lives in the menu bar, with no Dock icon.")
                        .font(.lupaText(12))
                        .foregroundColor(Palette.muted)
                }
                Spacer()
                LimeToggle(label: "Open at login", isOn: loginEnabled) {
                    LoginItem.set(!loginEnabled)
                    loginEnabled = LoginItem.isEnabled
                }
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screen Recording").font(.lupaText(14, .semibold))
                    PermissionPill(granted: permission)
                }
                Spacer()
                Button("Open System Settings") { ScreenCapture.openPrivacySettings() }
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

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
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
                Text(
                    verbatim: isRecording
                        ? String(localized: "press keys…") : (prefs.shortcuts[action]?.displayString ?? "—")
                )
                .font(.lupaMono(13))
                .frame(minWidth: 52)
                .padding(.horizontal, 10)
                .frame(height: 32)
            }
            .buttonStyle(KeyCapStyle(active: isRecording))
            .accessibilityLabel("Change shortcut for \(action.title)")
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
                .overlay(
                    Circle().stroke(selected ? Palette.paper : Palette.ink.opacity(0.2), lineWidth: selected ? 3 : 1)
                )
                .overlay(Circle().stroke(selected ? Palette.ink : .clear, lineWidth: 2).padding(-2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pen.name)
        .help(Text(verbatim: "\(pen.name) (\(pen.key))"))
    }
}

private struct KeyCapStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(active ? Palette.inkDeep : Palette.ink)
            .background(RoundedRectangle(cornerRadius: 8).fill(active ? Palette.lime : Palette.paper))
            .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(
                    active ? Palette.ink : Palette.borderStrong, lineWidth: active ? 2 : 1)
            )
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

private struct PermissionPill: View {
    let granted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(granted ? Palette.success : Palette.danger)
                .frame(width: 6, height: 6)
            Text(granted ? String(localized: "allowed") : String(localized: "not allowed"))
                .font(.lupaText(12, .semibold))
        }
        .foregroundColor(granted ? Palette.success : Palette.danger)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(granted ? Palette.successSoft : Palette.dangerSoft))
    }
}
