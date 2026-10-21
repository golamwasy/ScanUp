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
             distanceM: distance, bearingDeg: bearing, elevationDeg: nil, phase: nil, onGround: false)
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
let usageOffJSON = #"{"adsb_lol":{"used":420,"daily_budget":500,"remaining":80,"counted_since":"2026-10-20T14:06:18Z","next_free_at":"2026-10-21T14:07:00.5Z"},"opensky":{"enabled":false}}"#
let nearbyJSON = #"{"updated_at":"2026-10-20T14:06:18.1Z","refresh_after_s":30,"source":"adsb.lol","aircraft":[{"id":"4601fb","callsign":"FIN1L","airline":"Finnair","distance_m":850,"bearing_deg":44,"elevation_deg":54,"on_ground":false}]}"#
let usageSchedulesJSON = #"{"adsb_lol":{"used":1,"daily_budget":500,"remaining":499,"counted_since":"2026-10-20T14:06:18Z"},"opensky":{"enabled":false},"flight_schedules":{"enabled":true,"remaining":60,"monthly_limit":400,"resets_at":"2026-11-21T15:34:08.471599Z","used_last_30_days":340}}"#

/// A flight between Helsinki and Tallinn, scheduled at the given UTC time (the airport clock is UTC+3).
func flightJSON(number: String = "AY 1013", status: String = "expected", utc: String, local: String, revised: String? = nil,
                gate: String? = "11", extra: String = "") -> String {
    let place = #"{"name":"Helsinki Vantaa Airport","city":"Helsinki (Vantaa)","iata":"HEL","icao":"EFHK","country":"FI"}"#
    let other = #"{"name":"Tallinn","iata":"TLL","icao":"EETN","country":"EE"}"#
    let revisedPart = revised.map { #","revised":{"utc":"\#($0)","local":"\#($0)"}"# } ?? ""
    let gatePart = gate.map { #","gate":"\#($0)""# } ?? ""
    return #"{"number":"\#(number)","status":"\#(status)","airline":"Finnair","airline_iata":"AY","departure":{"airport":\#(place),"scheduled":{"utc":"\#(utc)","local":"\#(local)"}\#(revisedPart)\#(gatePart)},"arrival":{"airport":\#(other),"scheduled":{"utc":"2026-10-21T08:00:00Z","local":"2026-10-21T11:00:00+03:00"}}\#(extra)}"#
}

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
        check(second.adsbLol.nextFreeAt != nil && usage.adsbLol.nextFreeAt == nil, "when the next request frees up is optional")

        let nearby = try BackendClient.decode(NearbyResponse.self, from: Data(nearbyJSON.utf8))
        check(nearby.refreshAfterS == 30 && nearby.aircraft.count == 1 && nearby.aircraft[0].airline == "Finnair", "nearby answer")
        check(nearby.aircraft[0].title == "Finnair" && nearby.aircraft[0].lookDirection == "NE · 54° up", "card texts")
        check(usage.flightSchedules == nil, "an older server sends no schedule allowance")
        let withSchedules = try BackendClient.decode(Usage.self, from: Data(usageSchedulesJSON.utf8))
        check(withSchedules.flightSchedules?.remaining == 60 && withSchedules.flightSchedules?.monthlyLimit == 400, "schedule allowance numbers")
        check(withSchedules.flightSchedules?.isRunningLow == true && withSchedules.flightSchedules?.resetsAt != nil, "340 of 400 is low")
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

MainActor.assumeIsolated {
    do {
        // Boards: times come twice, UTC for order and the airport's own clock for showing.
        let boardJSON = #"{"airport":{"name":"Helsinki Vantaa Airport","city":"Helsinki (Vantaa)","iata":"HEL","icao":"EFHK","country":"FI","is_nearest":true,"distance_m":129},"updated_at":"2026-10-21T19:10:58.187931Z","refresh_after_s":600,"departures":[\#(flightJSON(utc: "2026-10-21T07:00:00Z", local: "2026-10-21T10:00:00+03:00", revised: "2026-10-21T07:11:00Z"))],"arrivals":[]}"#
        let board = try BackendClient.decode(BoardResponse.self, from: Data(boardJSON.utf8))
        check(board.airport?.isNearest == true && board.airport?.distanceM == 129 && board.airport?.icao == "EFHK", "board airport")
        check(board.refreshAfterS == 600 && board.notice == nil && board.arrivals.isEmpty, "board envelope")
        let flight = board.departures[0]
        check(flight.departure.scheduled?.clock == "10:00" && flight.departure.scheduled?.day == "2026-10-21", "the airport clock, not the phone's")
        check(flight.departure.scheduled?.offsetSeconds == 10_800, "offset read from the local time")
        check(flight.departure.delayMinutes == 11 && flight.departure.isLate, "11 minutes late is late")
        check(flight.arrival.delayMinutes == nil && !flight.arrival.isLate, "no estimate, no delay")
        check(flight.flightStatus == .expected && flight.departure.gate == "11" && flight.arrival.gate == nil, "status and gate")
        check(flight.initials == "AY" && flight.departure.airport.code == "HEL" && flight.arrival.airport.code == "TLL", "badge and codes")
        check(flight.arrival.airport.shortName == "Tallinn" && flight.departure.airport.shortName == "Helsinki", "short names drop the district")
        check(flight.end(on: .departures).airport.iata == "HEL" && flight.otherEnd(on: .departures).airport.iata == "TLL", "ends by direction")
        check(flight.end(on: .arrivals).airport.iata == "TLL" && flight.otherEnd(on: .arrivals).airport.iata == "HEL", "ends for arrivals")

        // An unknown status is neutral, and a missing airport name field does not matter.
        let odd = try BackendClient.decode(ScheduledFlight.self, from: Data(flightJSON(status: "teleported", utc: "2026-10-21T07:00:00Z", local: "2026-10-21T10:00:00+03:00", gate: nil).utf8))
        check(odd.flightStatus == .unknown && odd.departure.gate == nil, "unknown status and no gate")
        check(try BackendClient.decode(ScheduledFlight.self, from: Data(flightJSON(status: "check_in", utc: "2026-10-21T07:00:00Z", local: "2026-10-21T10:00:00+03:00").utf8)).flightStatus == .checkIn, "snake case status")
        let early = try BackendClient.decode(ScheduledFlight.self, from: Data(flightJSON(utc: "2026-10-21T07:00:00Z", local: "2026-10-21T10:00:00+03:00", revised: "2026-10-21T06:50:00Z").utf8))
        check(early.departure.delayMinutes == -10 && !early.departure.isLate, "ten minutes early is not late")

        // Rows: a heading when the day changes, and "now" before the first flight still to come.
        let a1 = try BackendClient.decode(ScheduledFlight.self, from: Data(flightJSON(number: "A1", utc: "2026-10-21T06:00:00Z", local: "2026-10-21T09:00:00+03:00").utf8))
        let a2 = try BackendClient.decode(ScheduledFlight.self, from: Data(flightJSON(number: "A2", utc: "2026-10-21T20:00:00Z", local: "2026-10-21T23:00:00+03:00").utf8))
        let a3 = try BackendClient.decode(ScheduledFlight.self, from: Data(flightJSON(number: "A3", utc: "2026-10-21T22:00:00Z", local: "2026-10-22T01:00:00+03:00").utf8))
        let noon = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!
        let rows = BoardRow.rows(for: [a1, a2, a3], direction: .departures, now: noon)
        check(rows.map(\.id) == ["day-2026-10-21", "A1|2026-10-21T09:00:00+03:00|EETN", "now", "A2|2026-10-21T23:00:00+03:00|EETN",
                                  "day-2026-10-22", "A3|2026-10-22T01:00:00+03:00|EETN"], "rows: \(rows.map(\.id))")
        let late = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z")!
        check(BoardRow.rows(for: [a1, a2], direction: .departures, now: late).last?.id == "now", "now at the end when all are past")
        check(BoardRow.rows(for: [], direction: .departures, now: noon).map(\.id) == ["now"], "an empty board is only the now line")

        let airports = try BackendClient.decode(AirportSearchResponse.self, from: Data(#"{"airports":[{"name":"London Heathrow Airport","city":"London","iata":"LHR","icao":"EGLL","country":"GB"},{"name":"Tiny Strip","icao":"XX12"}]}"#.utf8))
        check(airports.airports.count == 2 && airports.airports[0].code == "LHR" && airports.airports[1].code == "XX12", "airport search answer")
        check(airports.airports[1].shortName == "Tiny Strip" && airports.airports[0].id == "EGLL", "place names and ids")
    } catch {
        check(false, "decoding threw \(error)")
    }
    check(TrackQuery.normalised("ay 1406") == "AY1406" && TrackQuery.normalised(" fin5da ") == "FIN5DA", "search text is tidied")
    check(TrackQuery.normalised("oh-lxa") == "OH-LXA" && TrackQuery.normalised("N393UP") == "N393UP", "registrations")
    check(TrackQuery.normalised("A") == nil && TrackQuery.normalised("") == nil && TrackQuery.normalised("-AB") == nil, "too short or starting with a hyphen")
    check(TrackQuery.normalised("AY1406; DROP") == nil && TrackQuery.normalised("AY/1406") == nil && TrackQuery.normalised("ABCDEFGHIJK") == nil, "junk and long text is refused")
}

MainActor.assumeIsolated {
  do {
    // Barometric altitude can read below sea level on a day of high pressure, and must never be shown that way.
    func json(_ altitude: String) -> Data {
        Data(#"{"id":"a","altitude_ft":\#(altitude),"distance_m":500,"bearing_deg":10,"on_ground":false}"#.utf8)
    }
    let below = try BackendClient.decode(Aircraft.self, from: json("-375"))
    check(below.heightFt == 0 && below.isVeryLow, "a negative altitude counts as zero and very low")
    let low = try BackendClient.decode(Aircraft.self, from: json("99"))
    let high = try BackendClient.decode(Aircraft.self, from: json("3700"))
    func phaseJSON(_ phase: String) -> Data {
        Data(#"{"id":"a","altitude_ft":900,"phase":"\#(phase)","distance_m":500,"bearing_deg":10,"on_ground":false}"#.utf8)
    }
    check(try BackendClient.decode(Aircraft.self, from: phaseJSON("landing")).flightPhase == .landing, "landing phase")
    check(try BackendClient.decode(Aircraft.self, from: phaseJSON("taking_off")).flightPhase == .takingOff, "taking off phase")
    check(try BackendClient.decode(Aircraft.self, from: phaseJSON("hovering")).flightPhase == nil, "an unknown phase is ignored")
    check(try BackendClient.decode(Aircraft.self, from: json("900")).flightPhase == nil, "no phase when absent")
    check(low.isVeryLow && !high.isVeryLow && high.heightFt == 3700, "very low is under 100 ft")
  } catch {
    check(false, "decoding threw \(error)")
  }
}

do {
    // One failed refresh after a good answer keeps the list and only changes the status line. A few in a row, or a
    // failure before any answer, take over the screen. Problems the person must fix always do.
    var feed = Feed()
    feed.problem = .failed("x")
    check(feed.showsProblem, "a failure before any answer shows the problem")
    feed.updatedAt = Date()
    feed.failures = 1
    check(!feed.showsProblem, "one failure after an answer keeps the list")
    feed.failures = 2
    check(!feed.showsProblem, "two failures keep the list")
    feed.failures = Feed.failuresBeforeProblem
    check(feed.showsProblem, "three failures in a row show the problem")
    feed.failures = 0
    feed.problem = .locationOff
    check(feed.showsProblem, "location off always shows")
    feed.problem = nil
    check(!feed.showsProblem, "no problem, nothing to show")
}

do {
    // The two fake places, from the user's map coordinates.
    check(TestLocation.all.count == 2, "two fake places")
    check(close(TestLocation.all[0].latitude, 60.317200, 1e-9) && close(TestLocation.all[0].longitude, 24.963300, 1e-9), "location 1 coordinates")
    check(close(TestLocation.all[1].latitude, 60.171900, 1e-9) && close(TestLocation.all[1].longitude, 24.941400, 1e-9), "location 2 coordinates")
    check(TestLocation.choice(1).name == "Location 2", "choice 1 is location 2")
    check(TestLocation.choice(7).id == 0 && TestLocation.choice(-1).id == 0, "an unknown choice is location 1")
    let position = TestLocation.choice(0).position
    check(position.horizontalAccuracy == 5 && abs(position.timestamp.timeIntervalSinceNow) < 5, "the position is exact and fresh")
    check(position.coordinate.latitude == 60.317200, "the position carries the coordinates")
    check(TestLocation.choice(0).coordinatesText == "60.317200, 24.963300", "coordinates read with a dot")
    check(TestLocation.all.allSatisfy { CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }, "valid coordinates")
}

print(failures == 0 ? "all checks passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
