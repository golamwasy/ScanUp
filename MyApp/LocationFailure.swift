import CoreLocation

/// What to do with an error that Core Location reports while a position is being waited for.
nonisolated enum LocationFailure {
    enum Reaction: Equatable {
        /// Core Location says it is still trying. This happens when updates have just started, and indoors.
        case keepWaiting
        /// The compass could not be read. That has nothing to do with the position.
        case compassUnavailable
        case denied
        case fail
    }

    static func reaction(to error: Error) -> Reaction {
        switch (error as? CLError)?.code {
        case .locationUnknown: .keepWaiting
        case .headingFailure: .compassUnavailable
        case .denied: .denied
        default: .fail
        }
    }
}

/// Why no position could be found.
enum LocationError: LocalizedError {
    case denied, timedOut, unavailable

    var errorDescription: String? {
        switch self {
        case .denied:
            String(localized: "Location access is off. Allow it in Settings to see aircraft near you.")
        case .timedOut, .unavailable:
            String(localized: "Could not find your location. Try again outdoors.")
        }
    }
}
