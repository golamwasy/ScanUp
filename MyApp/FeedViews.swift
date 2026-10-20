import SwiftUI

/// How current the list is. Quiet while the data is fresh ("Live"), and it speaks up only when the data is old,
/// a refresh failed, or refreshing paused.
struct StatusPill: View {
    let feed: Feed
    let isPaused: Bool
    let resume: () -> Void
    let retry: () -> Void
    /// Seconds after a successful refresh at which the list counts as old.
    private static let staleAfter: Duration = .seconds(40)
    @State private var isStale = false

    var body: some View {
        Group {
            if isPaused {
                Button(action: resume) {
                    Label("Paused to save data. Tap to resume", systemImage: "pause.circle")
                }
                .foregroundStyle(.secondary)
            } else if feed.problem != nil, feed.hasLoaded {
                Button(action: retry) {
                    Label("Couldn’t refresh. Tap to retry", systemImage: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(Theme.warning)
            } else if feed.isLoading, !feed.hasLoaded {
                Label {
                    Text("Updating…")
                } icon: {
                    ProgressView().controlSize(.mini)
                }
                .foregroundStyle(.secondary)
            } else if let updatedAt = feed.updatedAt {
                if isStale {
                    // The wording follows the clock without a timer ticking every second.
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        Label("Updated \(updatedAt.formatted(.relative(presentation: .numeric, unitsStyle: .wide)))",
                              systemImage: "clock")
                    }
                    .foregroundStyle(Theme.warning)
                } else {
                    Label("Live", systemImage: "circle.fill")
                        .labelStyle(PillDotStyle(pulse: updatedAt))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .animation(.smooth, value: isStale)
        .animation(.smooth, value: feed.isLoading)
        .animation(.smooth, value: feed.problem)
        .animation(.smooth, value: isPaused)
        .task(id: feed.updatedAt) {
            isStale = false
            try? await Task.sleep(for: Self.staleAfter)
            if !Task.isCancelled { isStale = true }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PillDotStyle: LabelStyle {
    /// The dot gives a small bounce each time the list is refreshed.
    let pulse: Date

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: 6))
                .foregroundStyle(Theme.positive)
                .symbolEffect(.bounce, value: pulse)
            configuration.title
        }
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
    let openSettingsTab: () -> Void
    let retry: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch problem {
        case .notConfigured:
            MessageCard(systemImage: "server.rack", title: String(localized: "Connect to your server"),
                        message: String(localized: "Add the server address and access token in Settings to see aircraft."),
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
            MessageCard(systemImage: "wifi.exclamationmark", title: String(localized: "Couldn’t load aircraft"),
                        message: message, tint: Theme.warning,
                        actionTitle: String(localized: "Try again"), action: retry)
        }
    }
}

/// Cards for a list of aircraft, with one expanded at a time or several, as the reader chooses.
struct AircraftList: View {
    let aircraft: [Aircraft]
    /// The direction the phone points, so each card's arrow shows which way to turn. Nil keeps the arrows north-up.
    var heading: Double?
    /// Called when a card is tapped, so the app knows someone is using it.
    var interact: () -> Void = {}
    @State private var expanded: Set<String> = []

    var body: some View {
        LazyVStack(spacing: 12) {
            ForEach(aircraft) { item in
                AircraftCard(aircraft: item, heading: heading, isExpanded: expanded.contains(item.id)) {
                    interact()
                    withAnimation(Theme.spring) {
                        if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity.combined(with: .scale(scale: 0.92))))
            }
        }
        .animation(Theme.spring, value: aircraft.map(\.id))
    }
}
