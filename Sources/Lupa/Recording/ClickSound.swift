import Foundation

/// A synthesized mouse click, like the ones screencast tools add in post. Generated once per
/// sample rate and cached, so there is no audio asset to ship.
enum ClickSound {
    private static var cache: [Double: [Float]] = [:]
    private static let lock = NSLock()

    static func samples(rate: Double) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[rate] { return cached }
        let made = make(rate: rate)
        cache[rate] = made
        return made
    }

    /// A short "tick": a high snap, a mid body and a low thump, with a burst of noise on the attack.
    private static func make(rate: Double) -> [Float] {
        let count = Int(rate * 0.05)
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { index in
            let t = Double(index) / rate
            let attack = min(1, t / 0.0004)
            let snap = sin(2 * .pi * 3400 * t) * exp(-t / 0.0025)
            let body = sin(2 * .pi * 1250 * t) * exp(-t / 0.006)
            let thump = sin(2 * .pi * 190 * t) * exp(-t / 0.012)
            let noise = Double.random(in: -1...1, using: &generator) * exp(-t / 0.0012)
            return Float(attack * (0.32 * snap + 0.26 * body + 0.18 * thump + 0.22 * noise))
        }
    }
}
