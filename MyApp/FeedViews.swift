import SwiftUI

/// The line under a tab's title. It is one line in one style: a small icon, then the text. Normally the icon is a
/// pulsing green dot and the text says what was found. When the data is old, a refresh failed, refreshing paused, or
/// the first answer is on its way, the text says that instead, with a matching icon and colour.
struct StatusLine: View {
    /// What the line needs to know about a list.
    struct ListState: Equatable {
        var problem: FeedProblem?
        var hasLoaded: Bool
        var isLoading: Bool
        var updatedAt: Date?
        var count: Int
    }

    let summary: String
    let state: ListState
    let isPaused: Bool
    /// Time after a successful refresh at which the list counts as old.
    let staleAfter: Duration
    let resume: () -> Void
    let retry: () -> Void
    @State private var isStale = false

    /// The Overhead list, which refreshes every few seconds.
    init(summary: String, feed: Feed, isPaused: Bool, resume: @escaping () -> Void, retry: @escaping () -> Void) {
        self.init(summary: summary, state: ListState(problem: feed.problem, hasLoaded: feed.hasLoaded, isLoading: feed.isLoading,
                                                     updatedAt: feed.updatedAt, count: feed.aircraft.count),
                  isPaused: isPaused, staleAfter: .seconds(40), resume: resume, retry: retry)
    }

    /// The Airport board, which refreshes every ten minutes.
    init(summary: String, board: BoardFeed, isPaused: Bool, resume: @escaping () -> Void, retry: @escaping () -> Void) {
        self.init(summary: summary, state: ListState(problem: board.problem, hasLoaded: board.hasLoaded, isLoading: board.isLoading,
                                                     updatedAt: board.updatedAt, count: board.departures.count + board.arrivals.count),
                  isPaused: isPaused, staleAfter: .seconds(20 * 60), resume: resume, retry: retry)
    }

    init(summary: String, state: ListState, isPaused: Bool, staleAfter: Duration, resume: @escaping () -> Void,
         retry: @escaping () -> Void) {
        self.summary = summary
        self.state = state
        self.isPaused = isPaused
        self.staleAfter = staleAfter
        self.resume = resume
        self.retry = retry
    }

    private enum Mode {
        case paused, failed, updating, stale, live
    }

    private var mode: Mode? {
        if isPaused { return .paused }
        if state.problem != nil, state.hasLoaded { return .failed }
        if state.isLoading, !state.hasLoaded { return .updating }
        guard state.updatedAt != nil else { return nil }
        return isStale ? .stale : .live
    }

    var body: some View {
        content
            .font(.subheadline)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .id(mode)
            .transition(.opacity)
            .animation(.smooth, value: mode)
            .task(id: state.updatedAt) {
                isStale = false
                try? await Task.sleep(for: staleAfter)
                if !Task.isCancelled { isStale = true }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .paused:
            Button(action: resume) {
                line(Image(systemName: "pause.circle.fill"), tint: .secondary) { Text("Paused · tap to resume") }
            }
            .buttonStyle(.plain)
        case .failed:
            Button(action: retry) {
                line(Image(systemName: "exclamationmark.triangle.fill"), tint: Theme.warning) {
                    Text("Couldn’t refresh · tap to retry")
                }
            }
            .buttonStyle(.plain)
        case .updating:
            line(ProgressView().controlSize(.mini), tint: .secondary) { Text("Updating…") }
        case .stale:
            // The wording follows the clock without a timer ticking every second.
            line(Image(systemName: "clock.fill"), tint: Theme.warning) {
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text("Updated \(state.updatedAt?.formatted(.relative(presentation: .numeric, unitsStyle: .wide)) ?? "")")
                }
            }
        case .live:
            line(Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(Theme.positive)
                    .symbolEffect(.bounce, value: state.updatedAt), tint: .secondary) {
                Text(summary)
                    .contentTransition(.numericText())
                    .animation(.smooth, value: state.count)
            }
        case nil:
            Text(summary).foregroundStyle(.secondary)
        }
    }

    private func line(_ icon: some View, tint: Color, @ViewBuilder text: () -> some View) -> some View {
        HStack(spacing: 7) {
            icon
            text()
        }
        .foregroundStyle(tint)
    }
}

/// Shown while a fake location is in use, so a test is never mistaken for the real position.
struct TestLocationNotice: View {
    let place: TestLocation?

    var body: some View {
        Group {
            if let place {
                Label("Fake location: \(place.name)", systemImage: "location.slash.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.warning)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.snappy, value: place)
    }
}

/// A message with an icon, used for empty lists and for problems.
struct MessageCard: View {
    let systemImage: String
    let title: String
    let message: String
    var tint: Color = Theme.accent
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeating.speed(0.4))
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .cardBackground()
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

/// Grey cards that stand in for the list until the first answer arrives.
struct SkeletonList: View {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 14) {
                    Circle().frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).frame(width: 150, height: 14)
                        RoundedRectangle(cornerRadius: 4).frame(width: 100, height: 11)
                    }
                    Spacer()
                }
                .foregroundStyle(.secondary.opacity(0.25))
                .padding(14)
                .cardBackground()
            }
        }
        .phaseAnimator([0.5, 1.0]) { content, opacity in
            content.opacity(opacity)
        } animation: { _ in
            .easeInOut(duration: 0.9)
        }
        .accessibilityHidden(true)
    }
}

/// The problem a tab has, with the action that fixes it.
struct ProblemCard: View {
    let problem: FeedProblem
    /// What could not be loaded, for the failure message's title.
    var failureTitle = String(localized: "Couldn’t load aircraft")
    let openSettingsTab: () -> Void
    let retry: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch problem {
        case .notConfigured:
            MessageCard(systemImage: "server.rack", title: String(localized: "Connect to your server"),
                        message: String(localized: "Add the server address and access token in Settings to get started."),
                        actionTitle: String(localized: "Open Settings"), action: openSettingsTab)
        case .locationOff:
            MessageCard(systemImage: "location.slash", title: String(localized: "Location is off"),
                        message: String(localized: "ScanUp needs your location to find aircraft near you. It is only used while the app is open."),
                        tint: Theme.warning, actionTitle: String(localized: "Open iOS Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        case .locationApproximate:
            MessageCard(systemImage: "location.circle", title: String(localized: "Precise Location is off"),
                        message: String(localized: "ScanUp needs your exact position to tell what is overhead. Turn on Precise Location for ScanUp in iOS Settings."),
                        tint: Theme.warning, actionTitle: String(localized: "Open iOS Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        case .failed(let message):
            MessageCard(systemImage: "wifi.exclamationmark", title: failureTitle,
                        message: message, tint: Theme.warning,
                        actionTitle: String(localized: "Try again"), action: retry)
        }
    }
}

/// Cards for a list of aircraft, with one expanded at a time or several, as the reader chooses.
struct AircraftList: View {
    let aircraft: [Aircraft]
    /// The picked aircraft, shared with the radar. Picking one opens its card.
    @Binding var selection: String?
    /// Called when a card is tapped, so the app knows someone is using it.
    var interact: () -> Void = {}
    @State private var expanded: Set<String> = []

    var body: some View {
        LazyVStack(spacing: 12) {
            ForEach(aircraft) { item in
                AircraftCard(aircraft: item, isExpanded: expanded.contains(item.id), isSelected: selection == item.id) {
                    interact()
                    withAnimation(Theme.spring) {
                        if expanded.contains(item.id) {
                            expanded.remove(item.id)
                            if selection == item.id { selection = nil }
                        } else {
                            expanded.insert(item.id)
                            selection = item.id
                        }
                    }
                }
                .id(item.id)
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity.combined(with: .scale(scale: 0.92))))
            }
        }
        .onChange(of: selection) { _, picked in
            if let picked, !expanded.contains(picked) { withAnimation(Theme.spring) { _ = expanded.insert(picked) } }
        }
        .onChange(of: aircraft.map(\.id)) { _, ids in
            if let picked = selection, !ids.contains(picked) { selection = nil }
        }
        .animation(Theme.spring, value: aircraft.map(\.id))
    }
}
