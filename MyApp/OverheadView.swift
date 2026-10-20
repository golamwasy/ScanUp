import SwiftUI

struct OverheadView: View {
    let store: FlightStore
    let openSettingsTab: () -> Void

    private var feed: Feed { store.nearby }
    @State private var selectedID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    header(proxy)
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
            .sensoryFeedback(.selection, trigger: selectedID)
        }
    }

    /// A tap on a plane picks it and brings its card into view. A second tap lets go of it.
    private func pick(_ id: String, proxy: ScrollViewProxy) {
        store.noteInteraction()
        if selectedID == id {
            selectedID = nil
            return
        }
        selectedID = id
        withAnimation(Theme.spring) { proxy.scrollTo(id, anchor: .center) }
    }

    private func header(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 10) {
            RadarView(aircraft: feed.aircraft, radiusMeters: store.radiusMeters,
                      updatedAt: feed.updatedAt, heading: store.location.heading,
                      selectedID: selectedID) { pick($0, proxy: proxy) }
                .frame(width: 236, height: 236)
                .padding(.top, 4)
            VStack(spacing: 8) {
                Text("Above you")
                    .font(.system(.title, design: .rounded, weight: .bold))
                StatusLine(summary: summary, feed: feed, isPaused: store.isPaused, resume: store.noteInteraction) {
                    Task { await store.refreshNearby() }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var summary: String {
        let radius = Format.distance(store.radiusMeters)
        guard feed.hasLoaded else { return String(localized: "Within \(radius)") }
        return feed.aircraft.isEmpty
            ? String(localized: "No aircraft within \(radius)")
            : String(localized: "\(feed.aircraft.count) aircraft · \(radius)")
    }

    @ViewBuilder
    private var content: some View {
        if feed.showsProblem, let problem = feed.problem, feed.aircraft.isEmpty {
            ProblemCard(problem: problem, openSettingsTab: openSettingsTab) {
                Task { await store.refreshNearby() }
            }
        } else if !feed.hasLoaded {
            SkeletonList()
        } else if feed.aircraft.isEmpty {
            MessageCard(systemImage: "sun.max", title: String(localized: "Clear skies"),
                        message: String(localized: "Nothing is flying within \(Format.distance(store.radiusMeters)) of you right now. Widen the search area in Settings, or pull down to look again."))
        } else {
            AircraftList(aircraft: feed.aircraft, selection: $selectedID, interact: store.noteInteraction)
        }
    }
}
