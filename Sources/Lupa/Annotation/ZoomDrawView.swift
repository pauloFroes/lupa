import AppKit
import Carbon.HIToolbox

/// Zoom and annotation over a frozen screenshot (or, in live drawing, over the live screen).
///
/// Zoom scales around the pointer, so the point under the mouse is always the real point on
/// screen. Entering drawing mode freezes the visible crop so strokes stay where they were drawn.
final class ZoomDrawView: NSView, NSTextInputClient {
    enum Mode {
        case zoom
        case draw
    }

    private enum Board {
        case screen
        case white
        case black
    }

    var onExit: (() -> Void)?

    /// No snapshot means live drawing: the view is transparent over a screen (or live zoom) that
    /// keeps moving, and strokes end up in the recording. No hints are drawn, since they would be
    /// recorded too.
    private let snapshot: NSImage?
    var isLive: Bool { snapshot == nil }
    private(set) var mode: Mode
    private var zoom: CGFloat = 1
    private var targetZoom: CGFloat
    private var anchor: CGPoint
    private var mouse: CGPoint
    private var frozenSource: CGRect?
    private var enteredFromZoom = false
    private var board: Board = .screen

    private var shapes: [Shape] = []
    private var current: Shape?
    private var dragStart: CGPoint = .zero
    private var heldFlags: NSEvent.ModifierFlags = []
    private var helpVisible = false
    /// Every edit pushes the previous state, so ⌘Z also undoes erasing and clearing.
    private var history: [[Shape]] = []
    private var eraser = false
    /// Tool picked with keys 1–5; sticky until changed. A held modifier still takes precedence.
    private var tool: Shape.Kind = .freehand
    private static let toolKeys: [String: Shape.Kind] = [
        "1": .freehand, "2": .line, "3": .rectangle, "4": .ellipse, "5": .arrow,
    ]
    private var erasingStroke = false
    private var erasedThisStroke = false
    private var lastErasePoint: CGPoint = .zero
    private static let eraserRadius: CGFloat = 12
    private var penIndex: Int
    private var highlighter = false
    private var penWidth: CGFloat = 6
    private var draft: TextDraft?
    private var markedText = ""
    private var textSize: CGFloat = 40

    private var exporting = false
    private var hudUntil = Date.distantPast
    private var toast: String?
    private var toastUntil = Date.distantPast
    private var ticker: Timer?

    private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    init(frame: NSRect, snapshot: CGImage?, mode: Mode, initialZoom: CGFloat, penIndex: Int, mouse: CGPoint) {
        self.snapshot = snapshot.map { NSImage(cgImage: $0, size: frame.size) }
        self.mode = mode
        targetZoom = mode == .zoom ? initialZoom : 1
        anchor = mouse
        self.mouse = mouse
        self.penIndex = penIndex
        super.init(frame: frame)
        if mode == .draw {
            frozenSource = bounds
            helpVisible = self.snapshot != nil
        }
        showHUD(full: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { snapshot != nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, ticker == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        updateCursor()
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        NSCursor.arrow.set()
    }

    func switchToDraw() {
        guard mode == .zoom else { return }
        enterDraw(fromZoom: true)
    }

    // MARK: - State

    private var effectiveWidth: CGFloat { highlighter ? penWidth * 3 : penWidth }

    private func sourceRect() -> CGRect {
        if let frozenSource { return frozenSource }
        let scale = max(zoom, 1)
        return CGRect(
            x: anchor.x * (1 - 1 / scale),
            y: anchor.y * (1 - 1 / scale),
            width: bounds.width / scale,
            height: bounds.height / scale
        )
    }

    private func enterDraw(fromZoom: Bool) {
        frozenSource = sourceRect()
        mode = .draw
        enteredFromZoom = fromZoom
        helpVisible = !isLive
        updateCursor()
        showHUD(full: true)
    }

    private func returnToZoom() {
        commitText()
        shapes.removeAll()
        history.removeAll()
        current = nil
        eraser = false
        board = .screen
        frozenSource = nil
        mode = .zoom
        enteredFromZoom = false
        helpVisible = false
        anchor = mouse
        updateCursor()
        showHUD(full: true)
    }

    private func updateCursor() {
        window?.invalidateCursorRects(for: self)
        (mode == .draw ? Self.blankCursor : NSCursor.arrow).set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .draw ? Self.blankCursor : .arrow)
    }

    private func tick() {
        var dirty = false
        if frozenSource == nil, abs(zoom - targetZoom) > 0.001 {
            zoom += (targetZoom - zoom) * 0.22
            if abs(zoom - targetZoom) < 0.002 { zoom = targetZoom }
            dirty = true
        }
        let now = Date()
        if now < hudUntil.addingTimeInterval(0.4) || now < toastUntil.addingTimeInterval(0.4) { dirty = true }
        if dirty { needsDisplay = true }
    }

    private func showHUD(full: Bool) {
        hudUntil = Date().addingTimeInterval(full ? 4 : 1.6)
        needsDisplay = true
    }

    private func flash(_ message: String) {
        toast = message
        toastUntil = Date().addingTimeInterval(1.8)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        switch board {
        case .screen:
            if let snapshot {
                NSGraphicsContext.current?.imageInterpolation = .high
                snapshot.draw(in: bounds, from: sourceRect(), operation: .copy, fraction: 1)
            } else {
                NSColor.clear.set()
                dirtyRect.fill(using: .copy)
            }
        case .white:
            Theme.paper50.setFill()
            bounds.fill()
        case .black:
            Theme.ink900.setFill()
            bounds.fill()
        }
        for shape in shapes { shape.draw() }
        current?.draw()
        draft?.draw(marked: markedText, caret: !exporting)
        guard !exporting else { return }
        if mode == .draw, draft == nil {
            if showsEraser { drawEraserCursor() } else { drawPenCursor() }
        }
        drawHUD()
    }

    private func drawPenCursor() {
        let pen = Pens.all[penIndex]
        let diameter = max(effectiveWidth, 6)
        let path = NSBezierPath(
            ovalIn: NSRect(
                x: mouse.x - diameter / 2,
                y: mouse.y - diameter / 2,
                width: diameter,
                height: diameter
            ))
        (highlighter ? pen.color.withAlphaComponent(0.45) : pen.color).setFill()
        path.fill()
        Theme.paper50.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private var showsEraser: Bool {
        erasingStroke || (current == nil && (eraser || Self.isQuickErase(heldFlags)))
    }

    private static func isQuickErase(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.option) && flags.contains(.command)
    }

    private func drawEraserCursor() {
        let r = Self.eraserRadius
        let path = NSBezierPath(ovalIn: NSRect(x: mouse.x - r, y: mouse.y - r, width: r * 2, height: r * 2))
        Theme.paper50.withAlphaComponent(0.35).setFill()
        path.fill()
        path.lineWidth = 2
        Theme.ink900.setStroke()
        path.stroke()
        path.lineWidth = 1
        Theme.paper50.setStroke()
        path.stroke()
    }

    private func drawHUD() {
        guard !isLive else { return }
        let maxWidth = bounds.width - 32
        let alpha = HUD.fadeAlpha(until: hudUntil)
        switch mode {
        case .zoom:
            HUD.drawBar(
                zoomSegments(), style: .primary, centerX: bounds.midX, bottom: 40, maxWidth: maxWidth, alpha: alpha)
        case .draw:
            var bottom: CGFloat = 32
            if helpVisible {
                for row in helpRows().reversed() {
                    bottom +=
                        HUD.drawBar(
                            row, style: .secondary, centerX: bounds.midX, bottom: bottom, maxWidth: maxWidth, alpha: 1)
                        + 6
                }
                bottom += 4
            }
            HUD.drawBar(
                drawSegments(), style: .primary, centerX: bounds.midX, bottom: bottom, maxWidth: maxWidth,
                alpha: helpVisible ? 1 : alpha)
        }
        let toastAlpha = HUD.fadeAlpha(until: toastUntil)
        if toastAlpha > 0, let toast {
            HUD.drawBar(
                [.badge(toast)], style: .primary, centerX: bounds.midX, bottom: bounds.height - 92, maxWidth: maxWidth,
                alpha: toastAlpha)
        }
    }

    private func zoomSegments() -> [HUDSegment] {
        [
            .badge(targetZoom.zoomLabel),
            HUD.hint(String(localized: "scroll, pinch or ↑↓"), String(localized: "zoom")),
            HUD.hint(String(localized: "click"), String(localized: "draw")),
            HUD.hint("esc", String(localized: "exit")),
        ]
    }

    private func drawSegments() -> [HUDSegment] {
        let pen = Pens.all[penIndex]
        var segments: [HUDSegment] = [
            .swatches(selected: penIndex, highlighter: highlighter),
            .separator,
            .penWidth(pen.color, "\(Int(effectiveWidth.rounded())) px"),
            .separator,
            .tool(toolName()),
        ]
        if !helpVisible { segments.append(HUD.hint("H", String(localized: "shortcuts"))) }
        return segments
    }

    /// Follows the held modifier, so the shape can be checked before dragging.
    private func toolName() -> String {
        if draft != nil { return String(localized: "text") }
        if showsEraser { return String(localized: "eraser") }
        switch current?.kind ?? kind(for: heldFlags) {
        case .line: return String(localized: "line")
        case .rectangle: return String(localized: "rectangle")
        case .ellipse: return String(localized: "ellipse")
        case .arrow: return String(localized: "arrow")
        case .freehand, .text: return highlighter ? String(localized: "highlighter") : String(localized: "pen")
        }
    }

    /// One row per kind of element: shapes, text and color, board and file.
    private func helpRows() -> [[HUDSegment]] {
        var board: [HUDSegment] = [
            .group(String(localized: "board")),
            HUD.hint("W", String(localized: "white")),
            HUD.hint("K", String(localized: "black")),
            HUD.hint("X", String(localized: "eraser")),
            HUD.hint(String(localized: "⌥⌘ click"), String(localized: "erase one")),
            HUD.hint("E", String(localized: "erase all")),
            HUD.hint("⌘Z", String(localized: "undo")),
            HUD.hint("⌘C", String(localized: "copy")),
            HUD.hint("⌘S", String(localized: "save")),
        ]
        if enteredFromZoom { board.append(HUD.hint(String(localized: "right-click"), String(localized: "zoom"))) }
        board.append(HUD.hint("H", String(localized: "hide")))
        board.append(HUD.hint("esc", String(localized: "exit")))
        return [
            [
                .group(String(localized: "shapes")),
                HUD.hint("1", String(localized: "pen")),
                HUD.hint("2", String(localized: "line")),
                HUD.hint("3", String(localized: "rectangle")),
                HUD.hint("4", String(localized: "ellipse")),
                HUD.hint("5", String(localized: "arrow")),
                .hint([(String(localized: "or hold ⇧ ⌃ ⌥ ⌃⇧ while dragging"), false)]),
            ],
            [
                .group(String(localized: "text and color")),
                HUD.hint("T", String(localized: "type at pointer")),
                HUD.hint("R G B O Y P", String(localized: "color")),
                HUD.hint(String(localized: "⇧+color"), String(localized: "highlighter")),
                HUD.hint(String(localized: "scroll or pinch"), String(localized: "width")),
            ],
            board,
        ]
    }

    // MARK: - Mouse

    private func point(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = point(event)
        if mode == .zoom { anchor = mouse }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let location = point(event)
        mouse = location
        if mode == .zoom { enterDraw(fromZoom: true) }
        commitText()
        helpVisible = false
        dragStart = location
        heldFlags = Self.shapeFlags(event.modifierFlags)
        if eraser || Self.isQuickErase(heldFlags) {
            erasingStroke = true
            erasedThisStroke = false
            lastErasePoint = location
            erase(along: location)
            needsDisplay = true
            return
        }
        current = Shape(
            kind: kind(for: heldFlags),
            points: [location],
            color: Pens.all[penIndex].color,
            width: effectiveWidth,
            highlighter: highlighter
        )
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        mouse = point(event)
        if erasingStroke {
            erase(along: mouse)
            needsDisplay = true
            return
        }
        updateCurrentShape(flags: event.modifierFlags)
    }

    /// Samples the path between two drag events so a fast swipe does not skip thin items.
    private func erase(along target: CGPoint) {
        let distance = hypot(target.x - lastErasePoint.x, target.y - lastErasePoint.y)
        let steps = max(1, Int(distance / 4))
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let sample = CGPoint(
                x: lastErasePoint.x + (target.x - lastErasePoint.x) * t,
                y: lastErasePoint.y + (target.y - lastErasePoint.y) * t
            )
            guard shapes.contains(where: { $0.hit(sample, radius: Self.eraserRadius) }) else { continue }
            if !erasedThisStroke {
                checkpoint()
                erasedThisStroke = true
            }
            shapes.removeAll { $0.hit(sample, radius: Self.eraserRadius) }
        }
        lastErasePoint = target
    }

    override func rightMouseDragged(with event: NSEvent) {
        if current != nil || erasingStroke { mouseDragged(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if current != nil || erasingStroke { mouseUp(with: event) }
    }

    private func kind(for flags: NSEvent.ModifierFlags) -> Shape.Kind {
        let held = Shape.kind(for: flags)
        return held == .freehand ? tool : held
    }

    private func checkpoint() {
        history.append(shapes)
        if history.count > 200 { history.removeFirst() }
    }

    override func flagsChanged(with event: NSEvent) {
        if current != nil {
            updateCurrentShape(flags: event.modifierFlags)
            return
        }
        heldFlags = Self.shapeFlags(event.modifierFlags)
        if mode == .draw, draft == nil { showHUD(full: false) }
    }

    private static func shapeFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.shift, .control, .option, .command])
    }

    /// Releasing the modifier before the mouse button is the natural gesture; if that changed the
    /// shape, every rectangle would turn into a stroke at the end of the drag. Only pressing a
    /// modifier changes the shape mid-drag.
    private func updateCurrentShape(flags: NSEvent.ModifierFlags) {
        guard var shape = current else { return }
        let held = Self.shapeFlags(flags)
        let pressed = !held.subtracting(heldFlags).isEmpty
        heldFlags = held
        let kind = pressed ? Shape.kind(for: held) : shape.kind
        if kind == .freehand {
            if shape.kind != .freehand { shape.points = [dragStart] }
            shape.points.append(mouse)
        } else {
            shape.points = [dragStart, mouse]
        }
        shape.kind = kind
        current = shape
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        erasingStroke = false
        if let shape = current {
            checkpoint()
            shapes.append(shape)
        }
        current = nil
        heldFlags = Self.shapeFlags(event.modifierFlags)
        needsDisplay = true
    }

    /// macOS may deliver ⌃-click as a right click. While drawing it means "rectangle", not "exit".
    override func rightMouseDown(with event: NSEvent) {
        if mode == .draw, event.modifierFlags.contains(.control) {
            mouseDown(with: event)
            return
        }
        if mode == .draw, enteredFromZoom {
            returnToZoom()
        } else {
            onExit?()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let raw = event.scrollingDeltaY
        guard raw != 0 else { return }
        let step = event.hasPreciseScrollingDeltas ? raw / 30 : raw
        switch mode {
        case .zoom:
            targetZoom = (targetZoom * pow(1.15, step)).clamped(1, 16)
            showHUD(full: false)
        case .draw:
            if draft != nil {
                textSize = (textSize + step * 4).clamped(12, 220)
                draft?.fontSize = textSize
            } else {
                penWidth = (penWidth + step * 2).clamped(1, 60)
                showHUD(full: false)
            }
        }
        needsDisplay = true
    }

    /// Pinch zooms in zoom mode and changes the stroke width in drawing mode, like scrolling.
    override func magnify(with event: NSEvent) {
        switch mode {
        case .zoom:
            targetZoom = (targetZoom * (1 + event.magnification)).clamped(1, 16)
        case .draw:
            guard draft == nil else { return }
            penWidth = (penWidth * (1 + event.magnification)).clamped(1, 60)
        }
        showHUD(full: false)
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if draft != nil, !flags.contains(.command) {
            interpretKeyEvents([event])
            return
        }
        if Int(event.keyCode) == kVK_Escape {
            onExit?()
            return
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.contains(.command) {
            handleCommand(key)
            return
        }
        switch mode {
        case .zoom: handleZoomKey(event)
        case .draw: handleDrawKey(key, shift: flags.contains(.shift))
        }
    }

    private func handleCommand(_ key: String) {
        switch key {
        case "z":
            if draft != nil {
                draft = nil
                markedText = ""
            } else if let previous = history.popLast() {
                shapes = previous
            }
        case "c" where !isLive: copyImage()
        case "s" where !isLive: saveImage()
        default: return
        }
        needsDisplay = true
    }

    private func handleZoomKey(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_UpArrow, kVK_ANSI_Equal, kVK_ANSI_KeypadPlus: targetZoom = (targetZoom * 1.25).clamped(1, 16)
        case kVK_DownArrow, kVK_ANSI_Minus, kVK_ANSI_KeypadMinus: targetZoom = (targetZoom / 1.25).clamped(1, 16)
        default: return
        }
        showHUD(full: false)
    }

    private func handleDrawKey(_ key: String, shift: Bool) {
        if let index = Pens.index(forKey: key) {
            penIndex = index
            highlighter = shift
            eraser = false
            showHUD(full: false)
            return
        }
        switch key {
        case "e":
            if !shapes.isEmpty {
                checkpoint()
                shapes.removeAll()
            }
        case "x":
            eraser.toggle()
            showHUD(full: false)
        case "1", "2", "3", "4", "5":
            tool = Self.toolKeys[key] ?? .freehand
            eraser = false
            showHUD(full: false)
        case "w": board = board == .white ? .screen : .white
        case "k": board = board == .black ? .screen : .black
        case "t": startText()
        case "h" where !isLive: helpVisible.toggle()
        default: return
        }
        needsDisplay = true
    }

    private func startText() {
        commitText()
        eraser = false
        draft = TextDraft(origin: mouse, text: "", fontSize: textSize, color: Pens.all[penIndex].color)
        showHUD(full: false)
    }

    private func commitText() {
        guard let finished = draft else { return }
        draft = nil
        markedText = ""
        inputContext?.discardMarkedText()
        if !finished.text.isEmpty {
            checkpoint()
            shapes.append(Shape(text: finished))
        }
        needsDisplay = true
    }

    // MARK: - NSTextInputClient

    // Going through the input system makes dead keys and IMEs work (é, ã, ü, かな…).

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        draft?.text += text
        needsDisplay = true
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            draft?.text += "\n"
        case #selector(NSResponder.deleteBackward(_:)):
            if draft?.text.isEmpty == false { draft?.text.removeLast() }
        case #selector(NSResponder.cancelOperation(_:)):
            commitText()
        default:
            break
        }
        needsDisplay = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        needsDisplay = true
    }

    func unmarkText() {
        markedText = ""
    }

    func selectedRange() -> NSRange {
        NSRange(location: draft?.text.utf16.count ?? 0, length: 0)
    }

    func markedRange() -> NSRange {
        guard !markedText.isEmpty else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: draft?.text.utf16.count ?? 0, length: markedText.utf16.count)
    }

    func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let origin = draft?.origin ?? mouse
        guard let window else { return .zero }
        return window.convertToScreen(convert(NSRect(origin: origin, size: .zero), to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    // MARK: - Copy and save

    private func renderPNG() -> Data? {
        exporting = true
        defer {
            exporting = false
            needsDisplay = true
        }
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func copyImage() {
        guard let png = renderPNG() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        flash(String(localized: "copied"))
    }

    private func saveImage() {
        guard let png = renderPNG() else { return }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let url = desktop.appendingPathComponent(FileNames.timestamped("png"))
        do {
            try png.write(to: url)
            flash(String(localized: "saved to Desktop"))
        } catch {
            Log.recording.error(
                "Saving \(url.path, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
            flash(String(localized: "could not save"))
        }
    }
}
