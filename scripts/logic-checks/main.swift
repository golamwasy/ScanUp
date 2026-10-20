import CoreLocation
import Foundation

// Checks for the app's pure logic. Run with scripts/logic-checks/run.sh.

var failures = 0
func check(_ ok: Bool, _ name: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(name)") }
}
func close(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) <= tolerance }

// MARK: Compass

check(close(Compass.normalized(-10), 350), "normalized -10")
check(close(Compass.normalized(370), 10), "normalized 370")
check(close(Compass.normalized(360), 0), "normalized 360")
check(close(Compass.shortestTurn(from: 350, to: 10), 20), "350 to 10 turns +20")
check(close(Compass.shortestTurn(from: 10, to: 350), -20), "10 to 350 turns -20")
check(close(Compass.shortestTurn(from: 725, to: 5), 0), "an unwrapped current of 725 is the same as 5")

var dial = 350.0
for _ in 0..<40 { dial = Compass.smoothed(current: dial, toward: 10, factor: 0.4) }
check(close(dial, 370, 0.1), "the dial keeps going past 360 instead of spinning back: \(dial)")
var back = 10.0
for _ in 0..<40 { back = Compass.smoothed(current: back, toward: 350, factor: 0.4) }
check(close(back, -10, 0.1), "the dial goes below 0 instead of spinning round: \(back)")

check(close(Compass.relative(bearing: 90, heading: 90), 0), "facing the aircraft")
check(close(Compass.relative(bearing: 90, heading: 0), 90), "east seen facing north is to the right")
check(close(Compass.relative(bearing: 90, heading: nil), 90), "no compass keeps north up")
check(close(Compass.relative(bearing: 0, heading: 90), -90), "north seen facing east is to the left")

// MARK: Compass points never index out of range

for degrees in [-720, -360, -45, -1, 0, 1, 22, 23, 44, 45, 337, 338, 359, 360, 361, 720, 100_000] {
    let point = Aircraft.compassPoint(for: degrees)
    check(["N", "NE", "E", "SE", "S", "SW", "W", "NW"].contains(point), "compass point for \(degrees)")
}
check(Aircraft.compassPoint(for: 359) == "N" && Aircraft.compassPoint(for: 90) == "E" && Aircraft.compassPoint(for: 225) == "SW", "compass points")

// MARK: Aircraft drift between refreshes

func plane(distance: Int, bearing: Int, speed: Int?, track: Int?) -> Aircraft {
    Aircraft(id: "a", callsign: nil, airline: nil, origin: nil, originCode: nil, destination: nil, destinationCode: nil,
             type: nil, registration: nil, altitudeFt: 3000, speedKt: speed, headingDeg: track, verticalRateFpm: nil,
             distanceM: distance, bearingDeg: bearing, elevationDeg: nil, onGround: false)
}
let still = plane(distance: 1000, bearing: 90, speed: 200, track: 90).projected(after: 0)
check(close(still.distance, 1000) && close(still.bearing, 90), "no time, no movement")
let away = plane(distance: 1000, bearing: 90, speed: 200, track: 90).projected(after: 10)
check(close(away.distance, 1000 + 1028.9, 1.0) && close(away.bearing, 90), "flying away east: \(away)")
let toward = plane(distance: 2000, bearing: 90, speed: 200, track: 270).projected(after: 10)
check(close(toward.distance, 2000 - 1028.9, 1.0), "flying toward the phone: \(toward)")
let crossing = plane(distance: 1000, bearing: 0, speed: 200, track: 90).projected(after: 10)
check(crossing.bearing > 0 && crossing.bearing < 90 && crossing.distance > 1000, "crossing swings the bearing clockwise: \(crossing)")
let capped = plane(distance: 1000, bearing: 90, speed: 200, track: 90)
check(close(capped.projected(after: 30).distance, capped.projected(after: 300).distance), "movement stops after 30 seconds")
check(close(plane(distance: 500, bearing: 45, speed: nil, track: 90).projected(after: 10).distance, 500), "no speed, no movement")
check(close(plane(distance: 500, bearing: 45, speed: 100, track: nil).projected(after: 10).distance, 500), "no track, no movement")
check(close(plane(distance: 500, bearing: 45, speed: 0, track: 90).projected(after: 10).distance, 500), "stopped, no movement")

// MARK: Location errors

check(LocationFailure.reaction(to: CLError(.locationUnknown)) == .keepWaiting, "location unknown keeps waiting")
check(LocationFailure.reaction(to: CLError(.headingFailure)) == .compassUnavailable, "a heading failure is only the compass")
check(LocationFailure.reaction(to: CLError(.denied)) == .denied, "denied")
check(LocationFailure.reaction(to: CLError(.network)) == .fail, "network fails")
check(LocationFailure.reaction(to: URLError(.timedOut)) == .fail, "other errors fail")

// MARK: What the server sends

let usageJSON = #"{"adsb_lol":{"used":1,"daily_budget":500,"remaining":499,"counted_since":"2026-10-20T14:06:18.105730Z"},"opensky":{"enabled":true,"credits_remaining":1171,"checked_at":"2026-10-20T14:06:18.893864Z"}}"#
let usageOffJSON = #"{"adsb_lol":{"used":420,"daily_budget":500,"remaining":80,"counted_since":"2026-10-20T14:06:18Z"},"opensky":{"enabled":false}}"#
let nearbyJSON = #"{"updated_at":"2026-10-20T14:06:18.1Z","refresh_after_s":30,"source":"adsb.lol","aircraft":[{"id":"4601fb","callsign":"FIN1L","airline":"Finnair","distance_m":850,"bearing_deg":44,"elevation_deg":54,"on_ground":false}]}"#
let airportJSON = #"{"updated_at":"2026-10-20T14:06:18.1Z","refresh_after_s":60,"aircraft":[]}"#

MainActor.assumeIsolated {
    do {
        let usage = try BackendClient.decode(Usage.self, from: Data(usageJSON.utf8))
        check(usage.adsbLol.used == 1 && usage.adsbLol.remaining == 499 && usage.adsbLol.dailyBudget == 500, "usage numbers")
        check(usage.opensky.enabled && usage.opensky.creditsRemaining == 1171 && usage.opensky.checkedAt != nil, "opensky numbers")
        check(close(usage.adsbLol.countedSince.timeIntervalSince1970, 1_792_505_178.1, 1), "dates with fractions of a second")
        check(!usage.adsbLol.isRunningLow, "1 of 500 is not low")
        let second = try BackendClient.decode(Usage.self, from: Data(usageOffJSON.utf8))
        check(!second.opensky.enabled && second.opensky.creditsRemaining == nil, "opensky not set up")
        check(second.adsbLol.isRunningLow && close(second.adsbLol.fractionUsed, 0.84), "420 of 500 is low")

        let nearby = try BackendClient.decode(NearbyResponse.self, from: Data(nearbyJSON.utf8))
        check(nearby.refreshAfterS == 30 && nearby.aircraft.count == 1 && nearby.aircraft[0].airline == "Finnair", "nearby answer")
        check(nearby.aircraft[0].title == "Finnair" && nearby.aircraft[0].lookDirection == "NE · 54° up", "card texts")
        let airport = try BackendClient.decode(AirportResponse.self, from: Data(airportJSON.utf8))
        check(airport.airport == nil && airport.source == nil && airport.aircraft.isEmpty && airport.refreshAfterS == 60, "no airport nearby")
    } catch {
        check(false, "decoding threw \(error)")
    }
    do {
        _ = try BackendClient.decode(Usage.self, from: Data("{}".utf8))
        check(false, "an unexpected answer must be rejected")
    } catch {
        check(true, "an unexpected answer is rejected")
    }
}

print(failures == 0 ? "all checks passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
