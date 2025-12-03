import Foundation
import MCP
import Shared

/// Main MCP server for MacMailClauder
actor MailMCPServer {
    private var server: Server?
    private let configManager = ConfigManager()
    private var mailDatabase: MailDatabase?

    func run() async throws {
        log("Initializing MCP server...")

        // Initialize the mail database
        do {
            mailDatabase = try MailDatabase()
            log("Mail database connected")
        } catch {
            log("Warning: Could not connect to mail database: \(error)")
            // Continue anyway - tools will return appropriate errors
        }

        // Create the MCP server
        server = Server(
            name: "MacMailClauder",
            version: "1.0.0",
            capabilities: .init(
                tools: .init(listChanged: false)
            )
        )

        guard let server = server else {
            throw MCPError.internalError("Failed to create server")
        }

        // Register tool handlers
        await registerToolHandlers(server: server)

        // Create stdio transport
        let transport = StdioTransport()

        log("Starting MCP server on stdio...")
        try await server.start(transport: transport)

        log("MCP server started, waiting for requests...")
        await server.waitUntilCompleted()
    }

    private func registerToolHandlers(server: Server) async {
        // List tools handler
        await server.withMethodHandler(ListTools.self) { [weak self] _ in
            guard let self = self else {
                return ListTools.Result(tools: [])
            }
            return await self.listTools()
        }

        // Call tool handler
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self = self else {
                throw MCPError.internalError("Server not available")
            }
            return try await self.callTool(name: params.name, arguments: params.arguments)
        }
    }

    private func listTools() -> ListTools.Result {
        let config = configManager.load()
        var tools: [Tool] = []

        if config.permissions.listMailboxes {
            tools.append(Tool(
                name: "list_mailboxes",
                description: "List all available mailboxes/folders in Mail.app",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "required": .array([])
                ])
            ))
        }

        if config.permissions.searchEmails {
            tools.append(Tool(
                name: "search_emails",
                description: "Search emails by sender, subject, date range, or body content",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Search query for subject or body")
                        ]),
                        "from": .object([
                            "type": .string("string"),
                            "description": .string("Filter by sender email address")
                        ]),
                        "to": .object([
                            "type": .string("string"),
                            "description": .string("Filter by recipient email address")
                        ]),
                        "mailbox": .object([
                            "type": .string("string"),
                            "description": .string("Filter by mailbox name (e.g., 'INBOX', 'Sent')")
                        ]),
                        "after": .object([
                            "type": .string("string"),
                            "description": .string("Only emails after this date (ISO 8601 format)")
                        ]),
                        "before": .object([
                            "type": .string("string"),
                            "description": .string("Only emails before this date (ISO 8601 format)")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of results (default: 20)")
                        ])
                    ]),
                    "required": .array([])
                ])
            ))
        }

        if config.permissions.listEmails {
            tools.append(Tool(
                name: "list_emails",
                description: "List emails in a specific mailbox with pagination",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "mailbox": .object([
                            "type": .string("string"),
                            "description": .string("Mailbox name (e.g., 'INBOX', 'Sent')")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of results (default: 20)")
                        ]),
                        "offset": .object([
                            "type": .string("integer"),
                            "description": .string("Number of emails to skip (for pagination)")
                        ])
                    ]),
                    "required": .array([.string("mailbox")])
                ])
            ))
        }

        if config.permissions.getEmail {
            tools.append(Tool(
                name: "get_email",
                description: "Get full email content including body text",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("Email ID (from search or list results)")
                        ])
                    ]),
                    "required": .array([.string("id")])
                ])
            ))
        }

        if config.permissions.listAttachments {
            tools.append(Tool(
                name: "list_attachments",
                description: "List attachments for an email",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "email_id": .object([
                            "type": .string("string"),
                            "description": .string("Email ID to list attachments for")
                        ])
                    ]),
                    "required": .array([.string("email_id")])
                ])
            ))
        }

        if config.permissions.getAttachment {
            tools.append(Tool(
                name: "get_attachment",
                description: "Get attachment content (text extraction for PDFs, documents, etc.)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "email_id": .object([
                            "type": .string("string"),
                            "description": .string("Email ID containing the attachment")
                        ]),
                        "filename": .object([
                            "type": .string("string"),
                            "description": .string("Attachment filename")
                        ])
                    ]),
                    "required": .array([.string("email_id"), .string("filename")])
                ])
            ))
        }

        if config.permissions.searchAttachments {
            tools.append(Tool(
                name: "search_attachments",
                description: "Search for text content within email attachments (PDFs, documents, etc.)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Text to search for within attachments")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of results (default: 20)")
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            ))
        }

        if config.permissions.getEmailLink {
            tools.append(Tool(
                name: "get_email_link",
                description: "Get a message:// URL that opens the email in Mail.app",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("Email ID to get link for")
                        ])
                    ]),
                    "required": .array([.string("id")])
                ])
            ))

            tools.append(Tool(
                name: "open_email",
                description: "Open an email directly in Mail.app. This will switch to Mail.app and display the email.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("Email ID to open in Mail.app")
                        ])
                    ]),
                    "required": .array([.string("id")])
                ])
            ))
        }

        tools.append(Tool(
            name: "get_config",
            description: "Get current MacMailClauder configuration and permissions",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ])
        ))

        return ListTools.Result(tools: tools)
    }

    private func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        log("Tool called: \(name) with arguments: \(String(describing: arguments))")

        switch name {
        case "list_mailboxes":
            return try await handleListMailboxes()

        case "search_emails":
            return try await handleSearchEmails(arguments: arguments ?? [:])

        case "list_emails":
            return try await handleListEmails(arguments: arguments ?? [:])

        case "get_email":
            return try await handleGetEmail(arguments: arguments ?? [:])

        case "list_attachments":
            return try await handleListAttachments(arguments: arguments ?? [:])

        case "get_attachment":
            return try await handleGetAttachment(arguments: arguments ?? [:])

        case "search_attachments":
            return try await handleSearchAttachments(arguments: arguments ?? [:])

        case "get_email_link":
            return try await handleGetEmailLink(arguments: arguments ?? [:])

        case "open_email":
            return try await handleOpenEmail(arguments: arguments ?? [:])

        case "get_config":
            return handleGetConfig()

        default:
            throw MCPError.methodNotFound("Unknown tool: \(name)")
        }
    }

    // MARK: - Tool Implementations

    private func handleListMailboxes() async throws -> CallTool.Result {
        guard let db = mailDatabase else {
            return CallTool.Result(content: [.text("Error: Mail database not available. Please ensure Full Disk Access is granted.")])
        }

        let config = configManager.load()

        do {
            let mailboxes = try db.listMailboxes()
            let filtered = mailboxes.filter { mailbox in
                // Check excluded mailboxes
                if config.scope.excludedMailboxes.contains(where: { mailbox.name.localizedCaseInsensitiveContains($0) }) {
                    return false
                }
                // Check allowed mailboxes if specified
                if let allowed = config.scope.allowedMailboxes {
                    return allowed.contains(where: { mailbox.name.localizedCaseInsensitiveContains($0) })
                }
                return true
            }

            // Group mailboxes by account for clearer display
            var byAccount: [String: [Mailbox]] = [:]
            for mailbox in filtered {
                let account = mailbox.accountName ?? "Local"
                byAccount[account, default: []].append(mailbox)
            }

            var lines: [String] = []
            for (account, accountMailboxes) in byAccount.sorted(by: { $0.key < $1.key }) {
                lines.append("\n[\(account)]")
                for mb in accountMailboxes.sorted(by: { $0.name < $1.name }) {
                    lines.append("  - \(mb.name) (ID: \(mb.id))")
                }
            }

            let result = "Found \(filtered.count) mailboxes:" + lines.joined(separator: "\n")
            return CallTool.Result(content: [.text(result)])
        } catch {
            return CallTool.Result(content: [.text("Error listing mailboxes: \(error.localizedDescription)")])
        }
    }

    private func handleSearchEmails(arguments: [String: Value]) async throws -> CallTool.Result {
        guard let db = mailDatabase else {
            return CallTool.Result(content: [.text("Error: Mail database not available. Please ensure Full Disk Access is granted.")])
        }

        let query = arguments["query"]?.stringValue
        let from = arguments["from"]?.stringValue
        let to = arguments["to"]?.stringValue
        let mailbox = arguments["mailbox"]?.stringValue
        let afterStr = arguments["after"]?.stringValue
        let beforeStr = arguments["before"]?.stringValue
        let limit = arguments["limit"]?.intValue ?? 20

        let config = configManager.load()
        let effectiveLimit = min(limit, config.scope.maxResults)

        var afterDate: Date?
        var beforeDate: Date?

        // Parse dates
        let formatter = ISO8601DateFormatter()
        if let afterStr = afterStr {
            afterDate = formatter.date(from: afterStr)
        }
        if let beforeStr = beforeStr {
            beforeDate = formatter.date(from: beforeStr)
        }

        // Apply scope date filter
        if let scopeStart = config.scope.dateRange == .custom ? config.scope.customStartDate : config.scope.dateRange.startDate {
            if afterDate == nil || scopeStart > afterDate! {
                afterDate = scopeStart
            }
        }

        do {
            let emails = try db.searchEmails(
                query: query,
                from: from,
                to: to,
                mailbox: mailbox,
                after: afterDate,
                before: beforeDate,
                limit: effectiveLimit
            )

            if emails.isEmpty {
                return CallTool.Result(content: [.text("No emails found matching the search criteria.")])
            }

            let lines = emails.map { email in
                let date = email.dateReceived.map { ISO8601DateFormatter().string(from: $0) } ?? "Unknown date"
                return """
                ---
                ID: \(email.id)
                Subject: \(email.subject)
                From: \(email.sender)
                Date: \(date)
                Mailbox: \(email.mailboxName ?? "Unknown")
                """
            }

            let result = "Found \(emails.count) email(s):\n" + lines.joined(separator: "\n")
            return CallTool.Result(content: [.text(result)])
        } catch {
            return CallTool.Result(content: [.text("Error searching emails: \(error.localizedDescription)")])
        }
    }

    private func handleListEmails(arguments: [String: Value]) async throws -> CallTool.Result {
        guard let db = mailDatabase else {
            return CallTool.Result(content: [.text("Error: Mail database not available. Please ensure Full Disk Access is granted.")])
        }

        guard let mailbox = arguments["mailbox"]?.stringValue else {
            throw MCPError.invalidParams("Missing required parameter: mailbox")
        }

        let limit = arguments["limit"]?.intValue ?? 20
        let offset = arguments["offset"]?.intValue ?? 0

        let config = configManager.load()
        let effectiveLimit = min(limit, config.scope.maxResults)

        do {
            let emails = try db.listEmails(mailbox: mailbox, limit: effectiveLimit, offset: offset)

            if emails.isEmpty {
                return CallTool.Result(content: [.text("No emails found in mailbox '\(mailbox)'.")])
            }

            let lines = emails.map { email in
                let date = email.dateReceived.map { ISO8601DateFormatter().string(from: $0) } ?? "Unknown date"
                return "[\(email.id)] \(date) - \(email.sender): \(email.subject)"
            }

            let result = "Emails in '\(mailbox)' (showing \(emails.count), offset \(offset)):\n" + lines.joined(separator: "\n")
            return CallTool.Result(content: [.text(result)])
        } catch {
            return CallTool.Result(content: [.text("Error listing emails: \(error.localizedDescription)")])
        }
    }

    private func handleGetEmail(arguments: [String: Value]) async throws -> CallTool.Result {
        guard let db = mailDatabase else {
            return CallTool.Result(content: [.text("Error: Mail database not available. Please ensure Full Disk Access is granted.")])
        }

        guard let idStr = arguments["id"]?.stringValue, let id = Int64(idStr) else {
            throw MCPError.invalidParams("Missing or invalid required parameter: id")
        }

        let config = configManager.load()

        do {
            guard let email = try db.getEmail(id: id) else {
                return CallTool.Result(content: [.text("Email not found with ID: \(id)")])
            }

            var result = """
            Subject: \(email.subject)
            From: \(email.sender)
            To: \(email.recipients.joined(separator: ", "))
            Date: \(email.dateReceived.map { ISO8601DateFormatter().string(from: $0) } ?? "Unknown")
            Mailbox: \(email.mailboxName ?? "Unknown")
            Message-ID: \(email.messageId ?? "Unknown")
            """

            if config.permissions.getEmailBody, let body = email.body {
                result += "\n\n--- Body ---\n\(body)"
            }

            if let attachments = email.attachments, !attachments.isEmpty {
                result += "\n\n--- Attachments ---\n"
                result += attachments.map { "- \($0.filename) (\($0.mimeType ?? "unknown type"), \($0.size) bytes)" }.joined(separator: "\n")
            }

            return CallTool.Result(content: [.text(result)])
        } catch {
            return CallTool.Result(content: [.text("Error getting email: \(error.localizedDescription)")])
        }
    }

    private func handleListAttachments(arguments: [String: Value]) async throws -> CallTool.Result {
        guard let db = mailDatabase else {
            return CallTool.Result(content: [.text("Error: Mail database not available. Please ensure Full Disk Access is granted.")])
        }

        guard let idStr = arguments["email_id"]?.stringValue, let id = Int64(idStr) else {
            throw MCPError.invalidParams("Missing or invalid required parameter: email_id")
        }

        do {
            let attachments = try db.listAttachments(emailId: id)

            if attachments.isEmpty {
                return CallTool.Result(content: [.text("No attachments found for email ID: \(id)")])
            }

            let lines = attachments.map { attachment in
                "- \(attachment.filename) (\(attachment.mimeType ?? "unknown type"), \(attachment.size) bytes)"
            }

            let result = "Attachments for email \(id):\n" + lines.joined(separator: "\n")
            return CallTool.Result(content: [.text(result)])
        } catch {
            return CallTool.Result(content: [.text("Error listing attachments: \(error.localizedDescription)")])
        }
    }

    private func handleGetAttachment(arguments: [String: Value]) async throws -> CallTool.Result {
        guard let db = mailDatabase else {
            return CallTool.Result(content: [.text("Error: Mail database not available. Please ensure Full Disk Access is granted.")])
        }

        guard let idStr = arguments["email_id"]?.stringValue, let id = Int64(idStr) else {
            throw MCPError.invalidParams("Missing or invalid required parameter: email_id")
        }

        guard let filename = arguments["filename"]?.stringValue else {
            throw MCPError.invalidParams("Missing required parameter: filename")
        }

        let config = configManager.load()

        do {
            guard let content = try db.getAttachmentContent(emailId: id, filename: filename, extractText: config.permissions.extractAttachmentContent) else {
                return CallTool.Result(content: [.text("Attachment not found: \(filename)")])
            }

            return CallTool.Result(content: [.text(content)])
        } catch {
            return CallTool.Result(content: [.text("Error getting attachment: \(error.localizedDescription)")])
        }
    }

    private func handleSearchAttachments(arguments: [String: Value]) async throws -> CallTool.Result {
        guard let db = mailDatabase else {
            return CallTool.Result(content: [.text("Error: Mail database not available. Please ensure Full Disk Access is granted.")])
        }

        guard let query = arguments["query"]?.stringValue else {
            throw MCPError.invalidParams("Missing required parameter: query")
        }

        let limit = arguments["limit"]?.intValue ?? 20
        let config = configManager.load()
        let effectiveLimit = min(limit, config.scope.maxResults)

        do {
            let results = try db.searchAttachments(query: query, limit: effectiveLimit)

            if results.isEmpty {
                return CallTool.Result(content: [.text("No attachments found containing: \(query)")])
            }

            let lines = results.map { result in
                """
                ---
                Email ID: \(result.emailId)
                Subject: \(result.emailSubject)
                Attachment: \(result.filename)
                Match: \(result.matchSnippet)
                """
            }

            let result = "Found \(results.count) attachment(s) matching '\(query)':\n" + lines.joined(separator: "\n")
            return CallTool.Result(content: [.text(result)])
        } catch {
            return CallTool.Result(content: [.text("Error searching attachments: \(error.localizedDescription)")])
        }
    }

    private func handleGetEmailLink(arguments: [String: Value]) async throws -> CallTool.Result {
        guard let db = mailDatabase else {
            return CallTool.Result(content: [.text("Error: Mail database not available. Please ensure Full Disk Access is granted.")])
        }

        guard let idStr = arguments["id"]?.stringValue, let id = Int64(idStr) else {
            throw MCPError.invalidParams("Missing or invalid required parameter: id")
        }

        do {
            guard let email = try db.getEmail(id: id) else {
                return CallTool.Result(content: [.text("Email not found with ID: \(id)")])
            }

            guard let messageId = email.messageId else {
                return CallTool.Result(content: [.text("Email does not have a Message-ID, cannot generate link")])
            }

            // Generate message:// URL
            let encodedId = messageId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? messageId
            let url = "message://\(encodedId)"

            return CallTool.Result(content: [.text("Mail.app link: \(url)\n\nClick or open this URL to view the email in Mail.app.")])
        } catch {
            return CallTool.Result(content: [.text("Error getting email link: \(error.localizedDescription)")])
        }
    }

    private func handleOpenEmail(arguments: [String: Value]) async throws -> CallTool.Result {
        guard let db = mailDatabase else {
            return CallTool.Result(content: [.text("Error: Mail database not available. Please ensure Full Disk Access is granted.")])
        }

        guard let idStr = arguments["id"]?.stringValue, let id = Int64(idStr) else {
            throw MCPError.invalidParams("Missing or invalid required parameter: id")
        }

        do {
            guard let email = try db.getEmail(id: id) else {
                return CallTool.Result(content: [.text("Email not found with ID: \(id)")])
            }

            guard let messageId = email.messageId else {
                return CallTool.Result(content: [.text("Email does not have a Message-ID, cannot open in Mail.app")])
            }

            // Generate message:// URL
            let encodedId = messageId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? messageId
            let url = "message://\(encodedId)"

            // Use /usr/bin/open to open the URL, which will launch Mail.app
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [url]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                return CallTool.Result(content: [.text("Opening email in Mail.app...\n\nSubject: \(email.subject)\nFrom: \(email.sender)")])
            } else {
                return CallTool.Result(content: [.text("Failed to open email in Mail.app (exit code: \(process.terminationStatus))")])
            }
        } catch {
            return CallTool.Result(content: [.text("Error opening email: \(error.localizedDescription)")])
        }
    }

    private func handleGetConfig() -> CallTool.Result {
        let config = configManager.load()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(config)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            return CallTool.Result(content: [.text("Current configuration:\n\(json)")])
        } catch {
            return CallTool.Result(content: [.text("Error encoding config: \(error.localizedDescription)")])
        }
    }
}
