import AppKit

/// The always-visible "LIVE" badge with the zoom level, plus a hint bar that shows up on entry and
/// on every zoom change, then fades out.
final class LiveHUDView: NSView {
    private var zoom: CGFloat = 2
    private var hintsUntil = Date.distantPast
    var note: String? {
        didSet { bar.needsDisplay = true }
    }
    // Two small views: one transparent screen-sized layer would cost a composite on every frame.
    private let badge = HUDPart()
    private let bar = HUDPart()

    override init(frame: NSRect) {
        super.init(frame: frame)
        badge.frame = NSRect(x: 0, y: frame.height - 100, width: 360, height: 100)
        bar.frame = NSRect(x: 0, y: 0, width: frame.width, height: 170)
        badge.onDraw = { [weak self] bounds in self?.drawBadge(in: bounds) }
        bar.onDraw = { [weak self] bounds in self?.drawHints(in: bounds) }
        addSubview(badge)
        addSubview(bar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(zoom: CGFloat) {
        self.zoom = zoom
        hintsUntil = Date().addingTimeInterval(3)
        bar.isHidden = false
        badge.needsDisplay = true
        bar.needsDisplay = true
    }

    func tick() {
        guard !bar.isHidden else { return }
        if Date() < hintsUntil.addingTimeInterval(0.4) {
            bar.needsDisplay = true
        } else {
            bar.isHidden = true
        }
    }

    private var level: String { zoom.zoomLabel }

    private func drawBadge(in bounds: NSRect) {
        HUD.drawBadgeRow(
            label: String(localized: "LIVE"), value: level, origin: CGPoint(x: 24, y: bounds.height - 24 - 36))
    }

    private func drawHints(in bounds: NSRect) {
        HUD.drawBar(
            [
                .badge(level),
                HUD.hint(String(localized: "pinch"), String(localized: "zoom")),
                HUD.hint(String(localized: "⌃ scroll"), String(localized: "zoom")),
                HUD.hint("⌃+  ⌃-", String(localized: "zoom")),
                HUD.hint("⌃0", String(localized: "reset")),
                HUD.hint("esc", String(localized: "exit")),
            ],
            style: .primary,
            centerX: bounds.midX,
            bottom: 40,
            maxWidth: bounds.width - 32,
            alpha: HUD.fadeAlpha(until: hintsUntil)
        )
        if let note {
            HUD.drawBar(
                [.hint([(note, false)])],
                style: .secondary,
                centerX: bounds.midX,
                bottom: 104,
                maxWidth: bounds.width - 32,
                alpha: HUD.fadeAlpha(until: hintsUntil)
            )
        }
    }
}

private final class HUDPart: NSView {
    var onDraw: ((NSRect) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        onDraw?(bounds)
    }
}
