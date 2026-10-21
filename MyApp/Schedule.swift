import Foundation

// Flight schedules from the server: airport boards, flight search and airport search (see the backend's
// API_CONTRACT.md). Times come twice: in UTC for ordering, and on the airport's own clock for showing.

/// An airport as the server describes it.
struct Place: Decodable, Hashable, Identifiable {
    let name: String
    let city: String?
    let iata: String?
    let icao: String?
    let country: String?

    var id: String { icao ?? iata ?? name }
    /// The code to show: "HEL", or "EFHK" when there is no IATA code.
    var code: String? { iata ?? icao }
    /// "Copenhagen", or the airport's name when the city is not known. "Helsinki (Vantaa)" reads "Helsinki".
    var shortName: String { Aircraft.city(from: city) ?? name }
}

/// A time at an airport.
struct FlightTime: Decodable, Hashable {
    let utc: Date
    /// The airport's own clock with its offset, for example "2026-10-21T22:20:00+03:00".
    let local: String

    /// "22:20", as the airport's board shows it.
    var clock: String { local.count >= 16 ? String(local.dropFirst(11).prefix(5)) : "" }
    /// "2026-10-21", the date at the airport.
    var day: String { String(local.prefix(10)) }
    /// The airport's offset from UTC in seconds, read from the end of `local` ("+03:00").
    var offsetSeconds: Int? {
        let tail = local.suffix(6)
        guard tail.count == 6, let sign = tail.first, sign == "+" || sign == "-",
              let hours = Int(tail.dropFirst().prefix(2)), let minutes = Int(tail.suffix(2)) else { return nil }
        return (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
    }
}

/// One end of a flight: where it leaves from or lands, when, and the details at that airport.
struct FlightEnd: Decodable, Hashable {
    let airport: Place
    let scheduled: FlightTime?
    /// The airline's latest estimate.
    let revised: FlightTime?
    /// The data provider's own estimate.
    let predicted: FlightTime?
    /// When it really left or landed (runway time).
    let actual: FlightTime?
    let terminal: String?
    let gate: String?
    let checkIn: String?
    let baggageBelt: String?

    /// The newest time there is: the real one, then the airline's estimate, then the prediction.
    var expected: FlightTime? { actual ?? revised ?? predicted }

    /// Minutes later (positive) or earlier (negative) than scheduled, when both are known.
    var delayMinutes: Int? {
        guard let scheduled, let expected else { return nil }
        return Int((expected.utc.timeIntervalSince(scheduled.utc) / 60).rounded())
    }

    /// Five minutes or more late.
    var isLate: Bool { (delayMinutes ?? 0) >= 5 }
}

enum FlightStatus: String {
    case expected, boarding, departed, approaching, arrived, delayed, canceled, diverted, unknown
    case checkIn = "check_in"
    case gateClosed = "gate_closed"
    case enRoute = "en_route"
    case canceledUncertain = "canceled_uncertain"

    var isCancelled: Bool { self == .canceled }
    /// Finished as far as this list is concerned, so the row belongs to the past: a flight that has left is done on the
    /// Departures list but still to come on the Arrivals list, where only landing (or no landing) ends it.
    func isDone(on direction: BoardDirection) -> Bool {
        switch direction {
        case .departures: self == .departed || self == .enRoute || self == .arrived || self == .canceled || self == .diverted
        case .arrivals: self == .arrived || self == .canceled || self == .diverted
        }
    }
}

enum BoardDirection: String, CaseIterable, Identifiable {
    case departures, arrivals

    var id: String { rawValue }
    var title: String {
        switch self {
        case .departures: String(localized: "Departures")
        case .arrivals: String(localized: "Arrivals")
        }
    }
}

struct ScheduledFlight: Decodable, Hashable, Identifiable {
    /// As the airline writes it, for example "AY 1406".
    let number: String
    let callsign: String?
    let status: String
    let airline: String?
    let airlineIata: String?
    let departure: FlightEnd
    let arrival: FlightEnd
    let aircraftModel: String?
    let registration: String?
    let distanceKm: Int?

    var id: String { "\(number)|\(departure.scheduled?.local ?? "")|\(arrival.airport.id)" }
    var flightStatus: FlightStatus { FlightStatus(rawValue: status) ?? .unknown }

    /// This airport's end of the flight on a board: where it leaves for departures, where it lands for arrivals.
    func end(on direction: BoardDirection) -> FlightEnd { direction == .departures ? departure : arrival }
    /// The other airport's end: where it goes to, or where it comes from.
    func otherEnd(on direction: BoardDirection) -> FlightEnd { direction == .departures ? arrival : departure }

    /// Letters for the round badge: the airline's code, or the start of the flight number.
    var initials: String { airlineIata ?? String(number.prefix(2)).uppercased() }
    /// A stable number for the badge colour, the same for every flight of an airline.
    var colorSeed: Int {
        (airline ?? airlineIata ?? number).unicodeScalars.reduce(7) { ($0 &* 31) &+ Int($1.value) } & 0xFFFF
    }
}

struct BoardAirport: Decodable, Equatable {
    let name: String
    let city: String?
    let iata: String?
    let icao: String
    let country: String?
    let isNearest: Bool
    let distanceM: Int?

    var place: Place { Place(name: name, city: city, iata: iata, icao: icao, country: country) }
}

struct BoardResponse: Decodable {
    let airport: BoardAirport?
    let updatedAt: Date
    let refreshAfterS: Int?
    let notice: String?
    /// Who the flights came from, for the credits. Empty from servers older than the extra board sources.
    let sources: [String]
    let departures: [ScheduledFlight]
    let arrivals: [ScheduledFlight]

    private enum CodingKeys: String, CodingKey {
        case airport, updatedAt, refreshAfterS, notice, sources, departures, arrivals
    }

    /// One flight that does not read as expected is left out, not the whole board.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        airport = try container.decodeIfPresent(BoardAirport.self, forKey: .airport)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        refreshAfterS = try container.decodeIfPresent(Int.self, forKey: .refreshAfterS)
        notice = try container.decodeIfPresent(String.self, forKey: .notice)
        sources = (try? container.decodeIfPresent([String].self, forKey: .sources)) ?? []
        departures = try container.decode(LossyList<ScheduledFlight>.self, forKey: .departures).elements
        arrivals = try container.decode(LossyList<ScheduledFlight>.self, forKey: .arrivals).elements
    }
}

/// A list that keeps the elements that decode and skips the others.
struct LossyList<Element: Decodable>: Decodable {
    let elements: [Element]

    /// Takes the place of an element that did not decode, so the list moves on to the next one.
    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try container.decode(Skipped.self)
            }
        }
        self.elements = elements
    }
}

/// A value the app can do without: when it does not decode it is nil, and the rest of the answer is kept.
@propertyWrapper
struct Lenient<Value: Decodable & Equatable>: Decodable, Equatable {
    var wrappedValue: Value?

    init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        wrappedValue = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// A missing key is nil as well.
    func decode<Value>(_ type: Lenient<Value>.Type, forKey key: Key) throws -> Lenient<Value> {
        try decodeIfPresent(type, forKey: key) ?? Lenient(wrappedValue: nil)
    }
}

struct AirportSearchResponse: Decodable {
    let airports: [Place]
}

/// Why schedules are old, short or missing, as the server says it.
/// The credit the flight schedule providers ask for, naming the ones that supplied the flights on screen.
enum ScheduleCredit {
    /// "Flight schedules by AeroDataBox and AirLabs." AeroDataBox alone when the server named no source.
    static func text(for sources: [String]) -> String {
        let names = sources.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 40 }
        let shown = names.isEmpty ? ["AeroDataBox"] : Array(names.prefix(3))
        return String(localized: "Flight schedules by \(ListFormatter.localizedString(byJoining: shown)).")
    }
}

enum ScheduleNotice: String {
    case notConfigured = "not_configured"
    case allowanceUsed = "allowance_used"
    case denied
    case unavailable
    case noAirportNearby = "no_airport_nearby"

    var title: String {
        switch self {
        case .notConfigured: String(localized: "Flight schedules are not set up")
        case .allowanceUsed: String(localized: "Monthly allowance used")
        case .denied: String(localized: "Schedule service refused the key")
        case .unavailable: String(localized: "Flight schedules unavailable")
        case .noAirportNearby: String(localized: "No airport nearby")
        }
    }

    var message: String {
        switch self {
        case .notConfigured: String(localized: "The server has no key for the flight schedule service yet.")
        case .allowanceUsed: String(localized: "This month’s flight schedule requests are nearly used up. Boards you opened before still show; new ones come back when the month restarts.")
        case .denied: String(localized: "The server’s key for the flight schedule service was refused. It may need to be renewed.")
        case .unavailable: String(localized: "The flight schedule service did not answer. Trying again soon.")
        case .noAirportNearby: String(localized: "There is no airport with scheduled flights within 40 km. Search for one instead.")
        }
    }
}

/// A line of a board list: a day heading, the "now" line, or a flight.
enum BoardRow: Identifiable {
    case day(String)
    case now
    case flight(ScheduledFlight)

    var id: String {
        switch self {
        case .day(let day): "day-\(day)"
        case .now: "now"
        case .flight(let flight): flight.id
        }
    }

    /// The board's lines in time order, with a heading where the date at the airport changes and the "now" line
    /// before the first flight scheduled from now on (at the end when every flight is in the past).
    static func rows(for flights: [ScheduledFlight], direction: BoardDirection, now: Date) -> [BoardRow] {
        var rows: [BoardRow] = []
        var day: String?
        var nowPlaced = false
        var unscheduled: [BoardRow] = []
        for flight in flights {
            // A flight without a time cannot be placed, so it goes to the end instead of vanishing.
            guard let scheduled = flight.end(on: direction).scheduled else {
                unscheduled.append(.flight(flight))
                continue
            }
            if !nowPlaced, scheduled.utc >= now {
                rows.append(.now)
                nowPlaced = true
            }
            if scheduled.day != day {
                day = scheduled.day
                rows.append(.day(scheduled.day))
            }
            rows.append(.flight(flight))
        }
        if !nowPlaced { rows.append(.now) }
        return rows + unscheduled
    }
}

/// Which part of a board to show, so a long board opens at "now" with a few flights and grows as it is scrolled.
enum BoardPaging {
    /// Flights shown from "now" on when a board opens, and added by each tap on "Show more".
    static let firstPage = 15
    static let step = 30

    /// How much has been added to the first page, before "now" and after it.
    struct Window: Equatable {
        var earlier = 0
        var later = 0
    }

    /// The part of `flights` (in time order, flights without a time last) to show: the first page from "now", with the
    /// earlier and later flights that were asked for added. When nothing is still to come, the last flights are shown.
    static func range(in flights: [ScheduledFlight], direction: BoardDirection, now: Date, window: Window) -> Range<Int> {
        let count = flights.count
        guard count > 0 else { return 0..<0 }
        let firstUnscheduled = flights.firstIndex { $0.end(on: direction).scheduled == nil } ?? count
        let anchor = flights.firstIndex { ($0.end(on: direction).scheduled?.utc ?? .distantPast) >= now } ?? firstUnscheduled
        let upcoming = firstUnscheduled - anchor
        let start = upcoming > 0 ? anchor - window.earlier : anchor - firstPage - window.earlier
        let end = upcoming > 0 ? anchor + firstPage + window.later : anchor + window.later
        return max(0, start)..<min(count, max(end, 0))
    }

    /// Two lists of one board in one: time order, a flight in both once (the first list wins), flights without a time last.
    static func merged(_ first: [ScheduledFlight], _ second: [ScheduledFlight], direction: BoardDirection) -> [ScheduledFlight] {
        var seen = Set<String>()
        let unique = (first + second).filter { seen.insert($0.id).inserted }
        return unique.enumerated().sorted { left, right in
            let a = left.element.end(on: direction).scheduled?.utc ?? .distantFuture
            let b = right.element.end(on: direction).scheduled?.utc ?? .distantFuture
            return a == b ? left.offset < right.offset : a < b
        }.map(\.element)
    }
}

/// What the server knows of one aircraft: how old it is, when it was delivered and how many seats it has.
struct AircraftDetails: Decodable, Equatable {
    let registration: String
    let ageYears: Double?
    /// "2002-02-28".
    let delivered: String?
    let firstFlight: String?
    let seats: Int?
    let model: String?
    let notice: String?

    /// "24.8 years", or "5 months" for a new aircraft. Nil when the age is not known.
    var ageText: String? {
        guard let ageYears, ageYears >= 0 else { return nil }
        if ageYears < 1 {
            let months = max(1, Int((ageYears * 12).rounded()))
            return String(localized: "\(months) months")
        }
        return String(localized: "\(ageYears.formatted(.number.precision(.fractionLength(1)))) years")
    }

    /// "Delivered Feb 2002 · 174 seats".
    var ageDetail: String? {
        let parts = [Self.monthAndYear(delivered ?? firstFlight).map { String(localized: "Delivered \($0)") },
                     seats.map { String(localized: "\($0) seats") }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "2002-02-28" as "Feb 2002", in the phone's language.
    static func monthAndYear(_ day: String?) -> String? {
        guard let day else { return nil }
        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.timeZone = TimeZone(secondsFromGMT: 0)
        reader.dateFormat = "yyyy-MM-dd"
        guard let date = reader.date(from: day) else { return nil }
        let writer = DateFormatter()
        writer.timeZone = TimeZone(secondsFromGMT: 0)
        writer.setLocalizedDateFormatFromTemplate("MMM yyyy")
        return writer.string(from: date)
    }
}

enum TrackQuery {
    /// "ay 1406" becomes "AY1406"; nil when it cannot be a flight number, callsign or registration. The same rule as
    /// the server, so a typing mistake does not cost a request: letters, digits and hyphens, two to ten of them.
    static func normalised(_ text: String) -> String? {
        let compact = text.uppercased().filter { !$0.isWhitespace }
        guard compact.range(of: #"^[A-Z0-9][A-Z0-9-]{1,9}$"#, options: .regularExpression) != nil else { return nil }
        return compact
    }
}
