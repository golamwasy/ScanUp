import CoreLocation

/// Finds the phone's position for the app, and reads the compass. Both run only while the app is open.
@MainActor @Observable
final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    /// A position older than this is not used to answer a request, such as the cached one Core Location hands out
    /// first when updates start.
    private static let maxFixAge: TimeInterval = 60
    /// While updates are running, the system's last position is used as a last resort when no fresh one arrives.
    private static let maxFallbackAge: TimeInterval = 10 * 60

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeout: Task<Void, Never>?
    private var latest: CLLocation?
    private var updatesWanted = false
    /// The worst accuracy among positions that arrived but were too rough, to tell "Precise Location is off" apart
    /// from "no position at all".
    private var roughestRejectedAccuracy: CLLocationAccuracy = 0

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
        // Every update is wanted. A distance filter holds back new positions for a phone that stays still, which
        // left requests waiting for one that never came.
        manager.distanceFilter = kCLDistanceFilterNone
    }

    /// Asks for "While Using" access the first time. Does nothing once the user has answered.
    func requestAccessIfNeeded() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// Keeps the position warm while the app is open, so a refresh finds one at once. Stopping and starting it for
    /// every tab change made new requests fail while it was still getting going.
    func setUpdatesActive(_ active: Bool) {
        updatesWanted = active
        if active {
            startUpdatesIfPossible()
        } else if continuation == nil {
            manager.stopUpdatingLocation()
        }
    }

    /// The compass. True north needs location updates as well, because the difference between magnetic and true
    /// north depends on where you are (about 10 degrees in Finland).
    func setCompass(_ on: Bool) {
        if on {
            guard CLLocationManager.headingAvailable() else { return }
            manager.headingFilter = 2
            manager.startUpdatingHeading()
        } else {
            manager.stopUpdatingHeading()
            heading = nil
        }
    }

    private func startUpdatesIfPossible() {
        guard updatesWanted, authorization == .authorizedWhenInUse || authorization == .authorizedAlways else { return }
        manager.startUpdatingLocation()
    }

    func current() async throws -> CLLocation {
        try Task.checkCancellation()
        if let latest, latest.horizontalAccuracy <= 200, abs(latest.timestamp.timeIntervalSinceNow) <= 30 { return latest }
        if isDenied { throw LocationError.denied }
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

    /// Waits for a position in steps. With updates running the next one normally arrives within a second or two.
    /// After 3 seconds an explicit request is made as well, after 8 the system's last position is used if it is
    /// recent enough, and after 12 the wait ends with an error.
    private func requestFix() {
        timeout?.cancel()
        roughestRejectedAccuracy = 0
        let streaming = updatesWanted && manager.authorizationStatus != .notDetermined
        if !streaming { manager.requestLocation() }
        timeout = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            if streaming { manager.requestLocation() }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if let lastKnown = manager.location, streaming, Self.usable(lastKnown, maxAge: Self.maxFallbackAge) {
                latest = lastKnown
                finish(.success(lastKnown))
                return
            }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            finish(.failure(failureWhenNothingArrived))
        }
    }

    private var failureWhenNothingArrived: LocationError {
        manager.accuracyAuthorization == .reducedAccuracy || roughestRejectedAccuracy > 1000 ? .approximate : .timedOut
    }

    private static func usable(_ location: CLLocation, maxAge: TimeInterval) -> Bool {
        CLLocationCoordinate2DIsValid(location.coordinate)
            && location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 1000
            && abs(location.timestamp.timeIntervalSinceNow) <= maxAge
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        startUpdatesIfPossible()
        guard continuation != nil else { return }
        switch authorization {
        case .authorizedAlways, .authorizedWhenInUse:
            requestFix()
        case .denied, .restricted:
            finish(.failure(LocationError.denied))
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        if location.horizontalAccuracy > 1000 { roughestRejectedAccuracy = max(roughestRejectedAccuracy, location.horizontalAccuracy) }
        guard Self.usable(location, maxAge: Self.maxFixAge) else { return }
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
        switch LocationFailure.reaction(to: error) {
        case .keepWaiting:
            break
        case .compassUnavailable:
            heading = nil
        case .denied:
            finish(.failure(LocationError.denied))
        case .fail:
            finish(.failure(LocationError.unavailable))
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        timeout?.cancel()
        timeout = nil
        let pending = continuation
        continuation = nil
        if !updatesWanted { manager.stopUpdatingLocation() }
        pending?.resume(with: result)
    }
}
