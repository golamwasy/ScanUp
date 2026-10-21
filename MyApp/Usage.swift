import Foundation

/// What is left of each data source's request allowance (see the backend's API_CONTRACT.md).
struct Usage: Decodable, Equatable {
    struct AdsbLol: Decodable, Equatable {
        /// Requests made to ADSB.lol in the last 24 hours.
        let used: Int
        let dailyBudget: Int
        let remaining: Int
        /// When the server began counting its requests, so earlier ones are not in the number.
        let countedSince: Date
        /// When the oldest counted request turns 24 hours old and stops counting, so the number goes down by one.
        /// Absent when nothing is counted.
        let nextFreeAt: Date?

        var fractionUsed: Double { min(1, Double(used) / Double(max(dailyBudget, 1))) }
        /// More than 70 % used: the server then asks the app to refresh less often.
        var isRunningLow: Bool { fractionUsed > 0.7 }
    }

    struct OpenSky: Decodable, Equatable {
        let enabled: Bool
        let creditsRemaining: Int?
        let checkedAt: Date?
    }

    /// The flight schedule service (airport boards and flight search): units left this month.
    struct FlightSchedules: Decodable, Equatable {
        let enabled: Bool
        /// What the service last said is left this month, or the server's estimate before its first answer.
        let remaining: Int?
        let monthlyLimit: Int?
        /// When the service's month starts again. Absent until the service has answered once.
        let resetsAt: Date?
        let usedLast30Days: Int

        var fractionUsed: Double {
            guard let remaining, let monthlyLimit, monthlyLimit > 0 else { return 0 }
            return min(1, max(0, Double(monthlyLimit - remaining) / Double(monthlyLimit)))
        }
        /// Less than a fifth left.
        var isRunningLow: Bool { fractionUsed > 0.8 }
    }

    let adsbLol: AdsbLol
    let opensky: OpenSky
    /// Absent from servers older than the schedule features.
    let flightSchedules: FlightSchedules?
}
