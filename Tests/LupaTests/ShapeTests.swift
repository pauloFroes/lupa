import AppKit
import Testing

@testable import Lupa

struct ShapeTests {
    @Test(arguments: [
        (NSEvent.ModifierFlags(), Shape.Kind.freehand),
        ([.shift], .line),
        ([.control], .rectangle),
        ([.command], .rectangle),
        ([.option], .ellipse),
        ([.control, .shift], .arrow),
        ([.command, .shift], .arrow),
    ])
    func modifierSelectsKind(flags: NSEvent.ModifierFlags, kind: Shape.Kind) {
        #expect(Shape.kind(for: flags) == kind)
    }

    @Test func lineHitTestsNearTheSegmentOnly() {
        let line = Self.shape(.line, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], width: 4)
        #expect(line.hit(CGPoint(x: 50, y: 10), radius: 12))
        #expect(!line.hit(CGPoint(x: 50, y: 20), radius: 12))
        #expect(!line.hit(CGPoint(x: 130, y: 0), radius: 12))
    }

    @Test func rectangleHitTestsOutlineNotInterior() {
        let rect = Self.shape(.rectangle, [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 200)], width: 4)
        #expect(rect.hit(CGPoint(x: 0, y: 100), radius: 6))
        #expect(!rect.hit(CGPoint(x: 100, y: 100), radius: 6))
    }

    @Test func ellipseHitTestsOutline() {
        let ellipse = Self.shape(.ellipse, [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 100)], width: 2)
        #expect(ellipse.hit(CGPoint(x: 100, y: 100), radius: 4))
        #expect(!ellipse.hit(CGPoint(x: 100, y: 50), radius: 4))
    }

    @Test func singlePointStrokeIsADot() {
        let dot = Self.shape(.freehand, [CGPoint(x: 10, y: 10)], width: 10)
        #expect(dot.hit(CGPoint(x: 14, y: 10), radius: 0))
        #expect(!dot.hit(CGPoint(x: 30, y: 10), radius: 0))
    }

    private static func shape(_ kind: Shape.Kind, _ points: [CGPoint], width: CGFloat) -> Shape {
        Shape(kind: kind, points: points, color: .red, width: width, highlighter: false)
    }
}
