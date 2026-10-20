import Foundation

/// What is left of each data source's request allowance (see the backend's API_CONTRACT.md).
struct Usage: Decodable, Equatable {
    struct AdsbLol: Decodable, Equatable {
        /// Requests made to ADSB.lol in the last 24 hours.
        let used: Int
        let dailyBudget: Int
        let remaining: Int
        /// The server counts its own requests from its last start, so this is when the count began.
        let countedSince: Date

        var fractionUsed: Double { min(1, Double(used) / Double(max(dailyBudget, 1))) }
        /// More than 70 % used: the server then asks the app to refresh less often.
        var isRunningLow: Bool { fractionUsed > 0.7 }
    }

    struct OpenSky: Decodable, Equatable {
        let enabled: Bool
        let creditsRemaining: Int?
        let checkedAt: Date?
    }

    let adsbLol: AdsbLol
    let opensky: OpenSky
}
