import Foundation
import MCP
import Shared

// Configure logging to stderr AND file (stdout is reserved for MCP JSON-RPC)
private var logFileHandle: FileHandle?

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logMessage = "[\(timestamp)] \(message)\n"

    // Write to stderr
    FileHandle.standardError.write(logMessage.data(using: .utf8)!)

    // Also write to log file
    if logFileHandle == nil {
        let logURL = Constants.logFileURL
        let dir = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logFileHandle = FileHandle(forWritingAtPath: logURL.path)
        logFileHandle?.seekToEndOfFile()
    }
    if let data = logMessage.data(using: .utf8) {
        logFileHandle?.write(data)
    }
}

log("MacMailClauderMCP starting...")

// Create and run the MCP server
let server = MailMCPServer()

Task {
    do {
        try await server.run()
    } catch {
        log("Server error: \(error)")
        exit(1)
    }
}

// Keep the process running
RunLoop.main.run()
