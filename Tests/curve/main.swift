// `make test`: checks Smart fan mode's curve, smoothing and ramping without root or a real fan.

import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { failures += 1; print("FAIL (line \(line)): \(message)") }
}

let curve = SmartCurve(low: 60, high: 90)

// Curve endpoints and shape
check(curve.fraction(at: 40) == 0, "below low is the minimum")
check(curve.fraction(at: 60) == 0, "at low is the minimum")
check(curve.fraction(at: 90) == 1, "at high is the maximum")
check(curve.fraction(at: 110) == 1, "above high is the maximum")
check(abs(curve.fraction(at: 75) - 0.25) < 1e-9, "midpoint is eased (25 %), not linear (50 %)")
var previous = -1.0
for t in stride(from: 50.0, through: 100.0, by: 0.5) {
    check(curve.fraction(at: t) >= previous, "curve is monotonic at \(t)")
    previous = curve.fraction(at: t)
}
check(SmartCurve(low: 80, high: 80).fraction(at: 85) == 1, "degenerate range does not divide by zero")

// Fan targets
var fan = SmartFanTarget(minRPM: 1199, maxRPM: 7199)
check(fan.next(temperature: 50, curve: curve) == 1199, "cool chip idles at minimum")
check(fan.next(temperature: 90, curve: curve) == 7199, "hot chip jumps straight to maximum (no ramp up limit)")
check(fan.next(temperature: 50, curve: curve) == 6899, "cooling ramps down by at most 300 RPM")
for _ in 0..<30 { _ = fan.next(temperature: 50, curve: curve) }
check(fan.last == 1199, "ramp down eventually reaches the exact minimum")

fan.reset()
_ = fan.next(temperature: 89.8, curve: curve)          // within the deadband of the maximum
check(fan.next(temperature: 90, curve: curve) == 7199, "reaches the exact maximum despite the deadband")

fan.reset()
let a = fan.next(temperature: 75, curve: curve)
check(fan.next(temperature: 75.4, curve: curve) == a, "small temperature jitter does not change the speed")

check(fan.next(temperature: nil, curve: curve) == 7199, "missing sensors fail safe to maximum")

// Settled detection (drives the 3 s / 6 s check interval)
fan.reset()
_ = fan.next(temperature: 90, curve: curve)
_ = fan.next(temperature: 60, curve: curve)
check(!fan.settled(temperature: 60, curve: curve), "still ramping down is not settled")
for _ in 0..<30 { _ = fan.next(temperature: 60, curve: curve) }
check(fan.settled(temperature: 60, curve: curve), "at target is settled")

// Temperature filter
var filter = TemperatureFilter()
check(filter.add(60) == 60, "first reading is taken as is")
check(filter.add(80)! > 70, "rises are followed quickly")
var cooling = TemperatureFilter()
_ = cooling.add(80)
check(cooling.add(60)! > 70, "falls are followed slowly")
check(cooling.add(nil) != nil && cooling.add(nil) != nil, "two missed readings keep the last value")
check(cooling.add(nil) == nil, "three missed readings report no temperature (fail safe)")

// Print the curve so a human can sanity-check it
print("Smart curve 60–90 °C on a 1199–7199 RPM fan:")
for t in [50.0, 60, 65, 70, 75, 80, 85, 90, 95] {
    var f = SmartFanTarget(minRPM: 1199, maxRPM: 7199)
    print(String(format: "  %3.0f °C → %4.0f RPM", t, f.next(temperature: t, curve: curve)))
}
print(failures == 0 ? "All tests passed." : "\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
