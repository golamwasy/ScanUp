import SwiftUI

/// "Updated 5 s ago", or "Updating…" while a refresh runs, or a warning when the last one failed.
struct StatusPill: View {
    let feed: Feed

    var body: some View {
        Group {
            if feed.isLoading {
                Label {
                    Text("Updating…")
                } icon: {
                    ProgressView().controlSize(.mini)
                }
                .foregroundStyle(.secondary)
            } else if feed.problem != nil, feed.hasLoaded {
                Label("Couldn’t refresh", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            } else if let updatedAt = feed.updatedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label(Self.age(of: updatedAt, now: context.date), systemImage: "circle.fill")
                        .labelStyle(PillDotStyle())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .animation(.smooth, value: feed.isLoading)
        .animation(.smooth, value: feed.problem)
    }

    static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 5 { return String(localized: "Updated just now") }
        if seconds < 60 { return String(localized: "Updated \(seconds) s ago") }
        return String(localized: "Updated \(seconds / 60) min ago")
    }
}

private struct PillDotStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(Theme.positive)
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
    @State private var expanded: Set<String> = []

    var body: some View {
        LazyVStack(spacing: 12) {
            ForEach(aircraft) { item in
                AircraftCard(aircraft: item, isExpanded: expanded.contains(item.id)) {
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
