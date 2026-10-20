import SwiftUI

struct SettingsView: View {
    let store: FlightStore
    @State private var address = ""
    @State private var token = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                searchSection
                serverSection
                usageSection
                locationSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(SkyBackground())
            .navigationTitle("Settings")
            .task(id: store.serverAddress) { address = store.serverAddress }
            // Also loads when this screen first appears, and when a connection becomes available.
            .task(id: store.configuration != nil) { await store.refreshUsage() }
        }
    }

    private var searchSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.distance(store.radiusMeters))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: store.radiusMeters)
                    Spacer()
                    if store.radiusKm != FlightStore.defaultRadiusKm {
                        Button("Reset to 3 km") {
                            withAnimation(.snappy) { store.radiusKm = FlightStore.defaultRadiusKm }
                        }
                        .font(.footnote)
                    }
                }
                Slider(value: Bindable(store).radiusKm, in: FlightStore.radiusRange, step: 0.5) {
                    Text("Search distance")
                } minimumValueLabel: {
                    Text("1 km").font(.caption)
                } maximumValueLabel: {
                    Text("10 km").font(.caption)
                }
                .sensoryFeedback(.selection, trigger: store.radiusKm)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Search area")
        } footer: {
            Text("The Overhead tab lists aircraft within this distance of you. The Airport tab always looks around the nearest airport.")
        }
    }

    private var serverSection: some View {
        Section {
            TextField("Server address", text: $address)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(store.configuration == nil ? "Access token" : "New access token (optional)", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save connection") {
                if store.saveConnection(address: address, token: token) {
                    token = ""
                    address = store.serverAddress
                    Task { await store.refreshUsage() }
                }
            }
            .disabled(address.isEmpty)
            Button {
                Task { await store.testConnection() }
            } label: {
                HStack {
                    Text("Test connection")
                    Spacer()
                    testResult
                }
            }
            .disabled(store.configuration == nil || store.connectionTest == .testing)
            if let message = store.settingsMessage {
                Text(message).foregroundStyle(.secondary)
            }
            if let error = store.settingsError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Use the access token your backend was set up with. It is kept in this iPhone’s Keychain.")
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch store.connectionTest {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
        case .success:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.positive)
                .transition(.scale.combined(with: .opacity))
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.warning)
                .multilineTextAlignment(.trailing)
        }
    }

    private var usageSection: some View {
        Section {
            if let usage = store.usage {
                adsbRow(usage.adsbLol)
                openSkyRow(usage.opensky)
            } else if store.isLoadingUsage {
                HStack {
                    Text("Checking…").foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
            } else if store.configuration == nil {
                Text("Save the server address and token to see this.").foregroundStyle(.secondary)
            }
            if let error = store.usageError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
            }
        } header: {
            HStack {
                Text("Requests left")
                Spacer()
                Button {
                    Task { await store.refreshUsage() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.configuration == nil || store.isLoadingUsage)
                .accessibilityLabel("Refresh")
            }
        } footer: {
            if let since = store.usage?.adsbLol.countedSince {
                Text("ADSB.lol is counted by your server from \(since.formatted(date: .omitted, time: .shortened)). Requests before that, or from other devices on your network address, are not included. OpenSky’s number comes from OpenSky itself.")
            } else {
                Text("ADSB.lol is counted by your server. OpenSky’s number comes from OpenSky itself.")
            }
        }
    }

    private func adsbRow(_ adsb: Usage.AdsbLol) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("ADSB.lol")
                Text("main source").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(adsb.remaining) left")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(adsb.isRunningLow ? Theme.warning : .primary)
            }
            ProgressView(value: adsb.fractionUsed)
                .tint(adsb.isRunningLow ? Theme.warning : Theme.accent)
            Text("\(adsb.used) of \(adsb.dailyBudget) used in the last 24 hours")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .animation(.smooth, value: adsb)
    }

    private func openSkyRow(_ openSky: Usage.OpenSky) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("OpenSky")
            Text("backup").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !openSky.enabled {
                Text("Not set up").foregroundStyle(.secondary)
            } else if let credits = openSky.creditsRemaining {
                Text("\(credits.formatted()) credits left")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } else {
                Text("Unknown").foregroundStyle(.secondary)
            }
        }
        .animation(.smooth, value: openSky)
    }

    private var locationSection: some View {
        Section {
            LabeledContent("Location access", value: locationStatus)
            if store.location.authorization != .authorizedWhenInUse && store.location.authorization != .authorizedAlways {
                Button(store.location.isDenied ? "Open iOS Settings" : "Allow location") {
                    if store.location.isDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    } else {
                        store.location.requestAccessIfNeeded()
                    }
                }
            }
        } header: {
            Text("Location")
        } footer: {
            Text("ScanUp sends your position to your server only when you open the app or refresh a list. Nothing is sent in the background, and the server does not store it.")
        }
    }

    private var locationStatus: String {
        switch store.location.authorization {
        case .authorizedAlways, .authorizedWhenInUse: String(localized: "Allowed")
        case .denied: String(localized: "Off")
        case .restricted: String(localized: "Restricted")
        default: String(localized: "Not asked yet")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
        } header: {
            Text("About")
        } footer: {
            Text("Aircraft positions come from OpenSky Network and ADSB.lol. Airlines, routes and aircraft types come from adsbdb.")
        }
    }
}
