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

    /// Whether the problem takes the place of the list. A hiccup after a good answer does not: the list stays and
    /// the status line says the refresh failed. It takes over after a few failures in a row, when the list is old.
    var showsProblem: Bool {
        guard let problem else { return false }
        switch problem {
        case .notConfigured, .locationOff, .locationApproximate: return true
        case .failed: return !hasLoaded || failures >= Self.failuresBeforeProblem
        }
    }

    static let failuresBeforeProblem = 3
}
