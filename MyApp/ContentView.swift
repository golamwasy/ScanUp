import SwiftUI
import CoreLocation

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var monitor = ScanMonitor.shared

    var body: some View {
        NavigationStack {
            List {
                SharingStatusSection(monitor: monitor)
                SearchRadiusSection(monitor: monitor)
                HomeSection(monitor: monitor)
                QuietHoursSection(monitor: monitor)
                LocationStatusSection(monitor: monitor)
                BackendSettingsSection(monitor: monitor)
                AlertDeliverySection(telegramReady: monitor.telegramReady, hasUploaded: monitor.lastUpload != nil)
                SharingScheduleSection(respectsQuietHours: monitor.respectsQuietHours,
                                       wideSearch: monitor.wideSearch)
            }
            .navigationTitle("ScanUp")
            .task {
                await monitor.prepare()
                monitor.resume(inForeground: scenePhase != .background)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    monitor.resume(inForeground: true)
                } else if phase == .background {
                    monitor.resume(inForeground: false)
                    monitor.scheduleRefresh()
                }
            }
        }
    }
}

private struct SharingStatusSection: View {
    let monitor: ScanMonitor

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("Your location. Nearby flight alerts.", systemImage: "location.circle.fill")
                    .font(.title2.bold())
                if !monitor.hasConfiguration {
                    Label("Backend setup needed", systemImage: "server.rack")
                        .font(.headline)
                    Text("Your server will find nearby aircraft and send Telegram alerts. Add its access token when the backend is ready.")
                        .foregroundStyle(.secondary)
                } else if monitor.isBusy {
                    ProgressView { Text(monitor.status) }
                } else if monitor.isQuietHours && monitor.isSharing {
                    Label("Quiet hours", systemImage: "moon.fill")
                    Text("Location sharing is off until 09:00 Finnish time.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(monitor.status)
                }
                if let error = monitor.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let uploaded = monitor.lastUpload {
                    Text("Last accepted upload: \(uploaded.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)

            Button(monitor.isSharing ? "Pause sharing" : "Start sharing") {
                monitor.setSharing(!monitor.isSharing)
            }
            .disabled(!monitor.hasConfiguration || (!monitor.isSharing && monitor.isBusy))

            if monitor.isSharing {
                Button {
                    Task { await monitor.shareNow(manual: true) }
                } label: {
                    Label(monitor.isBusy ? "Sharing…" : "Share location now", systemImage: "arrow.up.circle")
                }
                .disabled(monitor.isBusy || monitor.isQuietHours)
            }
        } footer: {
            Text("Your backend uses your latest location to find nearby aircraft and send alerts to Telegram.")
        }
    }
}

private struct SearchRadiusSection: View {
    let monitor: ScanMonitor

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { monitor.wideSearch },
                                 set: { monitor.setWideSearch($0) })) {
                Label("Wide search (10 km)", systemImage: "dot.radiowaves.left.and.right")
            }
        } header: {
            Text("Search radius")
        } footer: {
            Text(monitor.wideSearch
                 ? "Your backend alerts for aircraft within 10 km. Expect more alerts, especially near an airport."
                 : "Your backend alerts for aircraft within 1 km. Turn on wide search to use 10 km.")
        }
    }
}

private struct HomeSection: View {
    let monitor: ScanMonitor

    var body: some View {
        Section {
            Label(monitor.home == nil ? "No home saved" : "Home saved",
                  systemImage: monitor.home == nil ? "house" : "house.fill")
            Button {
                Task { await monitor.setHomeHere() }
            } label: {
                Label(monitor.isSettingHome ? "Getting your location…" : "Use my current location as home",
                      systemImage: "location")
            }
            .disabled(monitor.isSettingHome || monitor.isQuietHours)
            Toggle(isOn: Binding(get: { monitor.sleepsAtHome }, set: { monitor.setSleepsAtHome($0) })) {
                Label("Sleep at home to save battery", systemImage: "battery.100")
            }
            .disabled(monitor.home == nil)
            if monitor.isResting {
                Label("Resting at home. GPS is off.", systemImage: "moon.zzz.fill")
                    .foregroundStyle(.secondary)
            }
            if monitor.home != nil {
                Button("Remove home", role: .destructive) { monitor.clearHome() }
            }
            if let message = monitor.homeMessage {
                Text(message).foregroundStyle(.secondary)
            }
        } header: {
            Text("Home")
        } footer: {
            Text("Stand at home when you save it. Within 200 m of home, ScanUp can stop using GPS and your backend watches your home instead. iOS may wake ScanUp when you leave, but not if you swipe it away in the app switcher, so leave it in the background. This needs Always location access. Your home is stored on your server.")
        }
    }
}

private struct QuietHoursSection: View {
    let monitor: ScanMonitor

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { monitor.respectsQuietHours },
                                 set: { monitor.setRespectsQuietHours($0) })) {
                Label("Observe quiet hours", systemImage: "moon.fill")
            }
            if !monitor.respectsQuietHours {
                Label("Quiet hours are off. Location is shared and Telegram alerts can arrive at any hour.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Quiet hours (testing)")
        } footer: {
            Text("Turn this off to test alerts between 00:00 and 09:00 Finnish time. The setting is sent to your backend with each upload. Turn it back on when you finish testing.")
        }
    }
}

private struct LocationStatusSection: View {
    let monitor: ScanMonitor

    var body: some View {
        Section {
            Text(monitor.permission)
            Text(monitor.backgroundStatus)
                .foregroundStyle(.secondary)
            if let location = monitor.lastLocation {
                LabeledContent("Latest fix") {
                    Text(location.timestamp, format: .dateTime.hour().minute().second())
                }
                LabeledContent("Accuracy") {
                    Text("±\(Int(location.horizontalAccuracy.rounded())) m")
                }
            }
            Button("Allow Always location access") { monitor.requestAlways() }
            if let settingsURL = URL(string: "app-settings:") {
                Link("Open location settings", destination: settingsURL)
            }
        } header: {
            Text("Location & background")
        } footer: {
            Text("Use Always and Precise Location for background sharing. Keeping location active uses battery. If updates stop, the backend must pause alerts once your last location is two minutes old.")
        }
    }
}

private struct BackendSettingsSection: View {
    let monitor: ScanMonitor
    @State private var address = ""
    @State private var token = ""

    var body: some View {
        Section {
            TextField("Server URL", text: $address)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(monitor.hasConfiguration ? "New access token (optional)" : "App access token", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save connection") {
                if monitor.saveConnection(address: address, token: token) {
                    token = ""
                    address = monitor.serverAddress
                }
            }
            .disabled(monitor.isSharing || monitor.isBusy || address.isEmpty)
            if let message = monitor.settingsMessage {
                Text(message).foregroundStyle(.secondary)
            }
            if let error = monitor.settingsError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Backend connection")
        } footer: {
            Text("Use the app token issued by your backend, not a Telegram bot token or Cloudflare password. It is stored in this iPhone’s Keychain. Pause sharing before editing the connection.")
        }
        .task { address = monitor.serverAddress }
        .disabled(monitor.isSharing)
    }
}

private struct AlertDeliverySection: View {
    let telegramReady: Bool
    let hasUploaded: Bool

    var body: some View {
        Section("Telegram alerts") {
            Label(telegramReady ? "Telegram connected on backend" : "Telegram setup pending",
                  systemImage: "paperplane")
            Text(hasUploaded
                 ? "The backend reports its Telegram connection status with each accepted upload."
                 : "Telegram status will appear after your backend accepts a location upload.")
                .foregroundStyle(.secondary)
            Text("Connect your Telegram bot on the server later. Enable Telegram notifications on this iPhone to receive flight alerts.")
            if let telegramURL = URL(string: "https://t.me/") {
                Link("Open Telegram", destination: telegramURL)
            }
        }
    }
}

private struct SharingScheduleSection: View {
    let respectsQuietHours: Bool
    let wideSearch: Bool

    var body: some View {
        Section("Monitoring schedule") {
            LabeledContent("Flight radius", value: wideSearch ? "10 km" : "1 km")
            LabeledContent("Backend flight checks", value: "Every 15 seconds")
            LabeledContent("Quiet hours in Finland", value: respectsQuietHours ? "00:00–09:00" : "Off (testing)")
            Text("The app aims to upload a fresh location every 15 seconds while iOS allows it to run. Both the app and backend must observe Finnish quiet hours, including daylight saving changes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("After overnight suspension or force-closing, opening the app ensures sharing resumes. The server must not use an expired location.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

