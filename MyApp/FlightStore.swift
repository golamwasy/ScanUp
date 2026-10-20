import CoreLocation
import Foundation

private enum StoreError: Error {
    case notConfigured
    case locationOff
}

enum ConnectionTest: Equatable {
    case idle, testing, success
    case failed(String)
}

@MainActor @Observable
final class FlightStore {
    static let radiusRange: ClosedRange<Double> = 1...10
    static let defaultRadiusKm = 3.0
    private static let radiusKey = "searchRadiusKm"
    /// Settings that earlier versions kept, from when ScanUp shared its location in the background.
    private static let retiredKeys = [
        "wideSearchRadiusEnabled", "quietHoursEnabled", "homeLatitude", "homeLongitude",
        "sleepAtHomeEnabled", "restingAtHome", "locationSharingEnabled", "locationSharingDeviceID",
        "locationSharingRevision",
    ]

    /// How long the app refreshes without a touch before it pauses to save the server's request budget.
    static let idleLimit: TimeInterval = 5 * 60
    private static let defaultInterval = 15.0
    private static let intervalRange = 10.0...120.0
    private static let longestBackOff = 60.0
    private static let longestServerWait = 300.0

    let location = LocationFetcher()
    private let client = BackendClient()
    @ObservationIgnored private var lastInteraction = Date()
    @ObservationIgnored private var nearbyFailures = 0
    @ObservationIgnored private var groundFailures = 0
    /// The refresh that is running, if any. A second call waits for it instead of starting another or being skipped,
    /// and it is not cancelled when the person changes tab, so its answer is not wasted.
    @ObservationIgnored private var nearbyTask: Task<Duration, Never>?
    @ObservationIgnored private var groundTask: Task<Duration, Never>?

    private(set) var configuration: BackendConfiguration?
    private(set) var isConfigurationLoaded = false
    private(set) var nearby = Feed()
    private(set) var ground = Feed()
    private(set) var airport: AirportInfo?
    /// Which data source answered the last airport refresh.
    private(set) var groundSource: String?
    private(set) var connectionTest = ConnectionTest.idle
    /// Auto-refresh stopped because nobody touched the app for a while. Any touch starts it again.
    private(set) var isPaused = false
    /// What is left of each data source's allowance, as the server last reported it.
    private(set) var usage: Usage?
    private(set) var isLoadingUsage = false
    private(set) var usageError: String?
    var settingsError: String?

    var radiusKm: Double = {
        let stored = UserDefaults.standard.double(forKey: radiusKey)
        return radiusRange.contains(stored) ? stored : defaultRadiusKm
    }() {
        didSet {
            UserDefaults.standard.set(radiusKm, forKey: Self.radiusKey)
            // The list on screen was found for another distance, so it is no longer an answer. Going back to
            // Overhead then loads the new one, with the header and radar already at the new distance.
            if radiusKm != oldValue {
                nearby = Feed()
                nearby.isLoading = nearbyTask != nil
            }
        }
    }

    var radiusMeters: Int { Int((radiusKm * 1000).rounded()) }

    private static let useTestLocationKey = "useTestLocation"
    private static let testLocationKey = "testLocationIndex"

    /// Use one of the fixed test places instead of the phone's position (see TestLocation).
    var useTestLocation = UserDefaults.standard.bool(forKey: useTestLocationKey) {
        didSet {
            UserDefaults.standard.set(useTestLocation, forKey: Self.useTestLocationKey)
            if useTestLocation != oldValue { positionSourceChanged() }
        }
    }

    var testLocationIndex = TestLocation.choice(UserDefaults.standard.integer(forKey: testLocationKey)).id {
        didSet {
            UserDefaults.standard.set(testLocationIndex, forKey: Self.testLocationKey)
            if testLocationIndex != oldValue, useTestLocation { positionSourceChanged() }
        }
    }

    /// The place being used instead of the real position, or nil for the real one.
    var testLocation: TestLocation? { useTestLocation ? TestLocation.choice(testLocationIndex) : nil }

    /// The lists on screen were found around another position, so they are no longer an answer. The refresh loop then
    /// loads the new ones.
    private func positionSourceChanged() {
        nearby = Feed()
        nearby.isLoading = nearbyTask != nil
        ground = Feed()
        ground.isLoading = groundTask != nil
        airport = nil
        groundSource = nil
        nearbyFailures = 0
        groundFailures = 0
    }
    var serverAddress: String { configuration?.baseURL.absoluteString ?? BackendConfiguration.suggestedURL }

    /// Loads the saved connection. Keychain can block while the phone restores protected data,
    /// so it stays off the main actor and out of the way of the first frame.
    func start() async {
        guard !isConfigurationLoaded else { return }
        for key in Self.retiredKeys { UserDefaults.standard.removeObject(forKey: key) }
        await Task.yield()
        let data = await Task.detached { BackendCredentialStore.loadData() }.value
        configuration = data.flatMap { try? JSONDecoder().decode(BackendConfiguration.self, from: $0) }
        isConfigurationLoaded = true
        location.requestAccessIfNeeded()
    }

    /// Refreshes the Overhead list. Returns how long to wait before the next refresh.
    @discardableResult
    func refreshNearby() async -> Duration {
        guard isConfigurationLoaded else { return Self.interval(nil) }
        if let running = nearbyTask { return await running.value }
        let task = Task { () -> Duration in
            let wait = await performNearby()
            nearbyTask = nil
            nearby.isLoading = false
            return wait
        }
        nearbyTask = task
        return await task.value
    }

    private func performNearby() async -> Duration {
        nearby.isLoading = true
        let requestedRadius = radiusMeters
        let requestedPlace = testLocation
        do {
            let (configuration, position) = try await prepare()
            let response = try await client.nearby(latitude: position.coordinate.latitude,
                                                   longitude: position.coordinate.longitude,
                                                   radiusMeters: requestedRadius, configuration: configuration)
            // The distance was changed while this was on its way, so the answer is for the wrong area. Ask again soon.
            guard requestedRadius == radiusMeters, requestedPlace == testLocation else { return .seconds(1) }
            nearby.aircraft = Self.unique(response.aircraft)
            nearby.updatedAt = Date()
            nearby.problem = nil
            nearby.failures = 0
            nearbyFailures = 0
            return Self.interval(response.refreshAfterS)
        } catch is CancellationError {
            return Self.interval(nil)
        } catch {
            nearby.problem = problem(for: error)
            let wait = Self.backOff(after: error, failures: &nearbyFailures)
            nearby.failures = nearbyFailures
            return wait
        }
    }

    /// Refreshes the Airport list. Returns how long to wait before the next refresh.
    @discardableResult
    func refreshGround() async -> Duration {
        guard isConfigurationLoaded else { return Self.interval(nil) }
        if let running = groundTask { return await running.value }
        let task = Task { () -> Duration in
            let wait = await performGround()
            groundTask = nil
            ground.isLoading = false
            return wait
        }
        groundTask = task
        return await task.value
    }

    private func performGround() async -> Duration {
        ground.isLoading = true
        let requestedPlace = testLocation
        do {
            let (configuration, position) = try await prepare()
            let response = try await client.airport(latitude: position.coordinate.latitude,
                                                    longitude: position.coordinate.longitude,
                                                    configuration: configuration)
            // The place was changed while this was on its way, so the answer is for the wrong position.
            guard requestedPlace == testLocation else { return .seconds(1) }
            airport = response.airport
            groundSource = response.source
            ground.aircraft = Self.unique(response.aircraft)
            ground.updatedAt = Date()
            ground.problem = nil
            ground.failures = 0
            groundFailures = 0
            return Self.interval(response.refreshAfterS)
        } catch is CancellationError {
            return Self.interval(nil)
        } catch {
            ground.problem = problem(for: error)
            let wait = Self.backOff(after: error, failures: &groundFailures)
            ground.failures = groundFailures
            return wait
        }
    }

    /// One entry per aircraft. A list with a repeated id would confuse the list view.
    private static func unique(_ aircraft: [Aircraft]) -> [Aircraft] {
        var seen = Set<String>()
        return aircraft.filter { seen.insert($0.id).inserted }
    }

    /// The wait the server asked for, kept within sensible limits.
    private static func interval(_ serverSeconds: Int?) -> Duration {
        .seconds(min(intervalRange.upperBound, max(intervalRange.lowerBound, Double(serverSeconds ?? Int(defaultInterval)))))
    }

    /// After a failure: 15, 30, then 60 seconds, or longer when the server said it needs longer. Problems the person
    /// fixes themselves (no server set up, location off) do not grow the wait, since fixing them restarts refreshing.
    private static func backOff(after error: Error, failures: inout Int) -> Duration {
        if case ScanError.wait(_, let seconds) = error {
            failures += 1
            return .seconds(min(longestServerWait, max(defaultInterval, seconds)))
        }
        if error is StoreError { return interval(nil) }
        if case LocationError.denied = error { return interval(nil) }
        if error is LocationError {
            // No position yet is usually over in seconds, so try again soon: 5, 10, then 15 seconds.
            failures += 1
            return .seconds(min(defaultInterval, 5 * Double(failures)))
        }
        // A network hiccup is usually over quickly, so the first retry comes after 5 seconds, then 15, 30 and 60.
        failures += 1
        return .seconds([5, 15, 30, longestBackOff][min(failures, 4) - 1])
    }

    /// A touch, scroll, tab change or return to the app. Starts auto-refresh again if it had paused.
    func noteInteraction() {
        lastInteraction = Date()
        if isPaused { isPaused = false }
    }

    /// Called after each refresh. Pauses when nobody has touched the app for `idleLimit`. True when it paused.
    func pauseIfIdle() -> Bool {
        guard Date().timeIntervalSince(lastInteraction) > Self.idleLimit else { return false }
        isPaused = true
        return true
    }

    private func prepare() async throws -> (BackendConfiguration, CLLocation) {
        guard let configuration else { throw StoreError.notConfigured }
        // A fake location needs neither the GPS nor the permission.
        if let testLocation { return (configuration, testLocation.position) }
        if location.isDenied { throw StoreError.locationOff }
        return (configuration, try await location.current())
    }

    private func problem(for error: Error) -> FeedProblem {
        switch error {
        case StoreError.notConfigured: .notConfigured
        case StoreError.locationOff, LocationError.denied: .locationOff
        case LocationError.approximate: .locationApproximate
        default: .failed(error.localizedDescription)
        }
    }

    func saveConnection(address: String, token: String) -> Bool {
        settingsError = nil
        do {
            let url = try BackendConfiguration.validatedURL(address)
            let sameServer = configuration?.baseURL.host == url.host && configuration?.baseURL.port == url.port
            // Leaving the token empty keeps the saved one, but only for the same server.
            let keptToken = sameServer ? configuration?.token : nil
            let connection = try BackendConfiguration(address: address,
                                                      token: token.isEmpty ? keptToken ?? "" : token)
            try BackendCredentialStore.save(connection)
            configuration = connection
            connectionTest = .idle
            nearby.problem = nil
            ground.problem = nil
            return true
        } catch {
            settingsError = error.localizedDescription
            return false
        }
    }

    /// Asks the server what is left of each allowance. Keeps the last answer if the server cannot be reached.
    func refreshUsage() async {
        guard let configuration, !isLoadingUsage else { return }
        isLoadingUsage = true
        defer { isLoadingUsage = false }
        do {
            usage = try await client.usage(configuration: configuration)
            usageError = nil
        } catch is CancellationError {
        } catch {
            usageError = error.localizedDescription
        }
    }

    func testConnection() async {
        guard let configuration else {
            connectionTest = .failed(String(localized: "Save the server address and token first."))
            return
        }
        connectionTest = .testing
        do {
            try await client.ping(configuration: configuration)
            connectionTest = .success
        } catch is CancellationError {
            connectionTest = .idle
        } catch {
            connectionTest = .failed(error.localizedDescription)
        }
    }
}
