// Smart fan mode, as pure logic (no SMC access) so it can be tested with `make test`.

import Foundation

/// Temperature → fraction of the fan's range. Below `low` the fan idles at its minimum; above
/// `high` it runs at maximum. In between it eases in quadratically: quiet through everyday
/// temperatures, climbing steeply as the chip approaches `high`.
///   e.g. 60–90 °C: 65 °C → 3 %, 75 °C → 25 %, 85 °C → 69 %, 90 °C → 100 %
struct SmartCurve {
    var low: Double
    var high: Double

    func fraction(at temperature: Double) -> Double {
        let f = min(1, max(0, (temperature - low) / max(1, high - low)))
        return f * f
    }
}

/// Smooths raw sensor readings: follows a rise quickly (heat matters) and a fall slowly (no fan
/// hunting). Several missing readings in a row mean the sensors are gone, and the caller
/// should fail safe.
struct TemperatureFilter {
    private(set) var value: Double?
    private var misses = 0

    mutating func add(_ reading: Double?) -> Double? {
        guard let reading else {
            misses += 1
            if misses >= 3 { value = nil }
            return value
        }
        misses = 0
        if let current = value {
            let weight = reading > current ? 0.7 : 0.3
            value = current + (reading - current) * weight
        } else {
            value = reading
        }
        return value
    }
}

/// One fan's Smart-mode target. Ignores changes under `deadband` RPM (no audible stepping),
/// never lowers the speed by more than `maxDrop` per update, and always reaches the exact
/// minimum and maximum.
struct SmartFanTarget {
    let minRPM: Double
    let maxRPM: Double
    var deadband = 150.0
    var maxDrop = 300.0
    private(set) var last: Double?

    init(minRPM: Double, maxRPM: Double) {
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }

    /// `temperature == nil` (no sensors) fails safe to maximum.
    mutating func next(temperature: Double?, curve: SmartCurve) -> Double {
        guard let temperature else { last = maxRPM; return maxRPM }
        var rpm = (minRPM + (maxRPM - minRPM) * curve.fraction(at: temperature)).rounded()
        if let last {
            let atLimit = rpm == minRPM || rpm == maxRPM
            if abs(rpm - last) < deadband && !atLimit { rpm = last }
            if rpm < last { rpm = max(rpm, last - maxDrop) }
        }
        last = rpm
        return rpm
    }

    /// True once the fan is at the curve's target (no ramp still in progress).
    func settled(temperature: Double, curve: SmartCurve) -> Bool {
        guard let last else { return false }
        let ideal = (minRPM + (maxRPM - minRPM) * curve.fraction(at: temperature)).rounded()
        return abs(ideal - last) < deadband
    }

    mutating func reset() { last = nil }
}
