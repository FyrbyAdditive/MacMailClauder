import Foundation
import SwiftUI

/// Observable store for MacMailClauder configuration
@MainActor
class ConfigStore: ObservableObject {
    @Published var config: MacMailClauderConfig
    @Published var claudeDesktopConfigured: Bool = false

    private let fileManager = FileManager.default

    init() {
        self.config = ConfigStore.loadConfig()
        checkPermissions()
    }

    // MARK: - Persistence

    private static func loadConfig() -> MacMailClauderConfig {
        let configURL = Constants.configFileURL

        guard FileManager.default.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(MacMailClauderConfig.self, from: data) else {
            return MacMailClauderConfig()
        }

        return config
    }

    func save() {
        let configURL = Constants.configFileURL

        do {
            // Ensure directory exists
            let directory = configURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configURL)
        } catch {
            print("Error saving config: \(error)")
        }
    }

    // MARK: - Permission Checks

    func checkPermissions() {
        claudeDesktopConfigured = checkClaudeDesktopConfig()
    }

    private func checkClaudeDesktopConfig() -> Bool {
        let configURL = Constants.claudeDesktopConfigURL

        guard fileManager.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else {
            return false
        }

        return servers["macmail"] != nil
    }

    // MARK: - Claude Desktop Configuration

    func configureClaudeDesktop() throws {
        let configURL = Constants.claudeDesktopConfigURL

        // Ensure Claude directory exists
        let directory = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Read existing config or create new one
        var config: [String: Any] = [:]
        if fileManager.fileExists(atPath: configURL.path),
           let data = try? Data(contentsOf: configURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = existing
        }

        // Get or create mcpServers
        var servers = (config["mcpServers"] as? [String: Any]) ?? [:]

        // Get path to MCP server executable
        let mcpServerPath = getMCPServerPath()

        // Add our server
        servers["macmail"] = [
            "command": mcpServerPath
        ]

        config["mcpServers"] = servers

        // Write back
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL)

        // Update state
        claudeDesktopConfigured = true
    }

    private func getMCPServerPath() -> String {
        // Check if we're in an app bundle
        if let bundlePath = Bundle.main.executablePath {
            let appContents = URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
            let mcpPath = appContents.appendingPathComponent("MacMailClauderMCP").path
            if fileManager.fileExists(atPath: mcpPath) {
                return mcpPath
            }
        }

        // Fall back to development path
        let devPath = "/Users/tim/VSCode/MacMailClauder/.build/debug/MacMailClauderMCP"
        if fileManager.fileExists(atPath: devPath) {
            return devPath
        }

        // Default installed path
        return "/Applications/MacMailClauder.app/Contents/MacOS/MacMailClauderMCP"
    }

    // MARK: - Mailbox Discovery

    func discoverMailboxes() -> [String] {
        guard let mailDataURL = Constants.findMailDataURL() else {
            return []
        }

        var mailboxes: [String] = []

        // Scan for .mbox directories
        if let enumerator = fileManager.enumerator(at: mailDataURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in enumerator {
                if url.pathExtension == "mbox" {
                    let name = url.deletingPathExtension().lastPathComponent
                    if !mailboxes.contains(name) {
                        mailboxes.append(name)
                    }
                }
            }
        }

        return mailboxes.sorted()
    }

    // MARK: - Account Discovery

    func discoverAccounts() -> [AccountInfo] {
        // First, find which account UUIDs have actual Mail data folders
        // Only these are truly active mail accounts
        let activeMailUUIDs = getActiveMailAccountUUIDs()

        // Read from ~/Library/Accounts/Accounts4.sqlite
        let accountsPath = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Accounts/Accounts4.sqlite").path

        guard fileManager.isReadableFile(atPath: accountsPath) else {
            print("Cannot read Accounts database at \(accountsPath)")
            return []
        }

        var accounts: [AccountInfo] = []

        // First, build a map of all accounts with their parent relationships
        // Some Mail folder UUIDs don't have a username directly - they inherit from parent
        var pkToIdentifier: [String: String] = [:]  // Z_PK -> ZIDENTIFIER
        var identifierToInfo: [String: (username: String?, description: String?, parentPK: String?)] = [:]

        // Query all accounts
        let allAccountsProcess = Process()
        allAccountsProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        allAccountsProcess.arguments = [
            accountsPath,
            "-separator", "|||",
            "SELECT Z_PK, ZIDENTIFIER, ZACCOUNTDESCRIPTION, ZUSERNAME, ZPARENTACCOUNT FROM ZACCOUNT"
        ]

        let allPipe = Pipe()
        allAccountsProcess.standardOutput = allPipe
        allAccountsProcess.standardError = FileHandle.nullDevice

        do {
            try allAccountsProcess.run()
            allAccountsProcess.waitUntilExit()

            let data = allPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                for line in lines {
                    let parts = line.components(separatedBy: "|||")
                    if parts.count >= 5 {
                        let pk = parts[0]
                        let identifier = parts[1]
                        let description = parts[2].isEmpty ? nil : parts[2]
                        let username = parts[3].isEmpty ? nil : parts[3]
                        let parentPK = parts[4].isEmpty ? nil : parts[4]

                        pkToIdentifier[pk] = identifier
                        identifierToInfo[identifier] = (username: username, description: description, parentPK: parentPK)
                    }
                }
            }
        } catch {
            print("Error reading all accounts: \(error)")
            return []
        }

        // Now process active Mail folder UUIDs, resolving parent accounts as needed
        for uuid in activeMailUUIDs {
            guard let info = identifierToInfo[uuid] else { continue }

            var username = info.username
            var description = info.description

            // If no username, try to resolve via parent
            if username == nil || username?.isEmpty == true {
                if let parentPK = info.parentPK,
                   let parentIdentifier = pkToIdentifier[parentPK],
                   let parentInfo = identifierToInfo[parentIdentifier] {
                    username = parentInfo.username
                    if description == nil || description?.isEmpty == true {
                        description = parentInfo.description
                    }
                }
            }

            // Skip if we still don't have a username
            guard let finalUsername = username, !finalUsername.isEmpty else { continue }

            // Skip if already have this email
            if !accounts.contains(where: { $0.email == finalUsername }) {
                accounts.append(AccountInfo(
                    identifier: uuid,
                    email: finalUsername,
                    accountDescription: description
                ))
            }
        }

        return accounts.sorted { $0.email < $1.email }
    }

    /// Get UUIDs of accounts that have active Mail data folders (not orphaned)
    private func getActiveMailAccountUUIDs() -> Set<String> {
        var activeUUIDs = Set<String>()

        // Find the Mail data directory (V10, V9, etc.)
        let mailDir = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")

        do {
            let contents = try fileManager.contentsOfDirectory(at: mailDir, includingPropertiesForKeys: nil)
            for url in contents {
                let name = url.lastPathComponent
                // Look for version directories like V10
                if name.hasPrefix("V"), name.dropFirst().allSatisfy({ $0.isNumber }) {
                    // Scan this version directory for account folders
                    let versionContents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    for accountUrl in versionContents {
                        let accountName = accountUrl.lastPathComponent
                        // Skip MailData, orphaned accounts, and non-UUID folders
                        if accountName == "MailData" ||
                           accountName.hasPrefix("Orphaned") ||
                           accountName.hasPrefix(".") {
                            continue
                        }
                        // Check if it looks like a UUID (8-4-4-4-12 format)
                        if isValidUUID(accountName) {
                            activeUUIDs.insert(accountName)
                        }
                    }
                }
            }
        } catch {
            print("Error scanning Mail directory: \(error)")
        }

        return activeUUIDs
    }

    /// Check if a string looks like a valid UUID
    private func isValidUUID(_ string: String) -> Bool {
        let uuidRegex = try? NSRegularExpression(
            pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$",
            options: .caseInsensitive
        )
        return uuidRegex?.firstMatch(
            in: string,
            options: [],
            range: NSRange(location: 0, length: string.utf16.count)
        ) != nil
    }
}

// MARK: - Account Info

struct AccountInfo: Identifiable, Equatable {
    let identifier: String  // UUID from Accounts database
    let email: String       // Email address (used as key in config)
    let accountDescription: String?  // Display name like "Work Gmail"

    var id: String { identifier }

    var displayName: String {
        if let desc = accountDescription, !desc.isEmpty {
            return "\(email) (\(desc))"
        }
        return email
    }
}

// MARK: - Config Model (duplicated from Shared for app use)

struct MacMailClauderConfig: Codable {
    var version: Int
    var permissions: Permissions
    var scope: Scope

    init(
        version: Int = 1,
        permissions: Permissions = Permissions(),
        scope: Scope = Scope()
    ) {
        self.version = version
        self.permissions = permissions
        self.scope = scope
    }

    struct Permissions: Codable, Equatable {
        var searchEmails: Bool
        var searchAttachments: Bool
        var getEmail: Bool
        var getEmailBody: Bool
        var getAttachment: Bool
        var extractAttachmentContent: Bool
        var listMailboxes: Bool
        var listEmails: Bool
        var listAttachments: Bool
        var getEmailLink: Bool

        init(
            searchEmails: Bool = true,
            searchAttachments: Bool = true,
            getEmail: Bool = true,
            getEmailBody: Bool = true,
            getAttachment: Bool = true,
            extractAttachmentContent: Bool = true,
            listMailboxes: Bool = true,
            listEmails: Bool = true,
            listAttachments: Bool = true,
            getEmailLink: Bool = true
        ) {
            self.searchEmails = searchEmails
            self.searchAttachments = searchAttachments
            self.getEmail = getEmail
            self.getEmailBody = getEmailBody
            self.getAttachment = getAttachment
            self.extractAttachmentContent = extractAttachmentContent
            self.listMailboxes = listMailboxes
            self.listEmails = listEmails
            self.listAttachments = listAttachments
            self.getEmailLink = getEmailLink
        }
    }

    struct Scope: Codable, Equatable {
        var dateRange: DateRange
        var customStartDate: Date?
        var excludedMailboxes: [String]
        var allowedMailboxes: [String]?
        var enabledAccounts: [String]  // Account emails that are enabled (allowlist)
        var maxResults: Int

        init(
            dateRange: DateRange = .all,
            customStartDate: Date? = nil,
            excludedMailboxes: [String] = ["Trash", "Junk"],
            allowedMailboxes: [String]? = nil,
            enabledAccounts: [String] = [],  // Empty = no accounts accessible until user enables
            maxResults: Int = 100
        ) {
            self.dateRange = dateRange
            self.customStartDate = customStartDate
            self.excludedMailboxes = excludedMailboxes
            self.allowedMailboxes = allowedMailboxes
            self.enabledAccounts = enabledAccounts
            self.maxResults = maxResults
        }
    }

    enum DateRange: String, Codable, CaseIterable, Equatable {
        case all
        case lastYear
        case lastSixMonths
        case lastMonth
        case lastWeek
        case custom

        var displayName: String {
            switch self {
            case .all: return "All Time"
            case .lastYear: return "Last Year"
            case .lastSixMonths: return "Last 6 Months"
            case .lastMonth: return "Last Month"
            case .lastWeek: return "Last Week"
            case .custom: return "Custom"
            }
        }
    }
}

// MARK: - Constants (duplicated from Shared for app use)

enum Constants {
    static var applicationSupportURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MacMailClauder")
    }

    static var configFileURL: URL {
        applicationSupportURL.appendingPathComponent("config.json")
    }

    static var mailLibraryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mail")
    }

    static func findMailDataURL() -> URL? {
        let mailURL = mailLibraryURL
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(
            at: mailURL,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        let versionDirs = contents.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("V") && name.dropFirst().allSatisfy { $0.isNumber }
        }

        let sorted = versionDirs.sorted { a, b in
            let aNum = Int(a.lastPathComponent.dropFirst()) ?? 0
            let bNum = Int(b.lastPathComponent.dropFirst()) ?? 0
            return aNum > bNum
        }

        return sorted.first
    }

    static var claudeDesktopConfigURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Claude")
            .appendingPathComponent("claude_desktop_config.json")
    }
}
