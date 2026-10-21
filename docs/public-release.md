# Putting ScanUp on the App Store or Google Play

Notes for later. ScanUp today is a personal app: one user, a home server behind a Cloudflare tunnel, a shared access token typed into Settings, and free community data sources. Opening it to the public changes several of these.

## What could block you, in order

### 1. The data source (decide this first)
- **Flight schedules (airport boards, times of a tracked flight) come from AeroDataBox on the free RapidAPI plan: 400 units a month, personal use only (commercial use is not allowed on that plan), and the app must credit AeroDataBox (it does, in Settings and under every board). A public release needs a paid plan or another provider.**
- ADSB.lol and OpenSky are free community or academic services. OpenSky is for non-commercial use. ADSB.lol allows about 500 requests in any 24 hours per address, which a few dozen users would use up. Read each service's current terms before publishing.
- Realistic choices: a paid licence (FlightAware, Flightradar24 or ADS-B Exchange sell APIs; the cost grows with users), or your own ADS-B receivers (cheap, but they cover only a limited area).
- Shared caching helps a lot: answer many users from one result per area (a few kilometres wide) for 5 to 10 seconds, so upstream requests do not grow with the number of users.
- Routes come from adsbdb by flight number, so they can be wrong when an airline reuses a number. The server drops a route the aircraft is more than 300 km from, but it cannot know the true one. Commercial schedule data (Cirium, OAG) is what the big apps use for reliable routes.

### 2. Access and abuse protection
- Now: one shared token. A public app cannot ship a shared token, because anyone could read it out of the app.
- Public: per-device proof that a request comes from the real app (Apple App Attest, Google Play Integrity), per-device rate limits, monitoring and alerts.

### 3. Hosting
- A home server and a tunnel are not dependable enough for the public. Move to a small cloud server or managed service with uptime alerts and backups. Expect a few euros to tens of euros a month to start, more with traffic. Check current prices.

### 4. Changes inside the app
- Remove the server address and token screen; the app must work straight after install.
- Apple review needs the app to work for the reviewer at once. Today it asks for a token, so it would be rejected.
- Hide or remove the fake-location testing option in the public build.
- Add a first-run explanation of why location is needed, and a "not for navigation or safety" notice.

### 5. Privacy and legal
- A privacy policy page and a support contact, on a website.
- The user's position reaches your server, so declare that in the store privacy forms. EU privacy law applies (you are in Finland). The server does not store positions, which helps; check the logs, which can hold IP addresses.
- Credit the data sources as their licences require. Check that the name "ScanUp" is not taken.

### 6. The stores
- Apple: Developer Program (about $99 a year). Needs screenshots, a description, an age rating, privacy answers and a review. The privacy manifest is already in the app. TestFlight allows up to 10,000 testers, builds last 90 days.
- Google Play: about $25 once. There is no Android app yet; it would be a second app (native or a shared toolkit). The server's JSON interface does not depend on the platform, so the backend would not change. New personal accounts may need a period of closed testing first; check the current rules.

## A sensible order
1. Settle the data licence and the costs. If that does not work, nothing else matters.
2. Build per-device access, area caching and cloud hosting.
3. Change the app so it works without setup, then write the policy pages.
4. Run TestFlight with friends to learn the real load.
5. Submit to the App Store; decide about Android last.

If it is only for friends, skip most of this: TestFlight, an invitation code and your current server with a bigger data allowance would be enough.

## Where flight trackers get their data (for context)
- Collection: ADS-B (aircraft broadcast position on 1090 MHz; a USB radio and antenna, about EUR 50, receive it within roughly 200 to 400 km), MLAT (position from signal timing across several receivers), satellite ADS-B (Aireon, Spire; oceans), official air-traffic feeds (such as the FAA, some delayed), and airline schedules and flight plans (Cirium, OAG).
- Flightradar24, RadarBox and Plane Finder: mostly their own volunteer receiver networks, plus MLAT, satellites and official feeds. FlightAware: its own network (PiAware), satellites and official feeds, sold as paid APIs. ADS-B Exchange: crowd-sourced and unfiltered, paid API. Flighty and trip apps: licensed schedule and status data plus live positions.
- ScanUp: ADSB.lol first, OpenSky as backup, adsbdb for airline, type, registration and route. Free alternatives: adsb.fi and airplanes.live.
- Idea: an ADS-B receiver on the home server, read by the backend, would give local aircraft with no request limits (range depends on the antenna).
