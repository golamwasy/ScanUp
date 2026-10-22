import SwiftUI

/// The state of the search: what was asked, the aircraft found, and the last few searches.
@MainActor @Observable
final class AircraftSearchModel {
    private static let recentKey = "recentAircraftSearches"
    private static let recentLimit = 3

    var text = ""
    private(set) var aircraft: [Aircraft] = []
    /// When no aircraft is heard: what the schedule knows of the flight (it has landed, or has not left).
    private(set) var timetable: ScheduledFlight?
    /// What the answer on screen was asked for.
    private(set) var searched: String?
    private(set) var foundAt: Date?
    private(set) var isLoading = false
    private(set) var problem: FeedProblem?
    /// Shown when the text cannot be a flight number, callsign or registration, instead of asking the server.
    private(set) var hint: String?
    private(set) var recent: [String] = Array((UserDefaults.standard.stringArray(forKey: recentKey) ?? []).prefix(recentLimit))
    /// Counts the searches, so only the newest one may write its answer: an older one that finishes late is ignored.
    private var generation = 0

    func run(store: FlightStore, asking query: String? = nil) async {
        let typed = query ?? text
        guard let normalised = TrackQuery.normalised(typed) else {
            hint = typed.trimmingCharacters(in: .whitespaces).isEmpty ? nil
                : String(localized: "That does not look like a flight number, callsign or registration. Try AY1406, FIN5DA or OH-LXA.")
            return
        }
        hint = nil
        generation += 1
        let mine = generation
        isLoading = true
        do {
            let found = try await store.track(query: normalised)
            guard mine == generation else { return }
            aircraft = found.aircraft
            timetable = found.schedule
            foundAt = Date()
            problem = nil
            searched = normalised
            remember(normalised)
        } catch is CancellationError {
            // Cleared or replaced: whoever did that owns the screen now.
            return
        } catch {
            guard mine == generation else { return }
            problem = store.problem(for: error)
            aircraft = []
            timetable = nil
            searched = normalised
        }
        isLoading = false
    }

    func clearRecent() {
        recent = []
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
    }

    func clearAnswer() {
        generation += 1
        isLoading = false
        aircraft = []
        timetable = nil
        searched = nil
        problem = nil
        hint = nil
        foundAt = nil
    }

    private func remember(_ query: String) {
        recent.removeAll { $0 == query }
        recent.insert(query, at: 0)
        recent = Array(recent.prefix(Self.recentLimit))
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
    }
}

/// Looks for one aircraft that is in the air and heard right now, by flight number, callsign or registration. When it
/// is found its details open at once; when it is not, the screen says so. A search uses one to three of the ADSB.lol
/// requests, so it runs only when asked (the search key or a recent search), never while typing.
struct SearchView: View {
    let store: FlightStore
    let openSettingsTab: () -> Void
    @State private var model = AircraftSearchModel()
    @State private var expanded: Set<String> = []
    @State private var searching: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(SkyBackground())
            .navigationTitle("Search")
            .searchable(text: $model.text, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Flight, callsign or registration")
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit(of: .search) { search() }
            .onChange(of: model.text) { _, text in
                if text.isEmpty {
                    searching?.cancel()
                    model.clearAnswer()
                }
            }
            .refreshable {
                guard let searched = model.searched else { return }
                store.noteInteraction()
                await model.run(store: store, asking: searched)
            }
        }
    }

    private func search(_ query: String? = nil) {
        store.noteInteraction()
        if let query { model.text = query }
        // A new search starts with every card closed, except a single answer, which opens at once.
        expanded = []
        searching?.cancel()
        searching = Task {
            await model.run(store: store, asking: query)
            if !Task.isCancelled, model.aircraft.count == 1, let only = model.aircraft.first {
                withAnimation(Theme.spring) { expanded = [only.id] }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let hint = model.hint {
            MessageCard(systemImage: "character.cursor.ibeam", title: String(localized: "Check what you typed"), message: hint,
                        tint: Theme.warning)
        } else if model.isLoading {
            SkeletonList()
        } else if let problem = model.problem {
            ProblemCard(problem: problem, failureTitle: String(localized: "Couldn’t search"), openSettingsTab: openSettingsTab) {
                search(model.searched)
            }
        } else if let searched = model.searched, model.aircraft.isEmpty, let timetable = model.timetable {
            NotFlyingCard(searched: searched, flight: timetable)
            footnote
        } else if let searched = model.searched, model.aircraft.isEmpty {
            MessageCard(systemImage: "antenna.radiowaves.left.and.right.slash", title: String(localized: "\(searched) is not on the radar"),
                        message: String(localized: "No aircraft is sending a signal under that name right now. It may not be in the air yet, may have landed, may be out of range of the receivers, or may fly under another callsign. Try its callsign or registration."))
            footnote
        } else if !model.aircraft.isEmpty {
            results
        } else {
            idle
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            let viaFlightAware = model.aircraft.contains(where: \.isFromFlightAware)
            Label(viaFlightAware ? String(localized: "Tracked by FlightAware") : String(localized: "On the radar now"),
                  systemImage: viaFlightAware ? "globe" : "dot.radiowaves.left.and.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.positive)
                .textCase(.uppercase)
                .padding(.leading, 4)
            if viaFlightAware {
                let age = model.aircraft.compactMap(\.positionAgeText).first
                Text("No receiver hears this flight right now, so its position comes from FlightAware\(age.map { ", reported \($0)" } ?? ""). It can be a few minutes behind.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            ForEach(model.aircraft) { item in
                AircraftCard(aircraft: item, isExpanded: expanded.contains(item.id)) {
                    store.noteInteraction()
                    withAnimation(Theme.spring) {
                        if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                    }
                }
            }
            if let foundAt = model.foundAt {
                Text("Seen at \(foundAt.formatted(date: .omitted, time: .shortened)). Pull down to look again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            footnote
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 16) {
            MessageCard(systemImage: "magnifyingglass", title: String(localized: "Find a plane"),
                        message: String(localized: "Type a flight number like AY1406, a callsign like FIN5DA or a registration like OH-LXA, and press Search. If that plane is in the air and heard right now, you see where it is."))
            if !model.recent.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recent").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        Spacer()
                        Button("Clear") { model.clearRecent() }
                            .font(.footnote.weight(.semibold))
                    }
                    FlowRow(items: model.recent) { search($0) }
                }
            }
            footnote
        }
    }

    private var footnote: some View {
        Text("Planes that are flying and heard by ADS-B receivers are found. Over deserts and the sea no receiver hears them, and then the position can come from FlightAware, a few minutes old. Each search uses up to 3 of the day’s ADSB.lol requests. Flight times by AeroDataBox.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }
}

/// Recent searches as tappable capsules that wrap onto more lines.
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
        ForEach(items, id: \.self) { query in
            Button { tap(query) } label: {
                Label(query, systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.card, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

/// A flight that is in the schedule but not on the radar: it has landed, or has not left yet. Shows what the schedule
/// says, with the real and expected times.
private struct NotFlyingCard: View {
    let searched: String
    let flight: ScheduledFlight

    private var headline: String {
        switch flight.flightStatus {
        case .arrived: String(localized: "\(flight.number) has landed")
        case .canceled: String(localized: "\(flight.number) was cancelled")
        case .expected, .checkIn, .boarding, .gateClosed, .delayed: String(localized: "\(flight.number) has not left yet")
        default: String(localized: "\(flight.number) is not on the radar")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                InitialsBadge(initials: flight.initials, seed: flight.colorSeed, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.headline)
                    Text("Not on the radar right now").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            RouteView(fromCode: flight.departure.airport.code, fromCity: flight.departure.airport.shortName,
                      toCode: flight.arrival.airport.code, toCity: flight.arrival.airport.shortName)
            if flight.flightStatus != .canceled { ScheduleTimes(schedule: flight) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}
