import Foundation

/// What a tab shows when it cannot list aircraft.
enum FeedProblem: Equatable {
    case notConfigured
    case locationOff
    /// Precise Location is off, so positions are too rough.
    case locationApproximate
    case failed(String)
}

/// The aircraft of one tab, with the state of its latest refresh.
struct Feed {
    var aircraft: [Aircraft] = []
    var updatedAt: Date?
    var isLoading = false
    var problem: FeedProblem?
    /// Refreshes that failed in a row.
    var failures = 0
    var hasLoaded: Bool { updatedAt != nil }

    /// Whether the problem takes the place of the list (see `FeedProblem.takesOver`).
    var showsProblem: Bool { FeedProblem.takesOver(problem, hasLoaded: hasLoaded, failures: failures) }

    static let failuresBeforeProblem = 3
}

extension FeedProblem {
    /// Whether a problem takes the place of a list. A hiccup after a good answer does not: the list stays and the
    /// status line says the refresh failed. It takes over after a few failures in a row, when the list is old.
    /// Problems the person has to fix always do.
    static func takesOver(_ problem: FeedProblem?, hasLoaded: Bool, failures: Int) -> Bool {
        guard let problem else { return false }
        switch problem {
        case .notConfigured, .locationOff, .locationApproximate: return true
        case .failed: return !hasLoaded || failures >= Feed.failuresBeforeProblem
        }
    }
}

/// The Airport tab's board, with the state of its latest refresh.
struct BoardFeed {
    var airport: BoardAirport?
    var departures: [ScheduledFlight] = []
    var arrivals: [ScheduledFlight] = []
    /// When the server fetched the data (the older half of the board).
    var dataTime: Date?
    /// When the app got its last answer.
    var updatedAt: Date?
    var isLoading = false
    var problem: FeedProblem?
    var failures = 0
    /// Why the server's lists are old, short or empty.
    var notice: ScheduleNotice?

    var hasLoaded: Bool { updatedAt != nil }
    var showsProblem: Bool { FeedProblem.takesOver(problem, hasLoaded: hasLoaded, failures: failures) }

    func flights(_ direction: BoardDirection) -> [ScheduledFlight] {
        direction == .departures ? departures : arrivals
    }
}
