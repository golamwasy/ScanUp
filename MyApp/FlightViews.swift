import SwiftUI

extension FlightStatus {
    /// How the status reads at one end of a flight. A flight that is late but still to go reads "Delayed".
    func label(late: Bool, direction: BoardDirection) -> String {
        switch self {
        case .expected: late ? String(localized: "Delayed") : String(localized: "Scheduled")
        case .checkIn: String(localized: "Check-in")
        case .boarding: String(localized: "Boarding")
        case .gateClosed: String(localized: "Gate closed")
        case .departed: direction == .departures ? String(localized: "Departed") : String(localized: "In the air")
        case .enRoute: String(localized: "In the air")
        case .approaching: String(localized: "Landing soon")
        case .arrived: String(localized: "Landed")
        case .delayed: String(localized: "Delayed")
        case .canceled: String(localized: "Cancelled")
        case .canceledUncertain: String(localized: "Maybe cancelled")
        case .diverted: String(localized: "Diverted")
        case .unknown: String(localized: "No status")
        }
    }

    func tint(late: Bool) -> Color {
        switch self {
        case .canceled: Theme.danger
        case .delayed, .canceledUncertain, .diverted: Theme.warning
        case .expected: late ? Theme.warning : .secondary
        case .checkIn, .boarding, .gateClosed, .enRoute, .approaching: Theme.accent
        case .departed, .arrived: Theme.positive
        case .unknown: .secondary
        }
    }
}

enum AirportClock {
    /// "2026-10-21" at an airport `offsetSeconds` east of UTC.
    static func day(_ date: Date, offsetSeconds: Int) -> String {
        format(date, offsetSeconds: offsetSeconds, pattern: "yyyy-MM-dd")
    }

    /// "22:14" at an airport `offsetSeconds` east of UTC.
    static func clock(_ date: Date, offsetSeconds: Int) -> String {
        format(date, offsetSeconds: offsetSeconds, pattern: "HH:mm")
    }

    /// "Today", "Tomorrow", "Yesterday", or a weekday and date, for a day at the airport.
    static func dayLabel(_ day: String, today: String) -> String {
        guard let date = parse(day), let todayDate = parse(today) else { return day }
        let calendar = utcCalendar
        switch calendar.dateComponents([.day], from: todayDate, to: date).day {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Tomorrow")
        case -1: return String(localized: "Yesterday")
        default:
            let formatter = DateFormatter()
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("EEEEdMMM")
            return formatter.string(from: date)
        }
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private static func parse(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return utcCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func format(_ date: Date, offsetSeconds: Int, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: offsetSeconds)
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// The status of a flight at one airport, as a small coloured chip.
struct FlightStatusChip: View {
    let flight: ScheduledFlight
    let direction: BoardDirection

    var body: some View {
        let late = flight.end(on: direction).isLate
        Chip(text: flight.flightStatus.label(late: late, direction: direction),
             tint: flight.flightStatus.tint(late: late))
    }
}

/// The scheduled time, and the new time in orange with the old one struck through when it is late.
struct FlightClock: View {
    let end: FlightEnd

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(end.scheduled?.clock ?? "—")
                .font(.system(.headline, design: .rounded))
                .monospacedDigit()
                .strikethrough(end.isLate, color: .secondary)
                .foregroundStyle(end.isLate ? .secondary : .primary)
            if end.isLate, let expected = end.expected {
                Text(expected.clock)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.warning)
            }
        }
    }
}

/// One flight on an airport board.
struct FlightRow: View {
    let flight: ScheduledFlight
    let direction: BoardDirection
    let open: () -> Void

    var body: some View {
        let end = flight.end(on: direction)
        let other = flight.otherEnd(on: direction).airport
        Button(action: open) {
            HStack(spacing: 12) {
                FlightClock(end: end)
                    .frame(width: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(other.shortName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text([flight.number, other.code].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    FlightStatusChip(flight: flight, direction: direction)
                    if let place = direction == .departures ? end.gate.map({ String(localized: "Gate \($0)") })
                        : end.baggageBelt.map({ String(localized: "Belt \($0)") }) {
                        Text(place)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .cardBackground()
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
        .buttonStyle(PressableCardStyle())
        // Flights that have gone or landed step back a little, so the ones still to come stand out.
        .opacity(flight.flightStatus.isDone(on: direction) ? 0.62 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(end: end, other: other))
        .accessibilityHint("Shows the flight’s details")
    }

    /// "Departure 10:00, expected 10:30. Paris, flight AY 1406. Delayed. Gate B4", the way the row reads to the eye.
    private func accessibilityLabel(end: FlightEnd, other: Place) -> String {
        var parts: [String] = []
        if let scheduled = end.scheduled {
            if end.isLate, let expected = end.expected {
                parts.append(String(localized: "Scheduled \(scheduled.clock), expected \(expected.clock)"))
            } else {
                parts.append(String(localized: "At \(scheduled.clock)"))
            }
        }
        parts.append(direction == .departures ? String(localized: "To \(other.shortName)") : String(localized: "From \(other.shortName)"))
        parts.append(String(localized: "Flight \(flight.number)"))
        parts.append(flight.flightStatus.label(late: end.isLate, direction: direction))
        if direction == .departures, let gate = end.gate { parts.append(String(localized: "Gate \(gate)")) }
        if direction == .arrivals, let belt = end.baggageBelt { parts.append(String(localized: "Belt \(belt)")) }
        return parts.joined(separator: ". ")
    }
}

/// The line between the past and the coming flights, with the time at the airport.
struct NowMarker: View {
    let time: String

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.warning).frame(width: 8, height: 8)
            Text("Now · \(time)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.warning)
            Rectangle().fill(Theme.warning.opacity(0.5)).frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Everything known about a flight: both airports with their times and details, and the aircraft.
struct FlightDetailView: View {
    let flight: ScheduledFlight

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                VStack(spacing: 12) {
                    RouteView(fromCode: flight.departure.airport.code, fromCity: flight.departure.airport.shortName,
                              toCode: flight.arrival.airport.code, toCity: flight.arrival.airport.shortName)
                    if let km = flight.distanceKm {
                        Text("\(km.formatted()) km")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .cardBackground()
                EndCard(title: String(localized: "Departure"), end: flight.departure, isDeparture: true)
                EndCard(title: String(localized: "Arrival"), end: flight.arrival, isDeparture: false)
                if !aircraftFacts.isEmpty {
                    factsCard(title: String(localized: "Aircraft"), facts: aircraftFacts)
                }
                Text("Times are local to each airport. Flight schedules by AeroDataBox.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .background(SkyBackground())
        .navigationTitle(flight.number)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: 14) {
            InitialsBadge(initials: flight.initials, seed: flight.colorSeed, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(flight.number)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                if let airline = flight.airline {
                    Text(airline).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            FlightStatusChip(flight: flight, direction: flight.flightStatus == .arrived ? .arrivals : .departures)
        }
        .padding(16)
        .cardBackground()
    }

    private var aircraftFacts: [Fact] {
        var facts: [Fact] = []
        if let model = flight.aircraftModel {
            facts.append(Fact(symbol: "airplane", title: String(localized: "Model"), value: model))
        }
        if let registration = flight.registration {
            facts.append(Fact(symbol: "number", title: String(localized: "Registration"), value: registration))
        }
        if let callsign = flight.callsign {
            facts.append(Fact(symbol: "dot.radiowaves.left.and.right", title: String(localized: "Callsign"), value: callsign))
        }
        return facts
    }

    private func factsCard(title: String, facts: [Fact]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      spacing: 14) {
                ForEach(facts, id: \.title) { FactView(fact: $0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardBackground()
    }
}

/// One airport of a flight in the detail view: its name, the times and the terminal, gate, check-in and belt.
private struct EndCard: View {
    let title: String
    let end: FlightEnd
    let isDeparture: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: isDeparture ? "airplane.departure" : "airplane.arrival")
                    .font(.headline)
                Spacer()
                if let delay = delayText {
                    Text(delay.text)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(delay.tint)
                }
            }
            Text(end.airport.name + (end.airport.code.map { " (\($0))" } ?? ""))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 24) {
                time(title: String(localized: "Scheduled"), value: end.scheduled)
                if let actual = end.actual {
                    time(title: isDeparture ? String(localized: "Took off") : String(localized: "Landed"), value: actual)
                } else if let expected = end.expected {
                    time(title: String(localized: "Expected"), value: expected)
                }
            }
            if !facts.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                          spacing: 14) {
                    ForEach(facts, id: \.title) { FactView(fact: $0) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardBackground()
    }

    private var delayText: (text: String, tint: Color)? {
        guard let minutes = end.delayMinutes else { return nil }
        if minutes >= 5 { return (String(localized: "\(minutes) min late"), Theme.warning) }
        if minutes <= -5 { return (String(localized: "\(-minutes) min early"), Theme.positive) }
        return (String(localized: "On time"), Theme.positive)
    }

    private func time(title: String, value: FlightTime?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value?.clock ?? "—")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
    }

    private var facts: [Fact] {
        var facts: [Fact] = []
        if let terminal = end.terminal {
            facts.append(Fact(symbol: "building.2", title: String(localized: "Terminal"), value: terminal))
        }
        if let gate = end.gate {
            facts.append(Fact(symbol: "door.left.hand.open", title: String(localized: "Gate"), value: gate))
        }
        if let checkIn = end.checkIn {
            facts.append(Fact(symbol: "person.text.rectangle", title: String(localized: "Check-in"), value: checkIn))
        }
        if let belt = end.baggageBelt {
            facts.append(Fact(symbol: "suitcase.rolling", title: String(localized: "Baggage belt"), value: belt))
        }
        return facts
    }
}

/// When a flight left and when it is due, as two columns: the best known time large, and below it whether that is real
/// or expected, what was scheduled and how late it is. Times are on each airport's own clock.
struct ScheduleTimes: View {
    let schedule: ScheduledFlight

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                column(title: String(localized: "Departs"), symbol: "airplane.departure", end: schedule.departure, isDeparture: true)
                column(title: String(localized: "Arrives"), symbol: "airplane.arrival", end: schedule.arrival, isDeparture: false)
            }
            Text("Local time at each airport")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func column(title: String, symbol: String, end: FlightEnd, isDeparture: Bool) -> some View {
        let shown = end.expected ?? end.scheduled
        return VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(shown?.clock ?? "—")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
            Text(state(end, isDeparture: isDeparture))
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.accent)
            if let detail = detail(end) {
                Text(detail).font(.caption).foregroundStyle(end.isLate ? Theme.warning : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func state(_ end: FlightEnd, isDeparture: Bool) -> String {
        if end.actual != nil { return isDeparture ? String(localized: "Took off") : String(localized: "Landed") }
        return end.expected != nil ? String(localized: "Expected") : String(localized: "Scheduled")
    }

    /// "Scheduled 22:55" and, below it, "10 min late", shown only when there is something to compare with.
    private func detail(_ end: FlightEnd) -> String? {
        guard let scheduled = end.scheduled, end.expected != nil, let minutes = end.delayMinutes else { return nil }
        let late = minutes >= 5 ? String(localized: "\(minutes) min late")
            : minutes <= -5 ? String(localized: "\(-minutes) min early") : String(localized: "on time")
        return String(localized: "Scheduled \(scheduled.clock)\n\(late)")
    }
}
