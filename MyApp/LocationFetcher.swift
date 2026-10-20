import CoreLocation

/// Finds the phone's position once, when the app asks for it. Nothing runs in the background.
@MainActor @Observable
final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeout: Task<Void, Never>?
    private var latest: CLLocation?

    private(set) var authorization: CLAuthorizationStatus

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Asks for "While Using" access the first time. Does nothing once the user has answered.
    func requestAccessIfNeeded() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func current() async throws -> CLLocation {
        try Task.checkCancellation()
        if let latest, abs(latest.timestamp.timeIntervalSinceNow) <= 15 { return latest }
        if isDenied {
            throw ScanError.message(String(localized: "Location access is off. Allow it in Settings to see aircraft near you."))
        }
        // A request that is still waiting is replaced by this one.
        finish(.failure(CancellationError()))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task {
                    try? await Task.sleep(for: .seconds(12))
                    guard !Task.isCancelled else { return }
                    finish(.failure(ScanError.message(String(localized: "Could not find your location. Try again outdoors."))))
                }
                if Task.isCancelled {
                    finish(.failure(CancellationError()))
                } else if manager.authorizationStatus == .notDetermined {
                    manager.requestWhenInUseAuthorization()
                } else {
                    manager.requestLocation()
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        guard continuation != nil else { return }
        switch authorization {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(ScanError.message(String(localized: "Location access is off. Allow it in Settings to see aircraft near you."))))
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last,
              CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 1000 else { return }
        latest = location
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(ScanError.message(String(localized: "Could not find your location. Try again outdoors."))))
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        timeout?.cancel()
        timeout = nil
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
