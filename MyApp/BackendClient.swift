import Foundation
import Security

enum ScanError: LocalizedError {
    case message(String)
    /// The server asked the app to wait, so the next try should not come sooner.
    case wait(String, seconds: Double)

    var errorDescription: String? {
        switch self {
        case .message(let message), .wait(let message, _): message
        }
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

struct NearbyRequest: Encodable {
    let latitude: Double
    let longitude: Double
    let radiusM: Int
}

/// An airport chosen in the search (`code`), or the phone's position for the nearest airport.
struct BoardRequest: Encodable {
    let code: String?
    let latitude: Double?
    let longitude: Double?
    /// "coming" (an hour ago to about 11 hours ahead), "past" (the 12 hours before now) or "all".
    let part: String
}

struct TrackRequest: Encodable {
    let query: String
    let latitude: Double
    let longitude: Double
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
    /// When each endpoint may be asked again after a 429, so a limit on one does not hold up the others.
    private var retryAfter: [String: Date] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        // The server may try its second aircraft source after the first one stalls, which takes up to about 20 seconds.
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    static func makeRequest(configuration: BackendConfiguration, path: String, query: [URLQueryItem] = [],
                            body: (any Encodable)? = nil) throws -> URLRequest {
        var url = configuration.baseURL.appendingPathComponent(path)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            url = components.url ?? url
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        return request
    }

    static func check(response: HTTPURLResponse) throws {
        guard response.statusCode == 200,
              response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") == true else {
            switch response.statusCode {
            case 401, 403:
                throw ScanError.message(String(localized: "Server access denied. Check the access token in Settings."))
            case 404:
                throw ScanError.message(String(localized: "Backend API not found. Check the server address in Settings."))
            case 422:
                throw ScanError.message(String(localized: "The server could not use that request. Check what you typed."))
            case 300...399:
                throw ScanError.message(String(localized: "The server redirected this request. Use a direct API address without a browser login."))
            case 503:
                let seconds = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 15
                throw ScanError.wait(String(localized: "Flight data is unavailable right now. Trying again soon."), seconds: seconds)
            default:
                throw ScanError.message(String(localized: "The server did not accept the request (HTTP \(response.statusCode))."))
            }
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let endpoint = request.url?.path ?? ""
        if let until = retryAfter[endpoint], Date() < until {
            throw ScanError.wait(String(localized: "The server asked us to wait. Trying again at \(until.formatted(date: .omitted, time: .standard))."),
                                 seconds: until.timeIntervalSinceNow)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw ScanError.message(String(localized: "No internet connection."))
            case .timedOut:
                throw ScanError.message(String(localized: "The server took too long to answer."))
            default:
                throw ScanError.message(String(localized: "Could not reach the server."))
            }
        }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 429 {
            let delay = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            retryAfter[endpoint] = Date().addingTimeInterval(min(3600, max(15, delay)))
            throw ScanError.wait(String(localized: "The server is limiting requests. Trying again soon."),
                                 seconds: min(3600, max(15, delay)))
        }
        try Self.check(response: response)
        return data
    }

    private func post<Response: Decodable>(_ path: String, body: some Encodable, as type: Response.Type,
                                           configuration: BackendConfiguration) async throws -> Response {
        let data = try await perform(Self.makeRequest(configuration: configuration, path: path, body: body))
        return try Self.decode(Response.self, from: data)
    }

    static func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // The backend writes times like 2026-10-20T14:06:18.105730Z, with fractions of a second.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw ScanError.message(String(localized: "The server answer was not what ScanUp expected. Check the server address."))
        }
    }

    func nearby(latitude: Double, longitude: Double, radiusMeters: Int,
                configuration: BackendConfiguration) async throws -> NearbyResponse {
        let body = NearbyRequest(latitude: latitude, longitude: longitude, radiusM: radiusMeters)
        return try await post("v1/nearby", body: body, as: NearbyResponse.self, configuration: configuration)
    }

    /// Departures and arrivals of an airport: the coming part (2 schedule units) or the past part (2 units).
    func board(_ request: BoardRequest, configuration: BackendConfiguration) async throws -> BoardResponse {
        try await post("v1/board", body: request, as: BoardResponse.self, configuration: configuration)
    }

    /// The aircraft heard right now under a flight number, callsign or registration, from anywhere in the world.
    func track(query: String, latitude: Double, longitude: Double, configuration: BackendConfiguration) async throws -> NearbyResponse {
        try await post("v1/track", body: TrackRequest(query: query, latitude: latitude, longitude: longitude),
                       as: NearbyResponse.self, configuration: configuration)
    }

    /// Airports for a code, a city or a name. Free: the server searches its own list.
    func searchAirports(_ query: String, configuration: BackendConfiguration) async throws -> [Place] {
        let request = try Self.makeRequest(configuration: configuration, path: "v1/airports/search",
                                           query: [URLQueryItem(name: "q", value: query)])
        return try Self.decode(AirportSearchResponse.self, from: try await perform(request)).airports
    }

    /// What is left of each data source's allowance.
    func usage(configuration: BackendConfiguration) async throws -> Usage {
        let data = try await perform(Self.makeRequest(configuration: configuration, path: "v1/usage"))
        return try Self.decode(Usage.self, from: data)
    }

    /// Checks the address and token. Sends no position.
    func ping(configuration: BackendConfiguration) async throws {
        _ = try await perform(Self.makeRequest(configuration: configuration, path: "v1/ping"))
    }
}
