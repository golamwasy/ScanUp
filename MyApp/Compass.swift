import Foundation

/// Angle maths for the compass radar. Angles are degrees, clockwise from north.
enum Compass {
    static func normalized(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    /// The shortest signed turn from one direction to another, between -180 and 180.
    static func shortestTurn(from: Double, to: Double) -> Double {
        let turn = normalized(to - from)
        return turn > 180 ? turn - 360 : turn
    }

    /// Moves `current` towards `target` by `factor` (0 to 1), the short way round. `current` may go past 360 or
    /// below 0, so a dial that crosses north keeps turning smoothly instead of spinning back.
    static func smoothed(current: Double, toward target: Double, factor: Double) -> Double {
        current + shortestTurn(from: current, to: target) * factor
    }

    /// Where something in compass direction `bearing` appears to a viewer facing `heading`: 0 is straight ahead and
    /// 90 is to the right. Not wrapped, so it can be animated without a spin.
    static func relative(bearing: Double, heading: Double?) -> Double {
        bearing - (heading ?? 0)
    }
}
