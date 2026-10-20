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
    let onGround: Bool
}

struct NearbyResponse: Decodable {
    let aircraft: [Aircraft]
}

struct AirportInfo: Decodable, Equatable {
    let name: String
    let iata: String?
    let icao: String
    let distanceM: Int
}

struct AirportResponse: Decodable {
    let airport: AirportInfo?
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

    static func compassPoint(for degrees: Int) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return points[Int((Double(degrees) / 45).rounded()) % 8]
    }

    var hasRoute: Bool { originCode != nil || destinationCode != nil }

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
