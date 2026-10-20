import SwiftUI

enum AppTab: Hashable {
    case overhead, airport, settings
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = FlightStore()
    @State private var selection = AppTab.overhead

    /// Aircraft are refreshed every 15 seconds, only while a list is on screen and the app is open.
    private static let refreshInterval = Duration.seconds(15)

    private struct RefreshKey: Hashable {
        let tab: AppTab
        let isActive: Bool
        let isReady: Bool
        let isConfigured: Bool
    }

    private var refreshKey: RefreshKey {
        RefreshKey(tab: selection, isActive: scenePhase == .active,
                   isReady: store.isConfigurationLoaded, isConfigured: store.configuration != nil)
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
        .task(id: refreshKey) {
            let key = refreshKey
            guard key.isActive, key.isReady, key.tab != .settings else { return }
            while !Task.isCancelled {
                if key.tab == .overhead {
                    await store.refreshNearby()
                } else {
                    await store.refreshGround()
                }
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }
}
