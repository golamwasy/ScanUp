import CoreLocation

/// A fixed place the app can use instead of the phone's position, to try it without travelling. Both are near
/// Helsinki-Vantaa Airport.
struct TestLocation: Equatable, Identifiable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double

    static let all = [
        TestLocation(id: 0, name: "Location 1", latitude: 60.317200, longitude: 24.963300),
        TestLocation(id: 1, name: "Location 2", latitude: 60.171900, longitude: 24.941400),
    ]

    /// The place with this number. A number that is not on the list, such as one left by an older version, is the first.
    static func choice(_ index: Int) -> TestLocation { all.indices.contains(index) ? all[index] : all[0] }

    /// The place as a position that is exact and fresh, like a fix from the GPS.
    var position: CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), altitude: 0,
                   horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: Date())
    }

    /// "60.317200, 24.963300", with a dot whatever the language of the phone.
    var coordinatesText: String { String(format: "%.6f, %.6f", latitude, longitude) }
}
