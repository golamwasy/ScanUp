import Foundation

/// One aircraft as the backend describes it (see the backend's API_CONTRACT.md).
struct Aircraft: Decodable, Identifiable, Equatable {
    let id: String
    let callsign: String?
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
    let onGround: Bool
}

struct NearbyResponse: Decodable {
    let aircraft: [Aircraft]
    /// Seconds the backend asks the app to wait before the next refresh.
    let refreshAfterS: Int?
}

struct AirportInfo: Decodable, Equatable {
    let name: String
    let iata: String?
    let icao: String
    let distanceM: Int
}

struct AirportResponse: Decodable {
    let airport: AirportInfo?
    let source: String?
    let refreshAfterS: Int?
    let aircraft: [Aircraft]
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

extension Aircraft {
    /// The airline when known, otherwise the best identifier there is.
    var title: String {
        airline ?? callsign ?? registration ?? String(localized: "Unknown aircraft")
    }

    /// Second line of a collapsed card.
    var subtitle: String {
        [airline == nil ? nil : callsign, type].compactMap { $0 }.joined(separator: " · ")
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
        return kilometers < 10
            ? kilometers.formatted(.number.precision(.fractionLength(1))) + " km"
            : kilometers.formatted(.number.precision(.fractionLength(0))) + " km"
    }

    static func altitude(_ feet: Int) -> String {
        "\(feet.formatted(.number)) ft"
    }

    static func meters(fromFeet feet: Int) -> String {
        "\(Int((Double(feet) * 0.3048).rounded()).formatted(.number)) m"
    }
}
