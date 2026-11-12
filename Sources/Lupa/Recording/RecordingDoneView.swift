import AppKit
import SwiftUI

/// Shown in the top-right corner after a recording is saved; closes itself after 30 s.
struct RecordingDoneView: View {
    let fileName: String
    let folder: String
    let duration: String
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("done. \(duration) recorded.")
                    .font(Font(Theme.display(20, .semibold) as CTFont))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(Palette.onInkMuted)
                .accessibilityLabel("Close")
            }
            Text("saved to \(folder)")
                .font(.lupaText(13))
                .foregroundColor(Palette.onInkMuted)
            Text(fileName)
                .font(.lupaMono(12))
                .foregroundColor(Palette.onInkText)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 10) {
                Button("Show in Finder", action: onReveal).buttonStyle(GhostOnInkStyle())
                Button("Open", action: onOpen).buttonStyle(PrimaryOnInkStyle())
            }
        }
        .padding(20)
        .frame(width: 380)
        .foregroundColor(Palette.paper)
        .background(RoundedRectangle(cornerRadius: 18).fill(Palette.ink))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.inkBorder, lineWidth: 1))
    }
}
