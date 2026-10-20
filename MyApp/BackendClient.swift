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

struct AirportRequest: Encodable {
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
    private var retryAfter = Date.distantPast

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    static func makeRequest(configuration: BackendConfiguration, path: String,
                            body: (any Encodable)? = nil) throws -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
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
        guard Date() >= retryAfter else {
            throw ScanError.message(String(localized: "The server asked us to wait. Try again at \(retryAfter.formatted(date: .omitted, time: .standard))."))
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
            retryAfter = Date().addingTimeInterval(min(3600, max(15, delay)))
            throw ScanError.wait(String(localized: "The server is limiting requests. Trying again soon."),
                                 seconds: min(3600, max(15, delay)))
        }
        try Self.check(response: response)
        return data
    }

    private func post<Response: Decodable>(_ path: String, body: some Encodable, as type: Response.Type,
                                           configuration: BackendConfiguration) async throws -> Response {
        let data = try await perform(Self.makeRequest(configuration: configuration, path: path, body: body))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
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

    func airport(latitude: Double, longitude: Double,
                 configuration: BackendConfiguration) async throws -> AirportResponse {
        let body = AirportRequest(latitude: latitude, longitude: longitude)
        return try await post("v1/airport", body: body, as: AirportResponse.self, configuration: configuration)
    }

    /// Checks the address and token. Sends no position.
    func ping(configuration: BackendConfiguration) async throws {
        _ = try await perform(Self.makeRequest(configuration: configuration, path: "v1/ping"))
    }
}
