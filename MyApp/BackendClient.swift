import Foundation
import CoreLocation
import Security

enum MonitoringHours {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZone = TimeZone(identifier: "Europe/Helsinki") {
            calendar.timeZone = timeZone
        }
        return calendar
    }

    static let respectsQuietHoursKey = "quietHoursEnabled"

    /// Testing switch. When false, the app and the backend ignore quiet hours for this device.
    static var respectsQuietHours: Bool {
        UserDefaults.standard.object(forKey: respectsQuietHoursKey) as? Bool ?? true
    }

    static func isQuiet(at date: Date = Date()) -> Bool {
        respectsQuietHours && calendar.component(.hour, from: date) < 9
    }
    
    static func nextAllowedDate(after date: Date) -> Date {
        guard isQuiet(at: date) else { return date }
        return calendar.nextDate(after: date, matching: DateComponents(hour: 9, minute: 0, second: 0),
                                 matchingPolicy: .nextTime) ?? date.addingTimeInterval(24 * 60 * 60)
    }

    static func requireActiveHours(at date: Date = Date()) throws {
        guard !isQuiet(at: date) else {
            throw ScanError.message(String(localized: "Quiet hours: location sharing is off until 09:00 Finnish time."))
        }
    }
}

enum SearchRadius {
    static let wideKey = "wideSearchRadiusEnabled"
    static let normalMeters = 1_000
    static let wideMeters = 10_000

    /// Off by default. When on, the backend searches within 10 km instead of 1 km.
    static var isWide: Bool { UserDefaults.standard.bool(forKey: wideKey) }
    static var meters: Int { isWide ? wideMeters : normalMeters }
}

enum ScanError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

struct BackendConfiguration: Codable {
    static let suggestedURL = "https://your-server.example"
    let baseURL: URL
    let token: String

    static func validatedURL(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let url = components.url else {
            throw ScanError.message(String(localized: "Enter an HTTPS server address without a path, query or password."))
        }
        return url
    }

    init(address: String, token: String) throws {
        baseURL = try Self.validatedURL(address)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096,
              trimmed.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else {
            throw ScanError.message(String(localized: "Enter the app access token created by your backend."))
        }
        self.token = trimmed
    }
}

enum BackendCredentialStore {
    nonisolated private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ScanUp.Backend",
         kSecAttrAccount as String: "connection"]
    }

    nonisolated static func loadData() -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func load() -> BackendConfiguration? {
        guard let data = loadData() else { return nil }
        return try? JSONDecoder().decode(BackendConfiguration.self, from: data)
    }

    static func save(_ configuration: BackendConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else {
                throw ScanError.message(String(localized: "Could not save the connection securely."))
            }
        } else if status != errSecSuccess {
            throw ScanError.message(String(localized: "Could not update the saved connection."))
        }
    }
}

struct LocationPayload: Codable {
    static let maximumAge: TimeInterval = 30
    static let lifetime: TimeInterval = 120
    /// A phone resting at home may go this long between check-ins. The backend caps it at 48 hours.
    static let restingLifetime: TimeInterval = 48 * 3600
    let latitude: Double
    let longitude: Double
    let horizontalAccuracyM: Double
    let capturedAt: Date
    let expiresAt: Date

    init(location: CLLocation, now: Date = Date(), lifetime: TimeInterval = LocationPayload.lifetime) throws {
        guard CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy.isFinite,
              (0...100).contains(location.horizontalAccuracy),
              (-5...Self.maximumAge).contains(now.timeIntervalSince(location.timestamp)) else {
            throw ScanError.message(String(localized: "Waiting for a recent, accurate location. Try outdoors with Precise Location enabled."))
        }
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        horizontalAccuracyM = location.horizontalAccuracy
        capturedAt = location.timestamp
        expiresAt = location.timestamp.addingTimeInterval(lifetime)
    }
}

struct HomePayload: Codable, Equatable {
    let latitude: Double
    let longitude: Double
}

enum HomeGeofence {
    /// iOS watches this circle around home and wakes the app when you leave it.
    static let radius: CLLocationDistance = 200
    /// The phone only rests when this close to home. A little inside the 200 m circle the backend checks,
    /// so the app and the backend can never disagree about a fix near the edge.
    static let restDistance: CLLocationDistance = 190
    /// A coarse position this far from home ends resting.
    static let leaveDistance: CLLocationDistance = 300
}

enum HomeStore {
    private static let latitudeKey = "homeLatitude"
    private static let longitudeKey = "homeLongitude"

    static var current: HomePayload? {
        let defaults = UserDefaults.standard
        guard let latitude = defaults.object(forKey: latitudeKey) as? Double,
              let longitude = defaults.object(forKey: longitudeKey) as? Double else { return nil }
        return HomePayload(latitude: latitude, longitude: longitude)
    }

    static func save(_ home: HomePayload) {
        UserDefaults.standard.set(home.latitude, forKey: latitudeKey)
        UserDefaults.standard.set(home.longitude, forKey: longitudeKey)
    }

    static func distance(from position: CLLocation, to home: HomePayload) -> CLLocationDistance {
        position.distance(from: CLLocation(latitude: home.latitude, longitude: home.longitude))
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: latitudeKey)
        UserDefaults.standard.removeObject(forKey: longitudeKey)
    }
}

struct DeviceStatePayload: Encodable {
    let apiVersion = 1
    let revision: Int
    let enabled: Bool
    let location: LocationPayload?
    let radiusM = SearchRadius.meters
    let pollIntervalSeconds = 15
    let timeZone = "Europe/Helsinki"
    let quietStart = "00:00"
    let quietEnd = "09:00"
    let quietHoursEnabled = MonitoringHours.respectsQuietHours
    /// Every update carries the saved home. A missing home clears it on the backend.
    let home = HomeStore.current
    /// True when the app is at home and about to sleep. The backend honours it only near home.
    var restingAtHome = false
}

struct BackendAcknowledgement: Decodable {
    let apiVersion: Int
    let revision: Int
    let enabled: Bool
    let telegramReady: Bool
}

// A Cloudflare login page or redirect must never receive the app's bearer token.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class BackendClient {
    private let session: URLSession
    private var retryAfter = Date.distantPast

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    static func makeRequest(configuration: BackendConfiguration, deviceID: UUID,
                            state: DeviceStatePayload, now: Date = Date()) throws -> URLRequest {
        try MonitoringHours.requireActiveHours(at: now)
        let url = configuration.baseURL.appendingPathComponent("v1/devices")
            .appendingPathComponent(deviceID.uuidString.lowercased()).appendingPathComponent("state")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(state)
        return request
    }

    static func acknowledgement(data: Data, response: HTTPURLResponse,
                                state: DeviceStatePayload) throws -> BackendAcknowledgement {
        guard response.statusCode == 200,
              response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") == true else {
            switch response.statusCode {
            case 401, 403:
                throw ScanError.message(String(localized: "Server access denied. Check the app token and Cloudflare access settings."))
            case 404:
                throw ScanError.message(String(localized: "Backend API not found. Finish the server setup before sharing."))
            case 300...399:
                throw ScanError.message(String(localized: "The server redirected this request. Use a direct API address without a browser login."))
            default:
                throw ScanError.message(String(localized: "The backend did not accept the update (HTTP \(response.statusCode))."))
            }
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let acknowledgement = try? decoder.decode(BackendAcknowledgement.self, from: data),
              acknowledgement.apiVersion == 1,
              acknowledgement.revision == state.revision,
              acknowledgement.enabled == state.enabled else {
            throw ScanError.message(String(localized: "The server response does not match the location API. Finish the backend setup."))
        }
        return acknowledgement
    }

    func send(configuration: BackendConfiguration, deviceID: UUID,
              state: DeviceStatePayload) async throws -> BackendAcknowledgement {
        try Task.checkCancellation()
        guard Date() >= retryAfter else {
            throw ScanError.message(String(localized: "The server asked us to wait. Retry after \(retryAfter.formatted(date: .omitted, time: .standard))."))
        }
        let request = try Self.makeRequest(configuration: configuration, deviceID: deviceID, state: state)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 429 {
            let delay = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            retryAfter = Date().addingTimeInterval(min(3600, max(15, delay)))
            throw ScanError.message(String(localized: "The server is limiting requests. Sharing will retry automatically."))
        }
        return try Self.acknowledgement(data: data, response: response, state: state)
    }
}
