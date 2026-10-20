import CoreLocation
import Foundation

/// What a tab shows when it cannot list aircraft.
enum FeedProblem: Equatable {
    case notConfigured
    case locationOff
    case failed(String)
}

private enum StoreError: Error {
    case notConfigured
    case locationOff
}

/// The aircraft of one tab, with the state of its latest refresh.
struct Feed {
    var aircraft: [Aircraft] = []
    var updatedAt: Date?
    var isLoading = false
    var problem: FeedProblem?
    var hasLoaded: Bool { updatedAt != nil }
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
    var settingsMessage: String?
    var settingsError: String?

    var radiusKm: Double = {
        let stored = UserDefaults.standard.double(forKey: radiusKey)
        return radiusRange.contains(stored) ? stored : defaultRadiusKm
    }() {
        didSet { UserDefaults.standard.set(radiusKm, forKey: Self.radiusKey) }
    }

    var radiusMeters: Int { Int((radiusKm * 1000).rounded()) }
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
        guard isConfigurationLoaded, !nearby.isLoading else { return Self.interval(nil) }
        nearby.isLoading = true
        defer { nearby.isLoading = false }
        do {
            let (configuration, position) = try await prepare()
            let response = try await client.nearby(latitude: position.coordinate.latitude,
                                                   longitude: position.coordinate.longitude,
                                                   radiusMeters: radiusMeters, configuration: configuration)
            nearby.aircraft = response.aircraft
            nearby.updatedAt = Date()
            nearby.problem = nil
            nearbyFailures = 0
            return Self.interval(response.refreshAfterS)
        } catch is CancellationError {
            return Self.interval(nil)
        } catch {
            nearby.problem = problem(for: error)
            return Self.backOff(after: error, failures: &nearbyFailures)
        }
    }

    /// Refreshes the Airport list. Returns how long to wait before the next refresh.
    @discardableResult
    func refreshGround() async -> Duration {
        guard isConfigurationLoaded, !ground.isLoading else { return Self.interval(nil) }
        ground.isLoading = true
        defer { ground.isLoading = false }
        do {
            let (configuration, position) = try await prepare()
            let response = try await client.airport(latitude: position.coordinate.latitude,
                                                    longitude: position.coordinate.longitude,
                                                    configuration: configuration)
            airport = response.airport
            groundSource = response.source
            ground.aircraft = response.aircraft
            ground.updatedAt = Date()
            ground.problem = nil
            groundFailures = 0
            return Self.interval(response.refreshAfterS)
        } catch is CancellationError {
            return Self.interval(nil)
        } catch {
            ground.problem = problem(for: error)
            return Self.backOff(after: error, failures: &groundFailures)
        }
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
        failures += 1
        return .seconds(min(longestBackOff, defaultInterval * pow(2, Double(failures - 1))))
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
        if location.isDenied { throw StoreError.locationOff }
        return (configuration, try await location.current())
    }

    private func problem(for error: Error) -> FeedProblem {
        switch error {
        case StoreError.notConfigured: .notConfigured
        case StoreError.locationOff: .locationOff
        default: .failed(error.localizedDescription)
        }
    }

    func saveConnection(address: String, token: String) -> Bool {
        settingsMessage = nil
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
            settingsMessage = String(localized: "Saved securely on this iPhone.")
            return true
        } catch {
            settingsError = error.localizedDescription
            return false
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
