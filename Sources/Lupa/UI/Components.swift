import AppKit
import SwiftUI

/// SwiftUI mirrors of the `Theme` tokens.
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

/// A segmented control in the app's style; `onInk` switches to the dark-surface variant.
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

/// The lime on/off switch used across Settings and the recording panel.
struct LimeToggle: View {
    let label: LocalizedStringKey
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
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? String(localized: "on") : String(localized: "off"))
    }
}
