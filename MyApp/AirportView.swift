import SwiftUI

/// The board of an airport: departures and arrivals from 12 hours ago to 12 hours ahead. It shows the nearest airport,
/// or another one picked in the search, and opens at "now".
struct AirportView: View {
    let store: FlightStore
    let openSettingsTab: () -> Void
    @State private var direction = BoardDirection.departures
    @State private var showingPicker = false
    @State private var openFlight: ScheduledFlight?

    private var board: BoardFeed { store.board }
    private var flights: [ScheduledFlight] { board.flights(direction) }
    /// The airport's offset from UTC, read from its own times, so "now" and the day headings follow its clock.
    private var offsetSeconds: Int {
        board.departures.lazy.compactMap { $0.departure.scheduled?.offsetSeconds }.first
            ?? board.arrivals.lazy.compactMap { $0.arrival.scheduled?.offsetSeconds }.first
            ?? TimeZone.current.secondsFromGMT()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if board.hasLoaded, !(board.departures.isEmpty && board.arrivals.isEmpty) {
                        Picker("List", selection: $direction) {
                            ForEach(BoardDirection.allCases) { direction in
                                Text("\(direction.title) \(board.flights(direction).count)").tag(direction)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    content
                    if board.hasLoaded {
                        Text("Times are local to the airport. Flight schedules by AeroDataBox.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(SkyBackground())
            .refreshable {
                store.noteInteraction()
                await store.refreshBoard()
            }
            .onScrollPhaseChange { _, _ in store.noteInteraction() }
            .scrollIndicators(.hidden)
            // Opens at "now", with a few earlier flights above it, when a board arrives and when the list changes.
            .onChange(of: scrollKey) { _, _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation(.smooth) { proxy.scrollTo("now", anchor: UnitPoint(x: 0.5, y: 0.22)) }
                }
            }
        }
        .sheet(isPresented: $showingPicker) {
            AirportPicker(store: store)
        }
        .sheet(item: $openFlight) { flight in
            NavigationStack {
                FlightDetailView(flight: flight)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { openFlight = nil }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private struct ScrollKey: Equatable {
        let airport: String?
        let loaded: Bool
        let direction: BoardDirection
    }

    private var scrollKey: ScrollKey { ScrollKey(airport: board.airport?.icao, loaded: board.hasLoaded, direction: direction) }

    private var header: some View {
        VStack(spacing: 10) {
            Image("TowerIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 46, height: 46)
                .foregroundStyle(Theme.accent)
                .padding(.top, 20)
                .accessibilityHidden(true)
            Text(board.airport?.name ?? store.chosenAirport?.name ?? String(localized: "Airport"))
                .font(.system(.title, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)
            if let airport = board.airport {
                HStack(spacing: 8) {
                    if let iata = airport.iata { Chip(text: iata) }
                    Chip(text: airport.icao, tint: .secondary)
                    if airport.isNearest, let distance = airport.distanceM {
                        Chip(text: String(localized: "\(Format.distance(distance)) away"), systemImage: "location.fill", tint: .secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    store.noteInteraction()
                    showingPicker = true
                } label: {
                    Label("Change airport", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                if store.chosenAirport != nil {
                    Button {
                        store.noteInteraction()
                        withAnimation(Theme.spring) { store.chooseAirport(nil) }
                    } label: {
                        Label("Nearest", systemImage: "location.fill")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
            .font(.subheadline.weight(.medium))
            .tint(Theme.accent)
            StatusLine(summary: summary, board: board, isPaused: store.isPaused, resume: store.noteInteraction) {
                Task { await store.refreshBoard() }
            }
            if store.chosenAirport == nil {
                TestLocationNotice(place: store.testLocation)
            }
            if let notice = board.notice, notice != .noAirportNearby, !(board.departures.isEmpty && board.arrivals.isEmpty) {
                // The server sent the last good board it had, so say how old it is.
                Label(String(localized: "\(notice.title). Showing the board from \(board.dataTime?.formatted(date: .omitted, time: .shortened) ?? "earlier")."),
                      systemImage: "clock.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.spring, value: board.airport)
        .animation(Theme.spring, value: store.chosenAirport)
    }

    private var summary: String {
        guard board.hasLoaded, board.airport != nil else {
            return String(localized: "12 hours back and 12 hours ahead")
        }
        return String(localized: "\(board.departures.count) departures · \(board.arrivals.count) arrivals")
    }

    @ViewBuilder
    private var content: some View {
        if board.showsProblem, let problem = board.problem, board.departures.isEmpty, board.arrivals.isEmpty {
            ProblemCard(problem: problem, failureTitle: String(localized: "Couldn’t load flights"), openSettingsTab: openSettingsTab) {
                Task { await store.refreshBoard() }
            }
        } else if !board.hasLoaded {
            SkeletonList()
        } else if let notice = board.notice, board.departures.isEmpty, board.arrivals.isEmpty {
            MessageCard(systemImage: notice == .noAirportNearby ? "mappin.slash" : "exclamationmark.circle",
                        title: notice.title, message: notice.message,
                        tint: notice == .noAirportNearby ? Theme.accent : Theme.warning,
                        actionTitle: notice == .noAirportNearby ? String(localized: "Search for an airport") : nil) {
                showingPicker = true
            }
        } else if flights.isEmpty {
            MessageCard(systemImage: "moon.zzz", title: String(localized: "No \(direction.title.lowercased())"),
                        message: String(localized: "There are no \(direction.title.lowercased()) here from 12 hours ago to 12 hours ahead."))
        } else {
            list
        }
    }

    private var list: some View {
        let now = Date()
        let today = AirportClock.day(now, offsetSeconds: offsetSeconds)
        return LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(BoardRow.rows(for: flights, direction: direction, now: now)) { row in
                switch row {
                case .day(let day):
                    Text(AirportClock.dayLabel(day, today: today))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                case .now:
                    NowMarker(time: AirportClock.clock(now, offsetSeconds: offsetSeconds))
                        .id("now")
                case .flight(let flight):
                    FlightRow(flight: flight, direction: direction) {
                        store.noteInteraction()
                        openFlight = flight
                    }
                }
            }
        }
        .animation(Theme.spring, value: direction)
    }
}

/// Search for another airport by code, city or name, or go back to the nearest one.
struct AirportPicker: View {
    let store: FlightStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var isSearching = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        store.chooseAirport(nil)
                        dismiss()
                    } label: {
                        HStack {
                            Label("Nearest airport", systemImage: "location.fill")
                            Spacer()
                            if store.chosenAirport == nil {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                .listRowBackground(Theme.card)
                if !results.isEmpty {
                    Section("Airports") {
                        ForEach(results) { place in
                            Button {
                                store.chooseAirport(place)
                                dismiss()
                            } label: {
                                row(place)
                            }
                        }
                    }
                    .listRowBackground(Theme.card)
                } else if query.trimmingCharacters(in: .whitespaces).count >= 2, !isSearching, problem == nil {
                    Text("No airport found for “\(query)”.")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Theme.card)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                        .listRowBackground(Theme.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(SkyBackground())
            .overlay(alignment: .top) {
                if isSearching { ProgressView().padding(.top, 8) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "City, airport or code")
            .autocorrectionDisabled()
            // Waits for a pause in typing, so each letter does not ask the server.
            .task(id: query) {
                let text = query.trimmingCharacters(in: .whitespaces)
                guard text.count >= 2 else {
                    results = []
                    problem = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                isSearching = true
                defer { isSearching = false }
                do {
                    results = try await store.searchAirports(text)
                    problem = nil
                } catch is CancellationError {
                } catch {
                    problem = error.localizedDescription
                }
            }
            .navigationTitle("Choose airport")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(_ place: Place) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).foregroundStyle(.primary)
                Text([place.city, place.country.flatMap { Locale.current.localizedString(forRegionCode: $0) }]
                        .compactMap { $0 }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let code = place.code {
                Text(code)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            if store.chosenAirport?.id == place.id {
                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }
}
