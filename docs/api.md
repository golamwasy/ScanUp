# ScanUp API (version 2)

The iPhone app asks a backend what is flying near it. The app sends its position only when it is open and refreshing. The backend finds aircraft with ADSB.lol, falling back to OpenSky, adds airline, route, aircraft type and registration from adsbdb.com, looks up schedules at AeroDataBox, and answers. This file describes what the app expects, so you can run your own backend. The backend the author uses is a separate, private project.

## Common rules

- Base URL: `https://your-server.example` (HTTPS origin only, no path, query, credentials or fragment).
- `Authorization: Bearer <app-token>` is required on every `/v1/` request. The token is a high-entropy secret chosen by the owner (`APP_TOKEN` on the server). The app keeps it in the Keychain.
- `POST` requests carry `Content-Type: application/json` and a `Content-Length` header. Bodies larger than 1024 bytes are refused (413, or 411 without a length).
- Responses are JSON with HTTP 200. Redirects must not be followed, and the token must never be sent to another host.
- Fields that are unknown are left out. They are never `null` and never the text "unknown".
- Do not log bearer tokens, request bodies or exact coordinates.

| Status | Meaning |
|---|---|
| 401 | Wrong or missing token |
| 411 / 413 | Missing content length / body too large |
| 422 | Invalid request (the response never describes the fields to an unauthenticated caller) |
| 429 | Rate limited by the server; honour `Retry-After` |
| 503 | No aircraft source could answer; wait `Retry-After` seconds (15 to 300, the time the paused sources need) |

## Refresh pace

The server decides how often the app refreshes, so it can change without an app update. `refresh_after_s` is 15 normally for nearby aircraft, and 30 when the backup source answered or when most of the daily request budget for ADSB.lol is used. For an airport board it is 1200 (20 minutes). The app clamps it to 10 to 120 seconds for aircraft and 60 to 1800 for boards, and stops refreshing when nobody is using it.

## `GET /v1/ping`

Checks the address and token. Returns `{"status":"ok"}` with a valid token and 401 without one. It sends no position and uses no data source. The app uses it for the "Test connection" button.

## `GET /v1/usage`

How much of each data source's request allowance is left. The app shows it in Settings.

```json
{
  "adsb_lol": { "used": 13, "daily_budget": 500, "remaining": 487, "counted_since": "2026-10-20T11:00:00Z", "next_free_at": "2026-10-21T11:02:00Z" },
  "opensky": { "enabled": true, "credits_remaining": 3991, "checked_at": "2026-10-20T11:20:00Z" },
  "flight_schedules": { "enabled": true, "remaining": 392, "monthly_limit": 400, "resets_at": "2026-11-21T07:34:00Z", "used_last_30_days": 8 }
}
```

- `adsb_lol`: `used` is the number of requests in the last 24 hours. ADSB.lol allows about 500 requests in any 24 hours. The server counts its own requests and saves their times in a file on a Docker volume, so the count survives restarts and deploys. It counts since `counted_since` (the first time the file was written, or the start of the server if saving is off), so it can be lower than ADSB.lol's own count when other devices on the same network address also use ADSB.lol. `next_free_at` is when the oldest counted request turns 24 hours old and stops counting; the count goes down by one then. There is no reset at midnight, because ADSB.lol's limit is a rolling 24 hours.
- `opensky`: `enabled` is false when no OpenSky credentials are set up, and then the other fields are left out. OpenSky only reports its remaining credits in the reply to a query, so a number older than 5 minutes is renewed with one tiny query (one credit). `credits_remaining` and `checked_at` are left out when it could not be read.
- `flight_schedules`: the allowance of the flight schedule provider (airport boards and flight search). `remaining` is what the provider itself last said is left this month, and `resets_at` when its month starts again; before the provider's first answer, `remaining` is an estimate from the server's own count and `resets_at` is left out. `enabled` is false when no key is set up. The server never spends the last 20 units.

## `POST /v1/nearby`

Aircraft in the air within a radius of the phone.

```json
{ "latitude": 60.3172, "longitude": 24.9633, "radius_m": 3000 }
```

`radius_m` is an integer from 500 to 10000.

```json
{
  "updated_at": "2026-10-20T11:23:39.727514Z",
  "refresh_after_s": 15,
  "source": "adsb.lol",
  "aircraft": [ { "...": "see Aircraft" } ]
}
```

`refresh_after_s` is how many seconds the app should wait before asking again (see Refresh pace). `source` is `adsb.lol` or `opensky`. Aircraft are sorted nearest first, at most 60, and only those with a position fresher than 60 seconds. Aircraft on the ground and surface vehicles are not included.

## `POST /v1/track`

Finds one aircraft that is in the air (or on the ground) and heard right now, anywhere in the world, by flight number,
callsign or registration. Request: `{"query": "AY1406", "latitude": 60.3, "longitude": 24.9}`. The position is only used
for the distance and bearing from the phone.

`query` is a flight number as on a ticket (`AY1406`, the airline's callsign code is looked up, so it becomes `FIN1406`),
a callsign (`FIN5DA`) or a registration (`OH-LXA`; the hyphen is needed, American `N393UP` works without). Spaces and
case do not matter. Text that cannot be one of these gets 422.

The answer is the same as `/v1/nearby`, with `source` always `adsb.lol`: `aircraft` is empty when nothing is heard under
that name (not in the air, or no coverage), otherwise up to five aircraft nearest first, described as in
[Aircraft](#aircraft). `elevation_deg` is left out beyond about 400 km, because the aircraft is below the horizon.
For an aircraft in the air the first match also carries `schedule` (`number`, `status`, `departure` and `arrival` as in
[Flight](#flight-in-boards-and-tracked-aircraft): scheduled, revised, predicted and actual times on the airport's own clock and in
UTC, terminal, gate), looked up by the ticket flight number (`flight_number`, from the route data, or the search text) at
the schedule provider. It is left out when the number is unknown, the provider is not set up, out of units or does not
list a leg between the aircraft's two airports. It costs 2 schedule units, shared for 10 minutes with other lookups of
that flight. Airlines often fly under a callsign that is not the ticket number (AY1549 flew as `FIN2L`). So when a ticket number is not heard
under the callsigns built from it, the schedule is asked (2 units, shared for 10 minutes): if it has a leg of that flight in the
air now, its callsign and registration are looked up too, and the aircraft found that way carries `schedule`. If no aircraft is
heard but the schedule knows the flight (it has landed, or is about to leave), the answer has `aircraft: []` and a top-level
`schedule` with the same fields, so the app can say what became of it. A flight that has landed is not looked for in the air.
A lookup costs one to three ADSB.lol requests of the 500 a day; answers are shared for 10 seconds. 503 with
`Retry-After` when ADSB.lol cannot be asked.

## Aircraft

| Field | Type | Notes |
|---|---|---|
| `id` | string | ICAO 24-bit address in lower-case hex, stable per airframe |
| `callsign` | string | Flight callsign, for example `FIN141` |
| `airline` | string | Airline name |
| `flight_number` | string | The number as on a ticket, for example `FR4622`, when the route data has one (some airlines fly under callsigns that are not a ticket number) |
| `schedule` | object | Only in `/v1/track`: departure and arrival times of the flight, see there |
| `origin`, `destination` | string | For example `Copenhagen (CPH)`. A route is a lookup by flight number, so it is left out when the aircraft is more than 300 km from the line between the two airports (airlines reuse numbers for other flights) |
| `origin_code`, `destination_code` | string | IATA code, or ICAO code when there is no IATA code |
| `type` | string | Aircraft type, for example `A350 941` |
| `registration` | string | For example `OH-LWM` |
| `altitude_ft` | integer | Barometric altitude, never below 0 (high air pressure can make it read below sea level). Left out on the ground |
| `speed_kt` | integer | Ground speed in knots |
| `heading_deg` | integer | Direction of travel, 0 to 359 |
| `vertical_rate_fpm` | integer | Feet per minute, negative when descending. Left out on the ground |
| `distance_m` | integer | Distance along the ground from the phone |
| `bearing_deg` | integer | Compass bearing from the phone to the aircraft, 0 to 359 |
| `phase` | string | `landing` or `taking_off` for an aircraft near an airport (within 15 km) that is less than 3,000 ft above the airport and descending or climbing at 300 ft/min or more. Left out otherwise |
| `elevation_deg` | integer | How high above the horizon the aircraft is seen, 0 to 90. Assumes the phone is at sea level, because the altitude is barometric. Left out on the ground |
| `on_ground` | boolean | |

`distance_m`, `bearing_deg` and `on_ground` are always present. `id` is always present.

## `GET /v1/aircraft/{registration}`

Age and delivery of one aircraft, from the schedule provider: `GET /v1/aircraft/OH-LXF`.

```json
{ "registration": "OH-LXF", "age_years": 24.8, "delivered": "2002-02-28", "first_flight": "2002-01-21", "seats": 174, "model": "Airbus A320" }
```

Fields the provider does not have are left out; for a registration it does not know, only `registration` comes back. `notice`
(`not_configured`, `allowance_used`, `denied`, `unavailable`) says why there is nothing, with status 200. A lookup costs 1
schedule unit and is kept for a week (in `/data/aircraft-details.json`, so it survives restarts; unknown registrations for a
day), so the same aircraft is free afterwards. Text that is not a registration (2 to 10 letters, digits or hyphens) gets 422.

## `GET /v1/airports/search?q=`

Airports for a code (IATA or ICAO), a city or a name, accent- and case-insensitive, best match first, at most 10. Needs 2 or more characters. It searches the server's own list of 3,291 airports with scheduled flights, so it costs nothing upstream.

```json
{ "airports": [ { "name": "Helsinki Vantaa Airport", "city": "Helsinki (Vantaa)", "iata": "HEL", "icao": "EFHK", "country": "FI" } ] }
```

## `POST /v1/board`

Departures and arrivals of an airport from 12 hours ago to about 11 hours from now (a provider call covers 12 hours, and the coming half starts an hour before now so that it overlaps the past half). Request either `{"code": "HEL"}` (an IATA or ICAO code from the airport search; a position may be sent as well to get the distance) or `{"latitude": 60.3172, "longitude": 24.9633}` for the nearest airport within 40 km.

`part` (optional) chooses what is sent: `"coming"` (from an hour ago to about 11 hours ahead, 2 units), `"past"` (the 12 hours before now, 2 units) or `"all"` (the default, both, 4 units). The app asks for `"coming"` and fetches `"past"` only when someone scrolls back, so a board that is only looked at costs 2 units, not 4.

```json
{
  "airport": { "name": "Helsinki Vantaa Airport", "city": "Helsinki (Vantaa)", "iata": "HEL", "icao": "EFHK", "country": "FI", "is_nearest": true, "distance_m": 450 },
  "updated_at": "2026-10-21T19:02:00Z",
  "refresh_after_s": 1200,
  "departures": [ FLIGHT, ... ],
  "arrivals": [ FLIGHT, ... ]
}
```

Lists are in order of the scheduled time at this airport. `updated_at` is when the oldest half of the data was fetched. `notice` says why the lists are old, short or empty: `not_configured` (no provider key), `allowance_used` (the month's units are nearly used up), `denied` (the key was refused), `unavailable` (the provider did not answer), `no_airport_nearby` (then `airport` is left out). When the provider cannot be asked, the last good lists (up to 6 hours old) are sent with the notice. An unknown code gets 404.

Cost: one board is two provider calls (2 units each); the coming half is reused for 20 minutes and the past half for 60 minutes, so opening the same board again is free, and a board left open costs about 8 units an hour. After a failed provider call no new call is made for 30 seconds (5 minutes when the key is refused, or as long as the provider asks after a rate limit).

## Flight (in boards and tracked aircraft)

| Field | Type | Notes |
|---|---|---|
| `number` | string | As the airline writes it, for example `AY 1406` |
| `callsign` | string | For example `FIN2PX`. Often left out |
| `status` | string | `expected`, `check_in`, `boarding`, `gate_closed`, `departed`, `en_route`, `approaching`, `arrived`, `delayed`, `canceled`, `canceled_uncertain`, `diverted` or `unknown` |
| `airline`, `airline_iata` | string | For example `Finnair`, `AY` |
| `departure`, `arrival` | object | One end of the flight, below |
| `aircraft_model` | string | For example `Airbus A320` |
| `registration` | string | For example `OH-LXI` |
| `distance_km` | integer | Great-circle distance; only in searches |

Each end: `airport` (`name`, and when known `city`, `iata`, `icao`, `country`), times `scheduled`, `revised` (the airline's latest estimate), `predicted` (the provider's own estimate) and `actual` (runway time), each `{"utc": "2026-10-21T19:20:00Z", "local": "2026-10-21T22:20:00+03:00"}` where `local` is that airport's own clock, and `terminal`, `gate`, `check_in`, `baggage_belt`. Everything except `airport` may be missing.

Data: flight schedules by AeroDataBox (attribution required by its terms). The free plan allows personal use only.

## `GET /health`

For monitoring. Without a token: `{"status":"ok"}`. With the token it also reports `detection_source`, `opensky_credits_remaining` once a query has run, `adsb_requests_last_24h`, and `deployed_ref` (the branch or tag and commit the server runs, see docs/switching-versions.md).
