import Foundation
import Observation
import CoreLocation
import BackgroundTasks
import UIKit

@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeout: Task<Void, Never>?
    private var latestLocation: CLLocation?
    private var continuousRequested = false
    private(set) var isTracking = false

    private static let homeRegionIdentifier = "scanup.home"
    private var movementWakeUpActive = false

    /// iOS reports leaving the home circle, even if it had to relaunch the app to do so.
    var homeExitHandler: (() -> Void)?
    /// Every position that arrives, however coarse. Used to notice a move while the app rests.
    var movementHandler: ((CLLocation) -> Void)?
    var authorizationChanged: (() -> Void)?
    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var hasAlwaysAccess: Bool { manager.authorizationStatus == .authorizedAlways }

    func setContinuousTracking(_ active: Bool) {
        continuousRequested = active
        let authorized = manager.authorizationStatus == .authorizedAlways
            || manager.authorizationStatus == .authorizedWhenInUse
        guard active, authorized, !MonitoringHours.isQuiet() else {
            latestLocation = nil
            if isTracking {
                isTracking = false
                manager.stopUpdatingLocation()
            }
            if !active {
                finish(.failure(CancellationError()))
            }
            return
        }
        manager.allowsBackgroundLocationUpdates = hasAlwaysAccess
        guard !isTracking else { return }
        // Keep the backend supplied with fresh positions, including when stationary.
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        manager.distanceFilter = kCLDistanceFilterNone
        isTracking = true
        manager.startUpdatingLocation()
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Resting needs iOS to wake the app later, which only works with Always access.
    var canWatchHome: Bool {
        hasAlwaysAccess && CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
    }

    /// With `verifyState`, also ask iOS whether you are inside right now. That catches an exit that happened
    /// while the app was not running, such as with the phone off.
    func startWatchingHome(_ home: HomePayload, verifyState: Bool = false) {
        let center = CLLocationCoordinate2D(latitude: home.latitude, longitude: home.longitude)
        let radius = min(HomeGeofence.radius, manager.maximumRegionMonitoringDistance)
        // Keep an existing circle. Replacing it could throw away the exit event that just woke the app.
        if let existing = manager.monitoredRegions.first(where: { $0.identifier == Self.homeRegionIdentifier })
            as? CLCircularRegion,
           abs(existing.center.latitude - center.latitude) < 1e-7,
           abs(existing.center.longitude - center.longitude) < 1e-7,
           existing.radius == radius {
            if verifyState { manager.requestState(for: existing) }
            return
        }
        stopWatchingHome()
        let region = CLCircularRegion(center: center, radius: radius, identifier: Self.homeRegionIdentifier)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        if verifyState { manager.requestState(for: region) }
    }

    func stopWatchingHome() {
        for region in manager.monitoredRegions where region.identifier == Self.homeRegionIdentifier {
            manager.stopMonitoring(for: region)
        }
    }

    /// A cheap safety net: iOS relaunches a closed app after a large move (a few hundred metres).
    func setMovementWakeUp(_ active: Bool) {
        let wanted = active && hasAlwaysAccess && CLLocationManager.significantLocationChangeMonitoringAvailable()
        guard wanted != movementWakeUpActive else { return }
        movementWakeUpActive = wanted
        if wanted {
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
        }
    }

    func requestAlways() {
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        } else {
            manager.requestWhenInUseAuthorization()
        }
    }

    func current(background: Bool) async throws -> CLLocation {
        try Task.checkCancellation()
        try MonitoringHours.requireActiveHours()
        if background && manager.authorizationStatus != .authorizedAlways {
            throw ScanError.message("Background sharing needs Always location access. Enable it in Settings.")
        }
        if let latestLocation, abs(latestLocation.timestamp.timeIntervalSinceNow) <= 20 {
            return latestLocation
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    finish(.failure(ScanError.message("Location timed out. Try again outdoors.")))
                }
                if Task.isCancelled {
                    finish(.failure(CancellationError()))
                } else if manager.authorizationStatus == .notDetermined {
                    manager.requestWhenInUseAuthorization()
                } else {
                    requestIfAuthorized()
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func requestIfAuthorized() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if !isTracking { manager.requestLocation() }
        case .denied, .restricted:
            finish(.failure(ScanError.message("Location access is disabled. Enable it in Settings.")))
        default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        setContinuousTracking(continuousRequested)
        if continuation != nil { requestIfAuthorized() }
        authorizationChanged?()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !MonitoringHours.isQuiet() else {
            setContinuousTracking(false)
            return
        }
        if let coarse = locations.last { movementHandler?(coarse) }
        guard let location = locations.last,
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100,
              abs(location.timestamp.timeIntervalSinceNow) <= 20 else { return }
        latestLocation = location
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier == Self.homeRegionIdentifier, state == .outside else { return }
        homeExitHandler?()
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.homeRegionIdentifier else { return }
        homeExitHandler?()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        timeout?.cancel()
        timeout = nil
        if !isTracking { manager.stopUpdatingLocation() }
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

@MainActor @Observable
final class ScanMonitor {
    static let shared = ScanMonitor()
    static let refreshIdentifier = "app.scanup.refresh"
    private static let restingKey = "restingAtHome"
    /// While resting, refresh the backend's 48 hour lease whenever the app is awake and this much time passed.
    private static let checkInInterval: TimeInterval = 6 * 3600

    private(set) var isSharing = false
    private(set) var hasConfiguration = false
    private(set) var serverAddress = BackendConfiguration.suggestedURL
    private(set) var status: LocalizedStringResource = "Set up your backend connection to begin."
    private(set) var errorMessage: String?
    private(set) var settingsMessage: LocalizedStringResource?
    private(set) var settingsError: String?
    private(set) var permission: LocalizedStringResource = "Location permission has not been requested."
    private(set) var backgroundStatus: LocalizedStringResource = "Background location is inactive."
    private(set) var isQuietHours = MonitoringHours.isQuiet()
    private(set) var respectsQuietHours = MonitoringHours.respectsQuietHours
    private(set) var wideSearch = SearchRadius.isWide
    private(set) var home = HomeStore.current
    /// At home with GPS off. iOS wakes the app when you leave, and the backend watches home meanwhile.
    private(set) var isResting = false
    private(set) var sleepsAtHome = UserDefaults.standard.object(forKey: "sleepAtHomeEnabled") as? Bool ?? true
    private(set) var isSettingHome = false
    private(set) var homeMessage: String?
    private(set) var lastUpload: Date?
    private(set) var lastLocation: CLLocation?
    private(set) var telegramReady = false
    private(set) var nextAttempt = Date.distantPast

    var isBusy: Bool { operation != nil }

    private var configuration: BackendConfiguration?
    private let deviceID: UUID
    @ObservationIgnored private lazy var location = LocationProvider()
    private let client = BackendClient()
    private var isPrepared = false
    private var loop: Task<Void, Never>?
    private var operation: Task<Bool, Never>?
    private var generation = UUID()
    private var isForeground = true
    private var failures = 0

    init() {
        if let storedID = UserDefaults.standard.string(forKey: "locationSharingDeviceID"),
           let id = UUID(uuidString: storedID) {
            deviceID = id
        } else {
            let id = UUID()
            deviceID = id
            UserDefaults.standard.set(id.uuidString, forKey: "locationSharingDeviceID")
        }
    }

    func prepare() async {
        guard !isPrepared else { return }
        isPrepared = true

        // Keychain and Core Location can block while the phone restores protected state.
        // Defer both until SwiftUI has committed its first frame, and keep Keychain off
        // the main actor so launch never remains on a black screen.
        await Task.yield()
        let savedData = await Task.detached {
            BackendCredentialStore.loadData()
        }.value
        let savedConfiguration = savedData.flatMap {
            try? JSONDecoder().decode(BackendConfiguration.self, from: $0)
        }

        configuration = savedConfiguration
        hasConfiguration = savedConfiguration != nil
        serverAddress = savedConfiguration?.baseURL.absoluteString ?? BackendConfiguration.suggestedURL
        isSharing = savedConfiguration != nil && UserDefaults.standard.bool(forKey: "locationSharingEnabled")
        if savedConfiguration != nil {
            status = "Connection saved. Start sharing when your backend is ready."
        }
        // Set the handlers and restore the resting state in one step, with no await in between,
        // because iOS can deliver the event that relaunched the app straight after the manager exists.
        location.authorizationChanged = { [weak self] in self?.refreshTracking() }
        location.homeExitHandler = { [weak self] in self?.leaveRest() }
        location.movementHandler = { [weak self] position in self?.handleMovement(position) }
        if isSharing, sleepsAtHome, let home, UserDefaults.standard.bool(forKey: Self.restingKey) {
            isResting = true
            location.startWatchingHome(home, verifyState: true)
            status = "At home. Location is paused to save battery. Your backend is watching your home."
        }
        refreshTracking()
    }

    func saveConnection(address: String, token: String) -> Bool {
        settingsMessage = nil
        settingsError = nil
        guard !isSharing, !isBusy else {
            settingsError = String(localized: "Pause sharing before changing the connection.")
            return false
        }
        do {
            let url = try BackendConfiguration.validatedURL(address)
            let savedToken = configuration?.baseURL.host == url.host
                && configuration?.baseURL.port == url.port ? configuration?.token : nil
            let connection = try BackendConfiguration(address: address,
                token: token.isEmpty ? savedToken ?? "" : token)
            try BackendCredentialStore.save(connection)
            configuration = connection
            hasConfiguration = true
            serverAddress = connection.baseURL.absoluteString
            lastUpload = nil
            lastLocation = nil
            telegramReady = false
            errorMessage = nil
            nextAttempt = .distantPast
            failures = 0
            settingsMessage = "Saved securely on this iPhone. The connection has not been verified yet."
            status = "Connection saved. Start sharing when your backend is ready."
            return true
        } catch {
            settingsError = error.localizedDescription
            return false
        }
    }

    func requestAlways() {
        location.requestAlways()
    }

    /// Saves where the phone is now as home. The backend keeps watching it when the phone goes quiet.
    func setHomeHere() async {
        guard !isSettingHome else { return }
        homeMessage = nil
        guard !MonitoringHours.isQuiet() else {
            homeMessage = String(localized: "Location is off during quiet hours. Save your home after 09:00 Finnish time.")
            return
        }
        isSettingHome = true
        defer { isSettingHome = false }
        do {
            let position = try await location.current(background: false)
            let fix = try LocationPayload(location: position)
            let place = HomePayload(latitude: fix.latitude, longitude: fix.longitude)
            HomeStore.save(place)
            home = place
            homeMessage = String(localized: "Home saved. Your backend receives it with the next update.")
            leaveRest(message: "Home changed. Checking your location again.")
            sendSoon()
        } catch {
            homeMessage = error.localizedDescription
        }
    }

    func clearHome() {
        HomeStore.clear()
        home = nil
        homeMessage = String(localized: "Home removed. Your backend learns this with the next update.")
        leaveRest(message: "Home removed. Sharing your location continuously.")
        sendSoon()
    }

    func setSleepsAtHome(_ value: Bool) {
        guard value != sleepsAtHome else { return }
        UserDefaults.standard.set(value, forKey: "sleepAtHomeEnabled")
        sleepsAtHome = value
        if !value, isResting { leaveRest(message: "Sleep at home is off. Sharing your location continuously.") }
    }

    /// Only rest when iOS can wake the app later, the backend can see home, and the fix is clearly at home.
    private func shouldRest(at position: CLLocation) -> Bool {
        guard sleepsAtHome, let home, location.canWatchHome, !MonitoringHours.isQuiet() else { return false }
        return HomeStore.distance(from: position, to: home) <= HomeGeofence.restDistance
    }

    private func enterRest() {
        guard let home, !isResting else { return }
        isResting = true
        UserDefaults.standard.set(true, forKey: Self.restingKey)
        location.startWatchingHome(home)
        refreshTracking()
        status = "At home. Location is paused to save battery. Your backend is watching your home."
    }

    /// Stop resting without restarting the sharing loop, for when sharing itself is paused.
    private func clearResting() {
        guard isResting else { return }
        isResting = false
        UserDefaults.standard.set(false, forKey: Self.restingKey)
        location.stopWatchingHome()
    }

    func leaveRest(message: LocalizedStringResource = "You left home. Sharing your location again.") {
        guard isResting else { return }
        clearResting()
        nextAttempt = .distantPast
        failures = 0
        status = message
        if isSharing {
            resume(inForeground: isForeground)
        } else {
            refreshTracking()
        }
    }

    private func handleMovement(_ position: CLLocation) {
        guard isResting, let home else { return }
        // A coarse position can be wrong, but resuming is cheap and the next fix at home rests again.
        if HomeStore.distance(from: position, to: home) > HomeGeofence.leaveDistance { leaveRest() }
    }

    private var checkInDue: Bool {
        lastUpload.map { Date().timeIntervalSince($0) > Self.checkInInterval } ?? true
    }

    /// While resting, send a fresh "still at home" update now and then so the backend's lease stays valid.
    func checkInIfDue() async {
        guard isResting, checkInDue else { return }
        await shareNow(manual: true)
    }

    /// Settings travel with the location upload, so make the next upload happen right away.
    private func sendSoon() {
        guard isSharing, hasConfiguration, !isQuietHours else { return }
        nextAttempt = .distantPast
        failures = 0
    }

    /// 1 km by default, 10 km when on. The backend receives the new radius with the next upload.
    func setWideSearch(_ value: Bool) {
        guard value != wideSearch else { return }
        UserDefaults.standard.set(value, forKey: SearchRadius.wideKey)
        wideSearch = value
        errorMessage = nil
        guard isSharing, hasConfiguration, !isQuietHours else { return }
        // Send the new radius right away instead of waiting for the next 15 second slot.
        nextAttempt = .distantPast
        failures = 0
        status = value ? "Searching within 10 km. Updating your backend…" : "Searching within 1 km. Updating your backend…"
    }

    /// Testing switch. Off lets the app upload, and the backend alert, during 00:00–09:00 Finnish time.
    func setRespectsQuietHours(_ value: Bool) {
        guard value != respectsQuietHours else { return }
        UserDefaults.standard.set(value, forKey: MonitoringHours.respectsQuietHoursKey)
        respectsQuietHours = value
        errorMessage = nil
        refreshTracking()
        guard isSharing, hasConfiguration else { return }
        // Wake the loop: it may be sleeping until 09:00, or about to start sharing.
        nextAttempt = .distantPast
        failures = 0
        status = value
            ? "Quiet hours are on again. The backend stops alerts when the last location expires."
            : "Quiet hours are off for testing. Sharing continues at any hour."
        resume(inForeground: isForeground)
        scheduleRefresh()
    }

    func resume(inForeground: Bool) {
        isForeground = inForeground
        refreshTracking()
        loop?.cancel()
        loop = nil
        guard isSharing, hasConfiguration else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshTracking()
                if self.isQuietHours {
                    self.operation?.cancel()
                    self.status = "Quiet hours. Sharing can resume after 09:00 Finnish time."
                    let delay = MonitoringHours.nextAllowedDate(after: Date()).timeIntervalSinceNow
                    do { try await Task.sleep(for: .seconds(max(1, delay))) } catch { return }
                } else if self.isResting {
                    // No GPS and no 15 second uploads. Only an occasional check-in.
                    if self.operation == nil { Task { await self.checkInIfDue() } }
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                } else {
                    if self.operation == nil, Date() >= self.nextAttempt,
                       self.isForeground || self.location.hasAlwaysAccess {
                        Task { await self.shareNow() }
                    }
                    // A separate loop can stop an in-flight request when quiet hours begin.
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
    }

    func setSharing(_ value: Bool) {
        guard !value || hasConfiguration else { return }
        generation = UUID()
        operation?.cancel()
        operation = nil
        loop?.cancel()
        loop = nil
        isSharing = value
        UserDefaults.standard.set(value, forKey: "locationSharingEnabled")
        errorMessage = nil
        if !value { clearResting() }
        if value {
            nextAttempt = .distantPast
            failures = 0
            status = "Starting location sharing…"
            resume(inForeground: isForeground)
            scheduleRefresh()
        } else {
            location.setContinuousTracking(false)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshIdentifier)
            refreshTracking()
            status = "Sharing paused on this iPhone."
            // Quiet hours prohibit all network requests, including the pause request.
            guard !isQuietHours, let configuration else {
                status = "Sharing paused. The backend must stop alerts when the last location expires."
                return
            }
            let state = makeState(enabled: false, location: nil)
            let currentGeneration = generation
            operation = Task {
                defer { if generation == currentGeneration { operation = nil } }
                do {
                    _ = try await client.send(configuration: configuration, deviceID: deviceID, state: state)
                    guard generation == currentGeneration else { return false }
                    status = "Sharing paused. The backend confirmed alerts are paused."
                    return true
                } catch {
                    guard generation == currentGeneration else { return false }
                    status = "Sharing paused on this iPhone."
                    errorMessage = String(localized: "Could not confirm the pause with your server. Alerts must expire within two minutes of the last location.")
                    return false
                }
            }
        }
    }

    @discardableResult
    func shareNow(manual: Bool = false) async -> Bool {
        refreshTracking()
        guard isSharing, !isQuietHours, let configuration, operation == nil,
              !Task.isCancelled else { return false }
        guard manual || Date() >= nextAttempt else { return false }
        guard manual || !isResting else { return false }
        let currentGeneration = generation
        let work = Task { await upload(configuration: configuration, generation: currentGeneration) }
        operation = work
        defer { if generation == currentGeneration { operation = nil } }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func upload(configuration: BackendConfiguration, generation currentGeneration: UUID) async -> Bool {
        errorMessage = nil
        status = "Getting a recent location…"
        nextAttempt = Date().addingTimeInterval(15)
        do {
            let position = try await location.current(background: !isForeground)
            try Task.checkCancellation()
            try MonitoringHours.requireActiveHours()
            guard isSharing, generation == currentGeneration else { return false }
            let rest = shouldRest(at: position)
            let payload = try LocationPayload(location: position,
                lifetime: rest ? LocationPayload.restingLifetime : LocationPayload.lifetime)
            lastLocation = position
            status = "Sending your location to the backend…"
            let acknowledgement = try await client.send(configuration: configuration, deviceID: deviceID,
                state: makeState(enabled: true, location: payload, resting: rest))
            try Task.checkCancellation()
            guard generation == currentGeneration, isSharing, !MonitoringHours.isQuiet() else { return false }
            lastUpload = Date()
            telegramReady = acknowledgement.telegramReady
            failures = 0
            status = telegramReady
                ? "Location received by your backend. Flight alerts are handled in Telegram."
                : "Location received. Telegram still needs to be connected on your backend."
            // Only rest once the backend has accepted a resting update, so it never expects a silent phone it did not agree to.
            if rest {
                enterRest()
            } else if isResting {
                leaveRest()
            }
            return true
        } catch {
            guard generation == currentGeneration, isSharing else { return false }
            if MonitoringHours.isQuiet() {
                status = "Quiet hours. Location sharing is off."
                errorMessage = nil
            } else if error is CancellationError || (error as? URLError)?.code == .cancelled {
                status = "Location upload interrupted. It will retry when the app can run."
            } else {
                failures = min(failures + 1, 3)
                nextAttempt = Date().addingTimeInterval(15 * pow(2, Double(failures - 1)))
                status = "Location has not reached your backend."
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    private func makeState(enabled: Bool, location: LocationPayload?, resting: Bool = false) -> DeviceStatePayload {
        // Persist a monotonic revision so the server can reject a delayed pre-pause upload.
        let revision = UserDefaults.standard.integer(forKey: "locationSharingRevision") + 1
        UserDefaults.standard.set(revision, forKey: "locationSharingRevision")
        return DeviceStatePayload(revision: revision, enabled: enabled, location: location, restingAtHome: resting)
    }

    private func refreshTracking() {
        isQuietHours = MonitoringHours.isQuiet()
        let canTrack = isSharing && hasConfiguration && !isQuietHours && !isResting
            && (isForeground || location.hasAlwaysAccess)
        location.setContinuousTracking(canTrack)
        location.setMovementWakeUp(isSharing && hasConfiguration)
        switch location.authorizationStatus {
        case .authorizedAlways: permission = "Always location access enabled."
        case .authorizedWhenInUse: permission = "Location is allowed while using the app. Choose Always in Settings for background sharing."
        case .denied, .restricted: permission = "Location access is disabled. Enable it in Settings."
        default: permission = "Location permission has not been requested."
        }
        if isQuietHours {
            location.setContinuousTracking(false)
            operation?.cancel()
            backgroundStatus = "Location and uploads are off until 09:00 Finnish time."
        } else if !isSharing {
            backgroundStatus = "Background location is inactive."
        } else if isResting {
            backgroundStatus = "At home. Location is paused to save battery. iOS may wake ScanUp when you leave, but not if you swipe it away."
        } else if location.hasAlwaysAccess && location.isTracking {
            backgroundStatus = "Background location is active. iOS may interrupt updates."
        } else {
            backgroundStatus = "Always location access is needed to share while the screen is locked."
        }
    }

    func scheduleRefresh() {
        guard isSharing, hasConfiguration else { return }
        let earliest = MonitoringHours.nextAllowedDate(after: Date().addingTimeInterval(15 * 60))
        let identifier = Self.refreshIdentifier
        Task.detached {
            let request = BGAppRefreshTaskRequest(identifier: identifier)
            request.earliestBeginDate = earliest
            do {
                if #available(iOS 27.0, *) {
                    try await BGTaskScheduler.shared.submitTaskRequest(request)
                } else {
                    try BGTaskScheduler.shared.submit(request)
                }
                await MainActor.run {
                    if !self.isSharing {
                        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                    }
                }
            } catch {
                // Refresh is only a fallback; continuous location drives active sharing.
                await MainActor.run {
                    if self.isSharing {
                        self.backgroundStatus = "Background refresh is unavailable. Location sharing continues while iOS allows it."
                    }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: ScanMonitor.refreshIdentifier, using: .main) { task in
            let work = Task { @MainActor in
                let monitor = ScanMonitor.shared
                await monitor.prepare()
                monitor.resume(inForeground: false)
                monitor.scheduleRefresh()
                let success: Bool
                if monitor.isResting {
                    await monitor.checkInIfDue()
                    success = true
                } else {
                    success = await monitor.shareNow()
                }
                task.setTaskCompleted(success: success)
            }
            task.expirationHandler = { work.cancel() }
        }
        // iOS relaunched a closed app in the background, for example because you left home or moved a
        // long way. Location events are delivered to a CLLocationManager's delegate, so create it now.
        // A normal launch is not in the background, and still sets up after its first frame.
        if application.applicationState == .background {
            Task { @MainActor in
                let monitor = ScanMonitor.shared
                await monitor.prepare()
                monitor.resume(inForeground: false)
            }
        }
        return true
    }
}
