import SwiftUI

struct MenuBarView: View {
    @ObservedObject var configStore: ConfigStore
    @Binding var showSettings: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "envelope.badge")
                    .font(.title2)
                Text("MacMailClauder")
                    .font(.headline)
                Spacer()
            }
            .padding(.bottom, 4)

            Divider()

            // Status Section
            VStack(alignment: .leading, spacing: 8) {
                StatusRow(
                    title: "Claude Desktop Configured",
                    isEnabled: configStore.claudeDesktopConfigured,
                    action: {
                        try? configStore.configureClaudeDesktop()
                    }
                )
            }

            Divider()

            // Actions
            HStack {
                Button("Settings...") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(width: 280)
        .onAppear {
            configStore.checkPermissions()
        }
    }
}

struct StatusRow: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: isEnabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(isEnabled ? .green : .orange)

            Text(title)
                .font(.subheadline)

            Spacer()

            if !isEnabled {
                Button("Fix") {
                    action()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }
}

#Preview {
    MenuBarView(configStore: ConfigStore(), showSettings: .constant(false))
}
