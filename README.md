# ScanUp

An iPhone app that shows what is flying around you. Open it and it asks your own server for the aircraft near your position.

- **Overhead:** aircraft within a distance you choose (3 km by default, up to 10 km). A radar that turns with the phone's compass shows where each one is. Tap an aircraft for its route, type, registration, altitude, speed and where in the sky to look.
- **Search:** type a flight number (AY1406), a callsign (FIN5DA) or a registration (OH-LXA). If that plane is in the air and heard right now, you see where it is, how high and fast, its route, and when it departed and is due to arrive. If not, the app says it is not on the radar.
- **Airport:** a board of departures and arrivals, from 12 hours ago to about 11 hours ahead, for the nearest airport or any airport you search for. It opens at "now", with the airport's local times, delays, gates and baggage belts.
- **Settings:** the server address and token, the search distance, the data sources' remaining requests (including the monthly flight schedule units), a fake location for testing, and the location status.

The position is read only while the app is open, and it is sent only to the server you set up. Nothing runs in the background. The server is [ScanUp-Backend](https://github.com/golamwasy/ScanUp-Backend), and the API the app talks to is described in its `API_CONTRACT.md`.

## Build

Open `ScanUp.xcodeproj` in Xcode (iOS 27 and the Swift 6 language mode), choose a device and run. Enter the server address and the access token in Settings. The token is kept in the iPhone's Keychain.

## Layout

| File | What it holds |
|---|---|
| `FlightStore.swift` | State of the screens, refresh pacing, back-off, idle pause |
| `BackendClient.swift` | The server connection, token storage and request code |
| `LocationFetcher.swift`, `LocationFailure.swift` | Position and compass |
| `Compass.swift` | Angle maths for the radar |
| `Aircraft.swift`, `Schedule.swift`, `Usage.swift` | What the server sends (aircraft, boards, flights, allowances) |
| `RootView.swift`, `OverheadView.swift`, `SearchView.swift`, `AirportView.swift`, `SettingsView.swift` | Screens |
| `AircraftCard.swift`, `FlightViews.swift`, `RadarView.swift`, `FeedViews.swift`, `Theme.swift` | Components |

## Checks

```sh
scripts/logic-checks/run.sh
```

Compiles the pure logic (angles, drift, location errors, the server's answers, board rows, search text) and checks it. It needs only the Swift toolchain.

## Things to know

- The project uses default main-actor isolation. A closure that a system framework calls on another thread must be marked `@Sendable`, or the app is stopped by the system. This happened once in `Theme.swift`.
- iPhone is locked to portrait, because the compass reference is portrait.
