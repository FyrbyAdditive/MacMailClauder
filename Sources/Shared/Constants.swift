import Foundation

public enum Constants {
    /// Application support directory for MacMailClauder
    public static var applicationSupportURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MacMailClauder")
    }

    /// Configuration file path
    public static var configFileURL: URL {
        applicationSupportURL.appendingPathComponent("config.json")
    }

    /// Log file path
    public static var logFileURL: URL {
        applicationSupportURL.appendingPathComponent("mcp.log")
    }

    /// Mail library base path
    public static var mailLibraryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mail")
    }

    /// Find the Mail data directory (V10, V11, etc.)
    public static func findMailDataURL() -> URL? {
        let mailURL = mailLibraryURL
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(
            at: mailURL,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        // Find highest versioned directory (V10, V11, etc.)
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

    /// Envelope Index database path
    public static func envelopeIndexURL() -> URL? {
        guard let mailData = findMailDataURL() else { return nil }
        return mailData
            .appendingPathComponent("MailData")
            .appendingPathComponent("Envelope Index")
    }

    /// Claude Desktop config file path
    public static var claudeDesktopConfigURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Claude")
            .appendingPathComponent("claude_desktop_config.json")
    }
}
