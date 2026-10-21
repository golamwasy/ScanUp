import Foundation

/// One aircraft as the backend describes it (see the backend's API_CONTRACT.md).
struct Aircraft: Decodable, Identifiable, Equatable {
    let id: String
    let callsign: String?
    /// The number as on a ticket, when the server knows it.
    let flightNumber: String?
    let airline: String?
    let origin: String?
    let originCode: String?
    let destination: String?
    let destinationCode: String?
    let type: String?
    let registration: String?
    let altitudeFt: Int?
    let speedKt: Int?
    let headingDeg: Int?
    let verticalRateFpm: Int?
    let distanceM: Int
    let bearingDeg: Int
    let elevationDeg: Int?
    /// "landing" or "taking_off", decided by the backend from the airport nearby. Absent otherwise.
    let phase: String?
    let onGround: Bool
    /// When the flight left and is due, in a search answer. Absent in the nearby list and when the server has none.
    @Lenient var schedule: ScheduledFlight?
}

struct NearbyResponse: Decodable {
    let aircraft: [Aircraft]
    /// Seconds the backend asks the app to wait before the next refresh.
    let refreshAfterS: Int?
}

enum VerticalTrend {
    case climbing, descending, level

    var label: String {
        switch self {
        case .climbing: String(localized: "Climbing")
        case .descending: String(localized: "Descending")
        case .level: String(localized: "Level")
        }
    }

    var symbol: String {
        switch self {
        case .climbing: "arrow.up.right"
        case .descending: "arrow.down.right"
        case .level: "arrow.right"
        }
    }
}

/// What a low aircraft near an airport is doing.
enum FlightPhase {
    case landing, takingOff

    var label: String {
        switch self {
        case .landing: String(localized: "Landing")
        case .takingOff: String(localized: "Taking off")
        }
    }

    var symbol: String {
        switch self {
        case .landing: "airplane.arrival"
        case .takingOff: "airplane.departure"
        }
    }
}

extension Aircraft {
    /// An unknown value from a newer backend counts as no phase.
    var flightPhase: FlightPhase? {
        switch phase {
        case "landing": .landing
        case "taking_off": .takingOff
        default: nil
        }
    }

    /// The airline when known, otherwise the best identifier there is.
    var title: String {
        airline ?? callsign ?? registration ?? String(localized: "Unknown aircraft")
    }

    /// Second line of a collapsed card: the flight number and where it is going. The aircraft type is in the details.
    var subtitle: String {
        let route = originCode != nil && destinationCode != nil ? "\(originCode ?? "") → \(destinationCode ?? "")" : nil
        return [airline == nil ? nil : callsign, route ?? (airline == nil ? type : nil)].compactMap { $0 }.joined(separator: " · ")
    }

    /// Letters for the round badge, such as "SA" for Scandinavian Airlines.
    var initials: String {
        let source = airline ?? callsign ?? "?"
        let words = source.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(source.prefix(2))
        return String(letters).uppercased()
    }

    /// A stable number for the badge colour. Swift's own hashing changes on every launch.
    var colorSeed: Int {
        (airline ?? callsign ?? id).unicodeScalars.reduce(7) { ($0 &* 31) &+ Int($1.value) } & 0xFFFF
    }

    var trend: VerticalTrend? {
        guard !onGround, let rate = verticalRateFpm else { return nil }
        if rate > 300 { return .climbing }
        if rate < -300 { return .descending }
        return .level
    }

    var isMoving: Bool { (speedKt ?? 0) >= 3 }

    /// The altitude, never below zero. Barometric altitude reads below sea level on a day of high air pressure, which
    /// means nothing to a person looking up.
    var heightFt: Int? { altitudeFt.map { max(0, $0) } }

    /// Under 100 ft the pressure-based reading is too coarse to quote as a number.
    var isVeryLow: Bool { !onGround && (heightFt ?? .max) < 100 }

    var compass: String { Self.compassPoint(for: bearingDeg) }

    /// "NE · 22° up" for the collapsed card: which way to look and how high.
    var lookDirection: String {
        guard let elevationDeg else { return compass }
        return "\(compass) · \(elevationDeg)° up"
    }

    /// Where in the sky to look: low near the horizon, low, high, or almost overhead.
    var skyPosition: String? {
        guard let elevationDeg else { return nil }
        switch elevationDeg {
        case ..<10: return String(localized: "Low, near the horizon")
        case 10..<35: return String(localized: "Low in the sky")
        case 35..<65: return String(localized: "High in the sky")
        default: return String(localized: "Almost overhead")
        }
    }

    static func compassPoint(for degrees: Int) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return points[Int((Compass.normalized(Double(degrees)) / 45).rounded()) % 8]
    }

    var hasRoute: Bool { originCode != nil || destinationCode != nil }

    /// An aircraft is not moved on the radar for longer than this after its report.
    static let maxProjection: TimeInterval = 30

    /// Where the aircraft is some seconds after it was reported, seen from the phone's position at the time of the
    /// report. It flies on in a straight line at its reported speed and track, which keeps the radar moving between
    /// refreshes.
    func projected(after seconds: TimeInterval) -> (distance: Double, bearing: Double) {
        guard seconds > 0, let speedKt, speedKt > 0, let headingDeg else {
            return (Double(distanceM), Double(bearingDeg))
        }
        let travelled = Double(speedKt) * 0.514444 * min(seconds, Self.maxProjection)
        let bearing = Double(bearingDeg) * .pi / 180
        let track = Double(headingDeg) * .pi / 180
        let east = Double(distanceM) * sin(bearing) + travelled * sin(track)
        let north = Double(distanceM) * cos(bearing) + travelled * cos(track)
        return (hypot(east, north), Compass.normalized(atan2(east, north) * 180 / .pi))
    }

    /// "Copenhagen (CPH)" becomes "Copenhagen".
    static func city(from place: String?) -> String? {
        guard let place else { return nil }
        guard let bracket = place.lastIndex(of: "("), bracket != place.startIndex else { return place }
        return place[..<bracket].trimmingCharacters(in: .whitespaces)
    }
}

enum Format {
    static func distance(_ meters: Int) -> String {
        if meters < 1000 { return "\(meters) m" }
        let kilometers = Double(meters) / 1000
        // Whole distances read better without a decimal: "8 km", not "8,0 km".
        let digits = kilometers < 10 && meters % 1000 != 0 ? 1 : 0
        return kilometers.formatted(.number.precision(.fractionLength(digits))) + " km"
    }

    static func altitude(_ feet: Int) -> String {
        "\(feet.formatted(.number)) ft"
    }

    static func meters(fromFeet feet: Int) -> String {
        "\(Int((Double(feet) * 0.3048).rounded()).formatted(.number)) m"
    }
}
