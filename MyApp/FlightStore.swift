import CoreLocation
import Foundation

private enum StoreError: LocalizedError {
    case notConfigured
    case locationOff

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "Add the server address and access token in Settings first.")
        case .locationOff: String(localized: "Location access is off. Allow it in Settings to see aircraft near you.")
        }
    }
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
    /// Boards change slowly and cost units of a small allowance, so they refresh every few minutes at most.
    private static let boardIntervalRange = 60.0...1800.0
    private static let defaultBoardInterval = 1200.0

    let location = LocationFetcher()
    private let client = BackendClient()
    @ObservationIgnored private var lastInteraction = Date()
    @ObservationIgnored private var nearbyFailures = 0
    @ObservationIgnored private var boardFailures = 0
    /// Seconds the server asked the app to wait between board refreshes.
    @ObservationIgnored private var boardEvery = 1200.0
    /// The refresh that is running, if any. A second call waits for it instead of starting another or being skipped,
    /// and it is not cancelled when the person changes tab, so its answer is not wasted.
    @ObservationIgnored private var nearbyTask: Task<Duration, Never>?
    @ObservationIgnored private var boardTask: Task<Duration, Never>?

    private(set) var configuration: BackendConfiguration?
    private(set) var isConfigurationLoaded = false
    private(set) var nearby = Feed()
    private(set) var board = BoardFeed()
    /// The airport picked in the search, or nil for the nearest one. Not saved: the app opens on the nearest airport.
    private(set) var chosenAirport: Place?
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
        nearbyFailures = 0
        // A picked airport does not depend on the position; the nearest one does.
        if chosenAirport == nil { resetBoard() }
    }

    private func resetBoard() {
        board = BoardFeed()
        board.isLoading = boardTask != nil
        boardFailures = 0
    }

    /// Shows the board of another airport, or of the nearest one again (nil). The refresh loop loads it at once.
    func chooseAirport(_ place: Place?) {
        guard place != chosenAirport else { return }
        chosenAirport = place
        resetBoard()
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
            guard requestedRadius == radiusMeters, requestedPlace == testLocation else { return .seconds(1) }
            nearby.problem = problem(for: error)
            let wait = Self.backOff(after: error, failures: &nearbyFailures)
            nearby.failures = nearbyFailures
            return wait
        }
    }

    /// Refreshes the Airport board. Returns how long to wait before the next refresh.
    @discardableResult
    func refreshBoard(force: Bool = false) async -> Duration {
        guard isConfigurationLoaded else { return Self.boardInterval(nil) }
        // A board that is still fresh is not asked for again (opening the tab again, or the loop starting over).
        if !force, board.problem == nil, let updated = board.updatedAt {
            let left = boardEvery - Date().timeIntervalSince(updated)
            if left > 1 { return .seconds(left) }
        }
        if let running = boardTask { return await running.value }
        let task = Task { () -> Duration in
            let wait = await performBoard()
            boardTask = nil
            board.isLoading = false
            return wait
        }
        boardTask = task
        return await task.value
    }

    private func performBoard() async -> Duration {
        board.isLoading = true
        let requestedAirport = chosenAirport
        let requestedPlace = testLocation
        do {
            let request: BoardRequest
            let configuration: BackendConfiguration
            if let requestedAirport, let code = requestedAirport.icao ?? requestedAirport.iata {
                guard let saved = self.configuration else { throw StoreError.notConfigured }
                (configuration, request) = (saved, BoardRequest(code: code, latitude: nil, longitude: nil, part: "coming"))
            } else {
                let (saved, position) = try await prepare()
                (configuration, request) = (saved, BoardRequest(code: nil, latitude: position.coordinate.latitude,
                                                                longitude: position.coordinate.longitude, part: "coming"))
            }
            let response = try await client.board(request, configuration: configuration)
            // Another airport or position was picked while this was on its way, so it is the wrong board.
            guard requestedAirport == chosenAirport, requestedPlace == testLocation else { return .seconds(1) }
            board.airport = response.airport
            board.setComing(departures: Self.unique(response.departures), arrivals: Self.unique(response.arrivals))
            board.dataTime = response.updatedAt
            board.updatedAt = Date()
            board.notice = response.notice.flatMap(ScheduleNotice.init(rawValue:))
            board.problem = nil
            board.failures = 0
            boardFailures = 0
            let wait = Self.boardInterval(response.refreshAfterS)
            boardEvery = Double(wait.components.seconds)
            return wait
        } catch is CancellationError {
            return Self.boardInterval(nil)
        } catch {
            // A failure of a request that is no longer wanted (another airport was picked) says nothing about this one.
            guard requestedAirport == chosenAirport, requestedPlace == testLocation else { return .seconds(1) }
            board.problem = problem(for: error)
            let wait = Self.backOff(after: error, failures: &boardFailures)
            board.failures = boardFailures
            return wait
        }
    }

    /// Fetches the 12 hours before now for the board on screen, once: they barely change, so they are not refreshed.
    /// Costs 2 schedule units the first time (the server keeps them for an hour).
    func loadEarlierBoard() async {
        guard board.airport != nil, !board.pastLoaded, !board.isLoadingPast else { return }
        let requestedAirport = chosenAirport
        let requestedPlace = testLocation
        board.isLoadingPast = true
        board.pastProblem = nil
        defer { if requestedAirport == chosenAirport, requestedPlace == testLocation { board.isLoadingPast = false } }
        do {
            let request: BoardRequest
            let configuration: BackendConfiguration
            if let code = board.airport?.icao {
                guard let saved = self.configuration else { throw StoreError.notConfigured }
                (configuration, request) = (saved, BoardRequest(code: code, latitude: nil, longitude: nil, part: "past"))
            } else {
                return
            }
            let response = try await client.board(request, configuration: configuration)
            guard requestedAirport == chosenAirport, requestedPlace == testLocation else { return }
            board.setPast(departures: Self.unique(response.departures), arrivals: Self.unique(response.arrivals))
        } catch is CancellationError {
        } catch {
            guard requestedAirport == chosenAirport, requestedPlace == testLocation else { return }
            board.pastProblem = error.localizedDescription
        }
    }

    /// The aircraft heard right now under a flight number, callsign or registration, with distance and direction from here.
    func track(query: String) async throws -> [Aircraft] {
        let (configuration, position) = try await prepare()
        let response = try await client.track(query: query, latitude: position.coordinate.latitude,
                                              longitude: position.coordinate.longitude, configuration: configuration)
        return Self.unique(response.aircraft)
    }

    /// Airports for a code, a city or a name. Free.
    func searchAirports(_ query: String) async throws -> [Place] {
        guard let configuration else { throw StoreError.notConfigured }
        return try await client.searchAirports(query, configuration: configuration)
    }

    /// One entry per id. A list with a repeated id would confuse the list view.
    private static func unique<Item: Identifiable>(_ items: [Item]) -> [Item] where Item.ID == String {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// The wait the server asked for between board refreshes, kept within sensible limits.
    private static func boardInterval(_ serverSeconds: Int?) -> Duration {
        .seconds(min(boardIntervalRange.upperBound,
                     max(boardIntervalRange.lowerBound, Double(serverSeconds ?? Int(defaultBoardInterval)))))
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

    func problem(for error: Error) -> FeedProblem {
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
            board.problem = nil
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
