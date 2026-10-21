import SwiftUI

struct SettingsView: View {
    let store: FlightStore
    @State private var address = ""
    @State private var token = ""
    /// Shows the address and token fields although a connection is saved.
    @State private var isEditing = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                // The same translucent cards as the lists, instead of the system's flat grey.
                searchSection.listRowBackground(Theme.card)
                serverSection.listRowBackground(Theme.card)
                usageSection.listRowBackground(Theme.card)
                locationSection.listRowBackground(Theme.card)
                testingSection.listRowBackground(Theme.card)
                aboutSection.listRowBackground(Theme.card)
            }
            .scrollContentBackground(.hidden)
            .background(SkyBackground())
            .navigationTitle("Settings")
            .task(id: store.serverAddress) { address = store.serverAddress }
            // Also loads when this screen first appears, and when a connection becomes available.
            .task(id: store.configuration != nil) {
                if store.configuration != nil, store.connectionTest == .idle { await store.testConnection() }
                await store.refreshUsage()
            }
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
            if store.configuration == nil || isEditing {
                connectionForm
            } else {
                connectionStatus
            }
            if let error = store.settingsError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
            }
        } header: {
            Text("Server")
        } footer: {
            Text(store.configuration == nil || isEditing
                 ? "Enter the address of your ScanUp server and the access token it was set up with. The token is kept in this iPhone’s Keychain."
                 : "The access token is kept in this iPhone’s Keychain.")
        }
    }

    /// The saved server with whether it answers, and the two things that can be done with it.
    @ViewBuilder
    private var connectionStatus: some View {
        let status = connectionStatus(for: store.connectionTest)
        HStack(spacing: 12) {
            Group {
                if store.connectionTest == .testing {
                    ProgressView()
                } else {
                    Image(systemName: status.symbol).foregroundStyle(status.tint)
                }
            }
            .font(.title3)
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.configuration?.baseURL.host() ?? store.serverAddress)
                Text(status.text)
                    .font(.footnote)
                    .foregroundStyle(status.tint)
            }
            Spacer()
        }
        .animation(.smooth, value: store.connectionTest)
        .accessibilityElement(children: .combine)
        Button("Test connection") {
            Task { await store.testConnection() }
        }
        .disabled(store.connectionTest == .testing)
        Button("Change server or token") {
            address = store.serverAddress
            store.settingsError = nil
            withAnimation(.snappy) { isEditing = true }
        }
    }

    /// The address and token fields, to connect for the first time or to change the saved connection.
    @ViewBuilder
    private var connectionForm: some View {
        TextField("Server address", text: $address)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        SecureField(store.configuration == nil ? "Access token" : "New access token (optional)", text: $token)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        Button(store.configuration == nil ? "Connect" : "Save changes") {
            if store.saveConnection(address: address, token: token) {
                token = ""
                address = store.serverAddress
                withAnimation(.snappy) { isEditing = false }
                Task {
                    await store.testConnection()
                    await store.refreshUsage()
                }
            }
        }
        .disabled(address.isEmpty || (store.configuration == nil && token.isEmpty))
        if store.configuration != nil {
            Button("Cancel", role: .cancel) {
                token = ""
                address = store.serverAddress
                store.settingsError = nil
                withAnimation(.snappy) { isEditing = false }
            }
        }
    }

    private func connectionStatus(for test: ConnectionTest) -> (symbol: String, tint: Color, text: String) {
        switch test {
        case .idle: ("lock.fill", .secondary, String(localized: "Token saved on this iPhone"))
        case .testing: ("clock", .secondary, String(localized: "Checking…"))
        case .success: ("checkmark.circle.fill", Theme.positive, String(localized: "Connected"))
        case .failed(let message): ("exclamationmark.triangle.fill", Theme.warning, message)
        }
    }

    private var usageSection: some View {
        Section {
            if let usage = store.usage {
                adsbRow(usage.adsbLol)
                openSkyRow(usage.opensky)
                if let schedules = usage.flightSchedules {
                    schedulesRow(schedules)
                }
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
            // Only worth saying when the allowance is nearly used. There is no reset at midnight: each request stops
            // counting 24 hours after it was made.
            if adsb.isRunningLow, let nextFreeAt = adsb.nextFreeAt {
                Label("Next one frees up \(Self.freeUpText(for: nextFreeAt))", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.vertical, 2)
        .animation(.smooth, value: adsb)
    }

    private static func freeUpText(for date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(date) ? String(localized: "at \(time)") : String(localized: "tomorrow at \(time)")
    }

    private func schedulesRow(_ schedules: Usage.FlightSchedules) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Flight schedules")
                Text("boards, search").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !schedules.enabled {
                    Text("Not set up").foregroundStyle(.secondary)
                } else if let remaining = schedules.remaining {
                    Text("\(remaining) left")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(schedules.isRunningLow ? Theme.warning : .primary)
                }
            }
            if schedules.enabled {
                ProgressView(value: schedules.fractionUsed)
                    .tint(schedules.isRunningLow ? Theme.warning : Theme.accent)
                Text(schedules.resetsAt.map { String(localized: "A board uses 4, a search 2. Renews on \($0.formatted(date: .abbreviated, time: .omitted)).") }
                     ?? String(localized: "A board uses 4, a search 2, each month."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .animation(.smooth, value: schedules)
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

    /// A fixed place for trying the app without travelling.
    private var testingSection: some View {
        Section {
            Toggle("Use a fake location", isOn: Bindable(store).useTestLocation.animation(.snappy))
            if store.useTestLocation {
                ForEach(TestLocation.all) { place in
                    Button {
                        store.testLocationIndex = place.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name).foregroundStyle(.primary)
                                Text(place.coordinatesText)
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.testLocationIndex == place.id {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Theme.accent)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(store.testLocationIndex == place.id ? .isSelected : [])
                    .transition(.opacity)
                }
            }
        } header: {
            Text("Testing")
        } footer: {
            Text("Aircraft are looked up around this place instead of where you are. Turn it off to use your real position.")
        }
        .animation(.snappy, value: store.testLocationIndex)
        .sensoryFeedback(.selection, trigger: store.testLocationIndex)
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
            Text("Aircraft positions come from OpenSky Network and ADSB.lol. Airlines, routes and aircraft types come from adsbdb. Flight schedules (airport boards and flight search) by AeroDataBox.")
        }
    }
}
