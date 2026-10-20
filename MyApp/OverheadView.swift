import SwiftUI

struct OverheadView: View {
    let store: FlightStore
    let openSettingsTab: () -> Void

    private var feed: Feed { store.nearby }

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
            await store.refreshNearby()
        }
        .onScrollPhaseChange { _, _ in store.noteInteraction() }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        VStack(spacing: 14) {
            RadarView(aircraft: feed.aircraft, radiusMeters: store.radiusMeters,
                      updatedAt: feed.updatedAt, heading: store.location.heading)
                .frame(width: 200, height: 200)
                .padding(.top, 8)
            VStack(spacing: 4) {
                Text("Above you")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.smooth, value: feed.aircraft.count)
            }
            StatusPill(feed: feed, isPaused: store.isPaused, resume: store.noteInteraction) {
                Task { await store.refreshNearby() }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var summary: String {
        let radius = Format.distance(store.radiusMeters)
        guard feed.hasLoaded else { return String(localized: "Within \(radius) of you") }
        return feed.aircraft.isEmpty
            ? String(localized: "No aircraft within \(radius)")
            : String(localized: "\(feed.aircraft.count) within \(radius)")
    }

    @ViewBuilder
    private var content: some View {
        if let problem = feed.problem, feed.aircraft.isEmpty {
            ProblemCard(problem: problem, openSettingsTab: openSettingsTab) {
                Task { await store.refreshNearby() }
            }
        } else if !feed.hasLoaded {
            SkeletonList()
        } else if feed.aircraft.isEmpty {
            MessageCard(systemImage: "sun.max", title: String(localized: "Clear skies"),
                        message: String(localized: "Nothing is flying within \(Format.distance(store.radiusMeters)) of you right now. Widen the search area in Settings, or pull down to look again."))
        } else {
            AircraftList(aircraft: feed.aircraft, heading: store.location.heading, interact: store.noteInteraction)
        }
    }
}
