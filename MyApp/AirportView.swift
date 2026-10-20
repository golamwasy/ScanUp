import SwiftUI

struct AirportView: View {
    let store: FlightStore
    let openSettingsTab: () -> Void

    private var feed: Feed { store.ground }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(SkyBackground())
        .refreshable { await store.refreshGround() }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "airplane.departure")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
                .padding(.top, 24)
                .symbolEffect(.bounce, value: feed.updatedAt)
            if let airport = store.airport {
                VStack(spacing: 6) {
                    Text(airport.name)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        if let iata = airport.iata { Chip(text: iata) }
                        Chip(text: airport.icao, tint: .secondary)
                        Chip(text: String(localized: "\(Format.distance(airport.distanceM)) away"),
                             systemImage: "location.fill", tint: .secondary)
                    }
                }
            } else {
                Text("Airport")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
            }
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.smooth, value: feed.aircraft.count)
            StatusPill(feed: feed)
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.spring, value: store.airport)
    }

    private var summary: String {
        guard feed.hasLoaded, store.airport != nil else {
            return String(localized: "Aircraft on the ground at the nearest airport")
        }
        return feed.aircraft.isEmpty
            ? String(localized: "Nothing on the ground right now")
            : String(localized: "\(feed.aircraft.count) on the ground")
    }

    @ViewBuilder
    private var content: some View {
        if let problem = feed.problem, feed.aircraft.isEmpty {
            ProblemCard(problem: problem, openSettingsTab: openSettingsTab) {
                Task { await store.refreshGround() }
            }
        } else if !feed.hasLoaded {
            SkeletonList()
        } else if store.airport == nil {
            MessageCard(systemImage: "mappin.slash", title: String(localized: "No airport nearby"),
                        message: String(localized: "ScanUp shows the aircraft on the ground when you are within 40 km of an airport."))
        } else if feed.aircraft.isEmpty {
            MessageCard(systemImage: "moon.zzz", title: String(localized: "Quiet on the ground"),
                        message: String(localized: "No aircraft are being tracked on the ground at this airport right now. Parked aircraft with their transponders off do not appear."))
        } else {
            AircraftList(aircraft: feed.aircraft)
        }
    }
}
