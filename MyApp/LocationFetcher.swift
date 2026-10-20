import CoreLocation

/// Finds the phone's position once, when the app asks for it. Nothing runs in the background.
@MainActor @Observable
final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeout: Task<Void, Never>?
    private var latest: CLLocation?
    private var headingWanted = false

    private(set) var authorization: CLAuthorizationStatus
    /// The direction the phone points, in degrees clockwise from north. Smoothed, and not wrapped at 360, so a dial
    /// that follows it never spins backwards. Nil while the compass is off or cannot be read.
    private(set) var heading: Double?

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

    /// Starts the compass. True north needs location updates as well, because the difference between magnetic and true
    /// north depends on where you are (about 10 degrees in Finland). Both stop again with `stopHeading()`.
    func startHeading() {
        headingWanted = true
        guard CLLocationManager.headingAvailable() else { return }
        manager.headingFilter = 2
        manager.startUpdatingHeading()
        startLocationUpdates()
    }

    func stopHeading() {
        headingWanted = false
        manager.stopUpdatingHeading()
        // A fix that is being waited for would be cancelled too, so that stop waits for the answer.
        if continuation == nil { manager.stopUpdatingLocation() }
        heading = nil
    }

    private func startLocationUpdates() {
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else { return }
        manager.distanceFilter = 50
        manager.startUpdatingLocation()
    }

    func current() async throws -> CLLocation {
        try Task.checkCancellation()
        if let latest, latest.horizontalAccuracy <= 200, abs(latest.timestamp.timeIntervalSinceNow) <= 30 { return latest }
        if isDenied {
            throw ScanError.message(String(localized: "Location access is off. Allow it in Settings to see aircraft near you."))
        }
        // A request that is still waiting is replaced by this one.
        finish(.failure(CancellationError()))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled {
                    finish(.failure(CancellationError()))
                } else if manager.authorizationStatus == .notDetermined {
                    // The wait for a fix starts once the person has answered the permission prompt.
                    manager.requestWhenInUseAuthorization()
                } else {
                    requestFix()
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func requestFix() {
        timeout?.cancel()
        timeout = Task {
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            finish(.failure(ScanError.message(String(localized: "Could not find your location. Try again outdoors."))))
        }
        manager.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if headingWanted { startLocationUpdates() }
        guard continuation != nil else { return }
        switch authorization {
        case .authorizedAlways, .authorizedWhenInUse:
            requestFix()
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

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else {
            heading = nil
            return
        }
        // Until the first fix arrives only magnetic north is known.
        let reading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        heading = heading.map { Compass.smoothed(current: $0, toward: reading, factor: 0.4) } ?? reading
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(ScanError.message(String(localized: "Could not find your location. Try again outdoors."))))
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        timeout?.cancel()
        timeout = nil
        let pending = continuation
        continuation = nil
        if !headingWanted { manager.stopUpdatingLocation() }
        pending?.resume(with: result)
    }
}
