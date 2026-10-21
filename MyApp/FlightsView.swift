import SwiftUI

/// The state of the flight search: what was asked, the answer, and the last few searches.
@MainActor @Observable
final class FlightSearchModel {
    private static let recentKey = "recentFlightSearches"
    private static let recentLimit = 6

    var text = ""
    var date = Calendar.current.startOfDay(for: Date())
    private(set) var flights: [ScheduledFlight] = []
    /// The flight number and day of the answer on screen.
    private(set) var searched: (number: String, day: String)?
    private(set) var isLoading = false
    private(set) var problem: FeedProblem?
    private(set) var notice: ScheduleNotice?
    /// Shown when the text cannot be a flight number, instead of asking the server.
    private(set) var hint: String?
    private(set) var recent: [String] = UserDefaults.standard.stringArray(forKey: recentKey) ?? []

    /// The days a search can be for, around today.
    static let dayRange: ClosedRange<Date> = {
        let today = Calendar.current.startOfDay(for: Date())
        let calendar = Calendar.current
        return (calendar.date(byAdding: .day, value: -7, to: today) ?? today)...(calendar.date(byAdding: .day, value: 30, to: today) ?? today)
    }()

    /// "2026-10-21" for the chosen day in the phone's calendar.
    var dayString: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func run(store: FlightStore) async {
        guard let number = FlightNumber.normalised(text) else {
            hint = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil
                : String(localized: "That does not look like a flight number. Try something like AY1406 or BA 2490.")
            return
        }
        hint = nil
        let day = dayString
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await store.searchFlights(number: number, date: day)
            flights = response.flights
            notice = response.notice.flatMap(ScheduleNotice.init(rawValue:))
            problem = nil
            searched = (number, day)
            remember(number)
        } catch is CancellationError {
        } catch {
            problem = store.problem(for: error)
            flights = []
            searched = (number, day)
        }
    }

    func clearAnswer() {
        flights = []
        searched = nil
        problem = nil
        notice = nil
        hint = nil
    }

    private func remember(_ number: String) {
        recent.removeAll { $0 == number }
        recent.insert(number, at: 0)
        recent = Array(recent.prefix(Self.recentLimit))
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
    }
}

/// Flight search by flight number, for a day. Each search uses units of the schedule allowance, so it runs only
/// when asked (the search key or a recent search), never while typing.
struct FlightsView: View {
    let store: FlightStore
    let openSettingsTab: () -> Void
    @State private var model = FlightSearchModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    dayPicker
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(SkyBackground())
            .navigationTitle("Flights")
            .navigationDestination(for: ScheduledFlight.self) { FlightDetailView(flight: $0) }
            .searchable(text: $model.text, prompt: "Flight number, like AY1406")
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .onSubmit(of: .search) { search() }
            .onChange(of: model.text) { _, text in
                if text.isEmpty { model.clearAnswer() }
            }
            // A new day for the same flight is a new question, so it is asked at once.
            .onChange(of: model.date) { _, _ in
                if model.searched != nil { search() }
            }
        }
    }

    private func search() {
        store.noteInteraction()
        Task { await model.run(store: store) }
    }

    private var dayPicker: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach([-1, 0, 1], id: \.self) { offset in
                    let day = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date())) ?? Date()
                    let isChosen = Calendar.current.isDate(model.date, inSameDayAs: day)
                    Button {
                        withAnimation(.snappy) { model.date = day }
                    } label: {
                        Text(offset == -1 ? String(localized: "Yesterday") : offset == 0 ? String(localized: "Today") : String(localized: "Tomorrow"))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(isChosen ? Theme.accent : Theme.card, in: Capsule())
                            .foregroundStyle(isChosen ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Another day").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                DatePicker("Day", selection: $model.date, in: FlightSearchModel.dayRange, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
            .padding(.horizontal, 4)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let hint = model.hint {
            MessageCard(systemImage: "character.cursor.ibeam", title: String(localized: "Check the flight number"), message: hint,
                        tint: Theme.warning)
        } else if model.isLoading {
            SkeletonList()
        } else if let problem = model.problem {
            ProblemCard(problem: problem, failureTitle: String(localized: "Couldn’t search"), openSettingsTab: openSettingsTab) {
                search()
            }
        } else if let notice = model.notice, model.flights.isEmpty {
            MessageCard(systemImage: "exclamationmark.circle", title: notice.title, message: notice.message, tint: Theme.warning)
        } else if let searched = model.searched, model.flights.isEmpty {
            MessageCard(systemImage: "airplane.circle", title: String(localized: "No flight \(searched.number)"),
                        message: String(localized: "There is no flight \(searched.number) on \(model.date.formatted(date: .abbreviated, time: .omitted)). Check the number, or try another day."))
        } else if !model.flights.isEmpty {
            results
        } else {
            idle
        }
    }

    private var results: some View {
        VStack(spacing: 12) {
            ForEach(model.flights) { flight in
                NavigationLink(value: flight) {
                    FlightSummaryCard(flight: flight)
                }
                .buttonStyle(PressableCardStyle())
            }
            footnote
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 16) {
            MessageCard(systemImage: "magnifyingglass", title: String(localized: "Find a flight"),
                        message: String(localized: "Type a flight number, like AY1406, and press Search. Choose the day above."))
            if !model.recent.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    FlowRow(items: model.recent) { number in
                        model.text = number
                        search()
                    }
                }
            }
            footnote
        }
    }

    @ViewBuilder
    private var footnote: some View {
        let left = store.usage?.flightSchedules?.remaining
        Text(left.map { String(localized: "Each search uses 2 of this month’s flight schedule units (\($0) left). Times are local to each airport. Flight schedules by AeroDataBox.") }
             ?? String(localized: "Each search uses 2 of this month’s flight schedule units. Times are local to each airport. Flight schedules by AeroDataBox."))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }
}

/// A flight in the search results: number, route, times and status.
private struct FlightSummaryCard: View {
    let flight: ScheduledFlight

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                InitialsBadge(initials: flight.initials, seed: flight.colorSeed, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(flight.number).font(.headline).foregroundStyle(.primary)
                    if let airline = flight.airline {
                        Text(airline).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                FlightStatusChip(flight: flight, direction: flight.flightStatus == .arrived || flight.flightStatus == .approaching ? .arrivals : .departures)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .top) {
                end(flight.departure, alignment: .leading)
                Spacer()
                Image(systemName: "airplane")
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 6)
                Spacer()
                end(flight.arrival, alignment: .trailing)
            }
        }
        .padding(16)
        .cardBackground()
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func end(_ end: FlightEnd, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(end.airport.code ?? "—")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
            Text(end.airport.shortName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            FlightClock(end: end)
        }
    }
}

/// Recent flight numbers as tappable capsules that wrap onto more lines.
private struct FlowRow: View {
    let items: [String]
    let tap: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { capsules }
            VStack(alignment: .leading, spacing: 8) { capsules }
        }
    }

    private var capsules: some View {
        ForEach(items, id: \.self) { number in
            Button { tap(number) } label: {
                Label(number, systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.card, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}
