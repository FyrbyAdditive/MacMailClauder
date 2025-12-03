import Foundation
import Shared

/// Manages loading and saving of MacMailClauder configuration
class ConfigManager {
    private let fileManager = FileManager.default

    /// Load configuration from disk, or return defaults if not found
    func load() -> MacMailClauderConfig {
        let configURL = Constants.configFileURL

        guard fileManager.fileExists(atPath: configURL.path) else {
            log("No config file found, using defaults")
            return MacMailClauderConfig()
        }

        do {
            let data = try Data(contentsOf: configURL)
            let decoder = JSONDecoder()
            let config = try decoder.decode(MacMailClauderConfig.self, from: data)
            return config
        } catch {
            log("Error loading config: \(error), using defaults")
            return MacMailClauderConfig()
        }
    }

    /// Save configuration to disk
    func save(_ config: MacMailClauderConfig) throws {
        let configURL = Constants.configFileURL

        // Ensure directory exists
        let directory = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL)

        log("Config saved to \(configURL.path)")
    }
}
