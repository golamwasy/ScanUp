# ScanUp

An iPhone app that shows what is flying around you. Open it and it asks your own server for the aircraft near your position.

- **Overhead:** aircraft within a distance you choose (3 km by default, up to 10 km). A radar that turns with the phone's compass shows where each one is. Tap an aircraft for its route, type, registration, altitude, speed and where in the sky to look.
- **Airport:** the aircraft on the ground at the nearest airport.
- **Settings:** the server address and token, the search distance, the data sources' remaining requests, and the location status.

The position is read only while the app is open, and it is sent only to the server you set up. Nothing runs in the background. The server is [ScanUp-Backend](https://github.com/golamwasy/ScanUp-Backend), and the API the app talks to is described in its `API_CONTRACT.md`.

## Build

Open `ScanUp.xcodeproj` in Xcode (iOS 27 and the Swift 6 language mode), choose a device and run. Enter the server address and the access token in Settings. The token is kept in the iPhone's Keychain.

## Layout

| File | What it holds |
|---|---|
| `FlightStore.swift` | State of the three screens, refresh pacing, back-off, idle pause |
| `BackendClient.swift` | The server connection, token storage and request code |
| `LocationFetcher.swift`, `LocationFailure.swift` | Position and compass |
| `Compass.swift` | Angle maths for the radar |
| `Aircraft.swift`, `Usage.swift` | What the server sends |
| `RootView.swift`, `OverheadView.swift`, `AirportView.swift`, `SettingsView.swift` | Screens |
| `AircraftCard.swift`, `RadarView.swift`, `FeedViews.swift`, `Theme.swift` | Components |

## Checks

```sh
scripts/logic-checks/run.sh
```

Compiles the pure logic (angles, drift, location errors, the server's answers) and checks it. It needs only the Swift toolchain.

## Things to know

- The project uses default main-actor isolation. A closure that a system framework calls on another thread must be marked `@Sendable`, or the app is stopped by the system. This happened once in `Theme.swift`.
- iPhone is locked to portrait, because the compass reference is portrait.
