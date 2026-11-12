import AppKit
import Carbon.HIToolbox

/// Full-screen break countdown. ↑/↓ add or remove a minute, Space pauses, Esc leaves.
final class BreakTimerView: NSView {
    var onExit: (() -> Void)?

    private var total: TimeInterval
    private var remaining: TimeInterval
    private var paused = false
    private var finished = false
    private var lastTick = Date()
    private var ticker: Timer?

    init(frame: NSRect, duration: TimeInterval) {
        total = duration
        remaining = duration
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, ticker == nil else { return }
        lastTick = Date()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTick)
        lastTick = now
        guard !paused, !finished else { return }
        remaining = max(0, remaining - elapsed)
        if remaining == 0 {
            finished = true
            NSSound(named: "Glass")?.play()
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            onExit?()
        case kVK_UpArrow:
            remaining += 60
            total += 60
            finished = false
        case kVK_DownArrow:
            let cut = min(60, remaining)
            remaining -= cut
            total = max(60, total - cut)
        case kVK_Space:
            paused.toggle()
        default:
            return
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        onExit?()
    }

    private var clockText: String {
        let seconds = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var eyebrowText: String {
        if finished { return String(localized: "BREAK · OVER") }
        if paused { return String(localized: "BREAK · PAUSED") }
        return String(localized: "BREAK")
    }

    private var captionText: String {
        if finished { return String(localized: "time's up. everyone's waiting.") }
        if paused { return String(localized: "paused. space resumes.") }
        let back = Date().addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened)
        return String(localized: "back at \(back).")
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.ink900.setFill()
        bounds.fill()
        let scale = min(bounds.width / 1440, bounds.height / 900)

        let eyebrow = NSAttributedString(
            string: eyebrowText,
            attributes: [
                .font: Theme.mono(15 * scale, .medium),
                .foregroundColor: Theme.ink300,
                .kern: 15 * scale * 0.14,
            ])
        let clock = NSAttributedString(
            string: clockText,
            attributes: [
                .font: Theme.tabular(Theme.display(300 * scale, .semibold)),
                .foregroundColor: finished ? Theme.lime : Theme.paper100,
                .kern: -300 * scale * 0.04,
            ])
        let caption = NSAttributedString(
            string: captionText,
            attributes: [
                .font: Theme.text(24 * scale, .regular),
                .foregroundColor: Theme.ink200,
            ])

        let gap = 28 * scale
        let barSize = CGSize(width: 720 * scale, height: 10 * scale)
        let clockHeight = 300 * scale * 0.9
        let sizes = [eyebrow.size().height, clockHeight, barSize.height, caption.size().height]
        var top = bounds.midY + (sizes.reduce(0, +) + gap * 3) / 2

        drawCentered(eyebrow, top: top)
        top -= sizes[0] + gap
        let clockSize = clock.size()
        clock.draw(
            at: CGPoint(
                x: bounds.midX - clockSize.width / 2, y: top - clockHeight + (clockHeight - clockSize.height) / 2))
        top -= clockHeight + gap

        let track = NSRect(
            x: bounds.midX - barSize.width / 2, y: top - barSize.height, width: barSize.width, height: barSize.height)
        Theme.ink800.setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        let progress = total > 0 ? (1 - remaining / total).clamped(0, 1) : 1
        if progress > 0 {
            var fill = track
            fill.size.width = max(track.height, track.width * progress)
            Theme.lime.setFill()
            NSBezierPath(roundedRect: fill, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        }
        top -= barSize.height + gap
        drawCentered(caption, top: top)

        HUD.drawBar(
            [
                HUD.hint("↑↓", String(localized: "±1 min")),
                HUD.hint(String(localized: "space"), String(localized: "pause")),
                HUD.hint("esc", String(localized: "back to the presentation")),
            ],
            style: .primary,
            centerX: bounds.midX,
            bottom: 40 * scale,
            maxWidth: bounds.width - 32,
            alpha: 1
        )
    }

    private func drawCentered(_ string: NSAttributedString, top: CGFloat) {
        let size = string.size()
        string.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: top - size.height))
    }
}
