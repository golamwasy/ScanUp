import SwiftUI

struct AirportView: View {
    let store: FlightStore
    let openSettingsTab: () -> Void

    private var feed: Feed { store.ground }
    @State private var selectedID: String?

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
        .refreshable {
            store.noteInteraction()
            await store.refreshGround()
        }
        .onScrollPhaseChange { _, _ in store.noteInteraction() }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image("TowerIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 46, height: 46)
                .foregroundStyle(Theme.accent)
                .padding(.top, 24)
                .accessibilityHidden(true)
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
            StatusLine(summary: summary, feed: feed, isPaused: store.isPaused, resume: store.noteInteraction) {
                Task { await store.refreshGround() }
            }
            TestLocationNotice(place: store.testLocation)
            if usesBackupSource {
                Label("Backup data source. Aircraft on the ground may be missing.", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.spring, value: store.airport)
        .animation(Theme.spring, value: usesBackupSource)
    }

    /// OpenSky answers when the main source is down, and it sees few aircraft on the ground.
    private var usesBackupSource: Bool { feed.hasLoaded && store.airport != nil && store.groundSource == "opensky" }

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
        if feed.showsProblem, let problem = feed.problem, feed.aircraft.isEmpty {
            ProblemCard(problem: problem, openSettingsTab: openSettingsTab) {
                Task { await store.refreshGround() }
            }
        } else if !feed.hasLoaded {
            SkeletonList()
        } else if store.airport == nil {
            MessageCard(systemImage: "mappin.slash", title: String(localized: "No airport nearby"),
                        message: String(localized: "ScanUp shows the aircraft on the ground when you are within 40 km of an airport."))
        } else if feed.aircraft.isEmpty {
            MessageCard(systemImage: "moon.zzz",
                        title: usesBackupSource ? String(localized: "Limited data") : String(localized: "Quiet on the ground"),
                        message: usesBackupSource
                            ? String(localized: "The backup data source shows few aircraft on the ground, so this may be incomplete. Try again in a few minutes.")
                            : String(localized: "No aircraft are being tracked on the ground at this airport right now. Parked aircraft with their transponders off do not appear."))
        } else {
            AircraftList(aircraft: feed.aircraft, selection: $selectedID, interact: store.noteInteraction)
        }
    }
}
