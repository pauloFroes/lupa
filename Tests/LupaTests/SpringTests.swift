import Testing

@testable import Lupa

struct SpringTests {
    @Test func settlesOnTarget() {
        var spring = Spring(value: 0, response: 0.4)
        spring.target = 10
        for _ in 0..<240 { spring.step(1.0 / 60) }
        #expect(spring.isSettled)
        #expect(spring.value == 10)
        #expect(spring.velocity == 0)
    }

    @Test func criticallyDampedNeverOvershoots() {
        var spring = Spring(value: 0, response: 0.4, dampingRatio: 1)
        spring.target = 1
        for _ in 0..<240 {
            spring.step(1.0 / 120)
            #expect(spring.value <= 1)
        }
    }

    @Test func largeTimeStepStaysStable() {
        var spring = Spring(value: 0, response: 0.2)
        spring.target = 1
        spring.step(5)  // A stalled frame: clamped to 0.1 s and sub-stepped.
        #expect(spring.value.isFinite)
        #expect(spring.value > 0 && spring.value <= 1)
    }

    @Test func confineClampsAndDropsOutwardVelocity() {
        var spring = Spring(value: 0, response: 0.4)
        spring.drive(to: 5, dt: 0.1)
        #expect(spring.velocity == 50)
        spring.confine(to: 0...2)
        #expect(spring.value == 2)
        #expect(spring.velocity == 0)
    }

    @Test func snapResetsMotion() {
        var spring = Spring(value: 0, response: 0.4)
        spring.drive(to: 3, dt: 0.1)
        spring.snap(to: 7)
        #expect(spring.value == 7 && spring.target == 7 && spring.velocity == 0)
    }
}
