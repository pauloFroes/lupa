import Foundation

// Mola amortecida, o movimento das câmeras do Screen Studio: em vez de andar uma fração fixa
// por quadro (que depende da taxa da tela e para de forma seca), acelera e assenta sozinha.
// `response` é o tempo de assentamento aproximado; `dampingRatio` 1 assenta sem passar do alvo.
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

    // Subpassos fixos deixam a integração estável mesmo quando um quadro atrasa.
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

    mutating func snap(to newValue: Double) {
        value = newValue
        target = newValue
        velocity = 0
    }
}
