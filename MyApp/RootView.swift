import SwiftUI

enum AppTab: Hashable {
    case overhead, airport, settings
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = FlightStore()
    @State private var selection = AppTab.overhead

    private struct RefreshKey: Hashable {
        let tab: AppTab
        let isActive: Bool
        let isReady: Bool
        let isConfigured: Bool
        let isPaused: Bool
    }

    /// The compass runs only while the Overhead radar is on screen.
    private var wantsCompass: Bool { selection == .overhead && scenePhase == .active }

    private var refreshKey: RefreshKey {
        RefreshKey(tab: selection, isActive: scenePhase == .active,
                   isReady: store.isConfigurationLoaded, isConfigured: store.configuration != nil,
                   isPaused: store.isPaused)
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Overhead", systemImage: "airplane", value: AppTab.overhead) {
                OverheadView(store: store) { selection = .settings }
            }
            Tab("Airport", systemImage: "airplane.departure", value: AppTab.airport) {
                AirportView(store: store) { selection = .settings }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView(store: store)
            }
        }
        .tint(Theme.accent)
        .task { await store.start() }
        .onChange(of: wantsCompass, initial: true) { _, wanted in
            if wanted { store.location.startHeading() } else { store.location.stopHeading() }
        }
        .onChange(of: selection) { store.noteInteraction() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.noteInteraction() }
        }
        // Refreshes only while a list is on screen and the app is open. The server says how long to wait between
        // them, failures wait longer, and with no touch for a while it stops until the next one.
        .task(id: refreshKey) {
            let key = refreshKey
            guard key.isActive, key.isReady, !key.isPaused, key.tab != .settings else { return }
            while !Task.isCancelled {
                let wait = key.tab == .overhead ? await store.refreshNearby() : await store.refreshGround()
                if store.pauseIfIdle() { return }
                try? await Task.sleep(for: wait)
            }
        }
    }
}
