import SwiftUI

@main
struct MacMailClauderApp: App {
    @StateObject private var configStore = ConfigStore()
    @State private var showSettings = false

    var body: some Scene {
        MenuBarExtra("MacMailClauder", systemImage: "envelope.badge") {
            MenuBarView(configStore: configStore, showSettings: $showSettings)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(configStore: configStore)
        }
    }
}
