import Foundation

/// A damped harmonic oscillator used for every camera, zoom and cursor motion.
///
/// Unlike moving a fixed fraction of the distance per frame, a spring is frame-rate independent,
/// accelerates smoothly and settles on its own. `response` is roughly the settling time in
/// seconds; a `dampingRatio` of 1 is critically damped and never overshoots.
struct Spring {
    var value: Double
    var target: Double
    private(set) var velocity: Double = 0
    var response: Double
    var dampingRatio: Double

    init(value: Double, response: Double, dampingRatio: Double = 1) {
        self.value = value
        target = value
        self.response = response
        self.dampingRatio = dampingRatio
    }

    var isSettled: Bool { abs(target - value) < 0.0005 && abs(velocity) < 0.001 }

    /// Integrates in fixed sub-steps so a late frame cannot destabilise the simulation.
    mutating func step(_ dt: Double) {
        let omega = 2 * Double.pi / response
        let stiffness = omega * omega
        let damping = 2 * dampingRatio * omega
        var remaining = min(dt, 0.1)
        while remaining > 0 {
            let h = min(remaining, 1.0 / 480)
            let acceleration = stiffness * (target - value) - damping * velocity
            velocity += acceleration * h
            value += velocity * h
            remaining -= h
        }
        if isSettled {
            value = target
            velocity = 0
        }
    }

    /// Clamps the value to `range` and drops any velocity pushing it further out.
    mutating func confine(to range: ClosedRange<Double>) {
        if value < range.lowerBound {
            value = range.lowerBound
            velocity = max(velocity, 0)
        } else if value > range.upperBound {
            value = range.upperBound
            velocity = min(velocity, 0)
        }
    }

    /// Follows an externally computed value while keeping its velocity, so the spring can take
    /// over again without a jolt.
    mutating func drive(to newValue: Double, dt: Double) {
        velocity = dt > 0 ? (newValue - value) / dt : 0
        value = newValue
        target = newValue
    }

    mutating func snap(to newValue: Double) {
        value = newValue
        target = newValue
        velocity = 0
    }
}
