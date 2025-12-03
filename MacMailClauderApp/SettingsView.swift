import SwiftUI

struct SettingsView: View {
    @ObservedObject var configStore: ConfigStore
    @State private var availableMailboxes: [String] = []

    var body: some View {
        TabView {
            PermissionsTab(configStore: configStore)
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }

            ScopeTab(configStore: configStore, availableMailboxes: $availableMailboxes)
                .tabItem {
                    Label("Scope", systemImage: "scope")
                }

            SetupTab(configStore: configStore)
                .tabItem {
                    Label("Setup", systemImage: "gear")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .padding()
        .frame(width: 500, height: 400)
        .onAppear {
            availableMailboxes = configStore.discoverMailboxes()
        }
    }
}

// MARK: - Permissions Tab

struct PermissionsTab: View {
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        Form {
            Section("Email Access") {
                Toggle("Search Emails", isOn: $configStore.config.permissions.searchEmails)
                Toggle("List Emails", isOn: $configStore.config.permissions.listEmails)
                Toggle("Get Email Details", isOn: $configStore.config.permissions.getEmail)
                Toggle("Read Email Body", isOn: $configStore.config.permissions.getEmailBody)
                Toggle("Get Email Links", isOn: $configStore.config.permissions.getEmailLink)
            }

            Section("Mailbox Access") {
                Toggle("List Mailboxes", isOn: $configStore.config.permissions.listMailboxes)
            }

            Section("Attachment Access") {
                Toggle("List Attachments", isOn: $configStore.config.permissions.listAttachments)
                Toggle("Get Attachment Content", isOn: $configStore.config.permissions.getAttachment)
                Toggle("Extract Text from Attachments", isOn: $configStore.config.permissions.extractAttachmentContent)
                Toggle("Search Attachments", isOn: $configStore.config.permissions.searchAttachments)
            }
        }
        .formStyle(.grouped)
        .onChange(of: configStore.config.permissions) {
            configStore.save()
        }
    }
}

// MARK: - Scope Tab

struct ScopeTab: View {
    @ObservedObject var configStore: ConfigStore
    @Binding var availableMailboxes: [String]
    @State private var availableAccounts: [AccountInfo] = []

    private func isAccountEnabled(_ account: AccountInfo) -> Binding<Bool> {
        Binding(
            get: { configStore.config.scope.enabledAccounts.contains(account.email) },
            set: { enabled in
                if enabled {
                    if !configStore.config.scope.enabledAccounts.contains(account.email) {
                        configStore.config.scope.enabledAccounts.append(account.email)
                    }
                } else {
                    configStore.config.scope.enabledAccounts.removeAll { $0 == account.email }
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("Account Access") {
                if availableAccounts.isEmpty {
                    Text("No email accounts found")
                        .foregroundColor(.secondary)
                } else {
                    Text("Enable accounts Claude can access:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(availableAccounts) { account in
                        Toggle(isOn: isAccountEnabled(account)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.email)
                                if let description = account.accountDescription, !description.isEmpty {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            Section("Date Range") {
                Picker("Show emails from", selection: $configStore.config.scope.dateRange) {
                    ForEach(MacMailClauderConfig.DateRange.allCases, id: \.self) { range in
                        Text(range.displayName).tag(range)
                    }
                }

                if configStore.config.scope.dateRange == .custom {
                    DatePicker(
                        "Start Date",
                        selection: Binding(
                            get: { configStore.config.scope.customStartDate ?? Date() },
                            set: { configStore.config.scope.customStartDate = $0 }
                        ),
                        displayedComponents: .date
                    )
                }
            }

            Section("Excluded Mailboxes") {
                ForEach(configStore.config.scope.excludedMailboxes, id: \.self) { mailbox in
                    HStack {
                        Text(mailbox)
                        Spacer()
                        Button(action: {
                            configStore.config.scope.excludedMailboxes.removeAll { $0 == mailbox }
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Menu("Add Excluded Mailbox") {
                    ForEach(availableMailboxes.filter { !configStore.config.scope.excludedMailboxes.contains($0) }, id: \.self) { mailbox in
                        Button(mailbox) {
                            configStore.config.scope.excludedMailboxes.append(mailbox)
                        }
                    }
                }
            }

            Section("Limits") {
                Stepper(
                    "Max Results: \(configStore.config.scope.maxResults)",
                    value: $configStore.config.scope.maxResults,
                    in: 10...500,
                    step: 10
                )
            }
        }
        .formStyle(.grouped)
        .onAppear {
            availableAccounts = configStore.discoverAccounts()
        }
        .onChange(of: configStore.config.scope.enabledAccounts) {
            configStore.save()
        }
        .onChange(of: configStore.config.scope.dateRange) {
            configStore.save()
        }
        .onChange(of: configStore.config.scope.excludedMailboxes) {
            configStore.save()
        }
        .onChange(of: configStore.config.scope.maxResults) {
            configStore.save()
        }
    }
}

// MARK: - Setup Tab

struct SetupTab: View {
    @ObservedObject var configStore: ConfigStore
    @State private var configureError: String?

    var body: some View {
        Form {
            Section("MacMailClauder Full Disk Access") {
                HStack {
                    Image(systemName: configStore.fullDiskAccessEnabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(configStore.fullDiskAccessEnabled ? .green : .red)
                    Text("Full Disk Access")
                    Spacer()
                    if !configStore.fullDiskAccessEnabled {
                        Button("Fix") {
                            configStore.openFullDiskAccessSettings()
                        }
                    }
                }

                if !configStore.fullDiskAccessEnabled {
                    Text("MacMailClauder needs Full Disk Access to discover email accounts. Click 'Fix' to open System Settings, then enable MacMailClauder in the list.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Claude Desktop Integration") {
                HStack {
                    Image(systemName: configStore.claudeDesktopConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(configStore.claudeDesktopConfigured ? .green : .orange)
                    Text("MCP Server Configured")
                    Spacer()
                    if !configStore.claudeDesktopConfigured {
                        Button("Configure") {
                            do {
                                try configStore.configureClaudeDesktop()
                                configureError = nil
                            } catch {
                                configureError = error.localizedDescription
                            }
                        }
                    }
                }

                if let error = configureError {
                    Text("Error: \(error)")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if !configStore.claudeDesktopConfigured {
                    Text("Click 'Configure' to automatically add MacMailClauder to Claude Desktop's MCP servers. You'll need to restart Claude Desktop after configuration.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Information") {
                LabeledContent("Config File") {
                    Text(Constants.configFileURL.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                LabeledContent("Claude Config") {
                    Text(Constants.claudeDesktopConfigURL.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            configStore.checkPermissions()
        }
    }
}

// MARK: - About Tab

struct AboutTab: View {
    private var appName: String { "MacMailClauder" }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Company Logo
            Image("CompanyLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 80)
                .padding(.bottom, 8)

            // App Name with gradient
            Text(appName)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .padding(.top, 16)

            Text(versionText)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.top, 4)

            // Description
            Text("Mail.app integration for Claude Desktop")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.top, 12)

            // Feature badges
            HStack(spacing: 12) {
                FeatureBadge(icon: "magnifyingglass", text: "Search")
                FeatureBadge(icon: "envelope.open", text: "Read")
                FeatureBadge(icon: "paperclip", text: "Attachments")
            }
            .padding(.top, 16)

            Spacer()

            // Footer
            VStack(spacing: 4) {
                Divider()
                    .padding(.horizontal, 40)
                    .padding(.bottom, 8)

                Text("© 2025 Fyrby Additive Manufacturing & Engineering")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Link(destination: URL(string: "https://fyrbyadditive.com")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                        Text("fyrbyadditive.com")
                    }
                    .font(.caption)
                }
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FeatureBadge: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.1))
        )
        .foregroundColor(.accentColor)
    }
}

#Preview {
    SettingsView(configStore: ConfigStore())
}
