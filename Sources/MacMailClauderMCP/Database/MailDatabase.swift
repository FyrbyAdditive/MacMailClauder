import Foundation
import SQLite
import Shared

/// Errors that can occur when working with the mail database
enum MailDatabaseError: Error, LocalizedError {
    case databaseNotFound
    case accessDenied
    case queryFailed(String)
    case emailNotFound(Int64)
    case attachmentNotFound(String)

    var errorDescription: String? {
        switch self {
        case .databaseNotFound:
            return "Mail database not found. Make sure Mail.app has been used on this system."
        case .accessDenied:
            return "Access denied to Mail database. Please grant Full Disk Access to MacMailClauderMCP."
        case .queryFailed(let message):
            return "Database query failed: \(message)"
        case .emailNotFound(let id):
            return "Email not found with ID: \(id)"
        case .attachmentNotFound(let filename):
            return "Attachment not found: \(filename)"
        }
    }
}

/// Provides read-only access to the Mail.app SQLite database
class MailDatabase {
    private let db: Connection
    private let emlxParser: EMLXParser

    // Table definitions
    private let messages = Table("messages")
    private let subjects = Table("subjects")
    private let addresses = Table("addresses")
    private let mailboxes = Table("mailboxes")
    private let recipients = Table("recipients")

    // Column definitions - messages
    private let msgRowId = Expression<Int64>("ROWID")
    private let msgMailbox = Expression<Int64?>("mailbox")
    private let msgSubject = Expression<Int64?>("subject")
    private let msgSender = Expression<Int64?>("sender")
    private let msgDateSent = Expression<Double?>("date_sent")
    private let msgDateReceived = Expression<Double?>("date_received")
    private let msgMessageId = Expression<String?>("message_id")
    private let msgSummary = Expression<String?>("summary")

    // Column definitions - subjects
    private let subjRowId = Expression<Int64>("ROWID")
    private let subjSubject = Expression<String?>("subject")

    // Column definitions - addresses
    private let addrRowId = Expression<Int64>("ROWID")
    private let addrAddress = Expression<String?>("address")
    private let addrComment = Expression<String?>("comment")

    // Column definitions - mailboxes
    private let mbRowId = Expression<Int64>("ROWID")
    private let mbUrl = Expression<String?>("url")

    // Column definitions - recipients
    private let recpMessage = Expression<Int64>("message")
    private let recpAddress = Expression<Int64>("address")
    private let recpType = Expression<Int64?>("type")

    private let mailDataURL: URL
    private var accountInfoCache: [String: AccountInfo] = [:]

    struct AccountInfo {
        let description: String?
        let username: String?
        let parentAccountPK: Int64?
    }

    init() throws {
        // Find the mail database
        guard let envelopeURL = Constants.envelopeIndexURL() else {
            throw MailDatabaseError.databaseNotFound
        }

        guard let mailData = Constants.findMailDataURL() else {
            throw MailDatabaseError.databaseNotFound
        }

        self.mailDataURL = mailData

        // Check if we can access it
        guard FileManager.default.isReadableFile(atPath: envelopeURL.path) else {
            throw MailDatabaseError.accessDenied
        }

        log("Opening mail database at: \(envelopeURL.path)")

        // Open database in read-only mode
        do {
            db = try Connection(envelopeURL.path, readonly: true)
        } catch {
            log("Failed to open database: \(error)")
            throw MailDatabaseError.accessDenied
        }

        emlxParser = EMLXParser()

        // Load account info from system Accounts database
        loadAccountInfo()

        // Log available tables for debugging
        logAvailableTables()

        log("Mail database opened successfully")
    }

    private func loadAccountInfo() {
        // Load account info from ~/Library/Accounts/Accounts4.sqlite
        // This maps account UUIDs to email addresses and descriptions
        let accountsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Accounts/Accounts4.sqlite").path

        guard FileManager.default.isReadableFile(atPath: accountsPath) else {
            log("Cannot read Accounts database at \(accountsPath)")
            return
        }

        do {
            let accountsDb = try Connection(accountsPath, readonly: true)

            // First pass: load all accounts with their parent PKs
            var pkToIdentifier: [Int64: String] = [:]
            let sql = "SELECT Z_PK, ZIDENTIFIER, ZACCOUNTDESCRIPTION, ZUSERNAME, ZPARENTACCOUNT FROM ZACCOUNT"

            for row in try accountsDb.prepare(sql) {
                guard let pk = row[0] as? Int64,
                      let identifier = row[1] as? String else { continue }
                let description = row[2] as? String
                let username = row[3] as? String
                let parentPK = row[4] as? Int64

                pkToIdentifier[pk] = identifier
                accountInfoCache[identifier] = AccountInfo(
                    description: description,
                    username: username,
                    parentAccountPK: parentPK
                )
            }

            // Second pass: resolve parent accounts for entries with no username/description
            for (identifier, info) in accountInfoCache {
                if (info.username == nil || info.username?.isEmpty == true) &&
                   (info.description == nil || info.description?.isEmpty == true),
                   let parentPK = info.parentAccountPK,
                   let parentIdentifier = pkToIdentifier[parentPK],
                   let parentInfo = accountInfoCache[parentIdentifier] {
                    // Copy parent's info to child
                    accountInfoCache[identifier] = AccountInfo(
                        description: parentInfo.description,
                        username: parentInfo.username,
                        parentAccountPK: info.parentAccountPK
                    )
                    log("Resolved account \(identifier) via parent: \(parentInfo.username ?? parentInfo.description ?? "unknown")")
                }
            }

            log("Loaded \(accountInfoCache.count) accounts from Accounts database")
        } catch {
            log("Error reading Accounts database: \(error)")
        }
    }

    private func logAvailableTables() {
        do {
            let tables = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            var tableNames: [String] = []
            for row in tables {
                if let name = row[0] as? String {
                    tableNames.append(name)
                }
            }
            log("Available tables: \(tableNames.joined(separator: ", "))")

            // Log schema for key tables - including messages to see all columns
            for tableName in ["messages", "subjects", "addresses", "mailboxes", "recipients"] {
                if tableNames.contains(tableName) {
                    let schema = try db.prepare("PRAGMA table_info(\(tableName))")
                    var columns: [String] = []
                    for col in schema {
                        if let name = col[1] as? String {
                            columns.append(name)
                        }
                    }
                    log("Table '\(tableName)' columns: \(columns.joined(separator: ", "))")
                }
            }

            // Sample a message to see what data looks like
            let sample = try db.prepare("SELECT ROWID, * FROM messages LIMIT 1")
            for row in sample {
                log("Sample message row: \(row)")
            }
        } catch {
            log("Error inspecting database schema: \(error)")
        }
    }

    // MARK: - Mailbox Operations

    func listMailboxes() throws -> [Mailbox] {
        var result: [Mailbox] = []

        // Try raw SQL first to see if schema is different
        do {
            log("Attempting to list mailboxes...")
            for row in try db.prepare(mailboxes) {
                let id = row[mbRowId]
                let urlStr = row[mbUrl]

                let (name, accountName) = parseMailboxUrl(urlStr)
                result.append(Mailbox(id: id, name: name, url: urlStr, accountName: accountName))
            }
            log("Found \(result.count) mailboxes")
        } catch {
            log("Error listing mailboxes with typed query: \(error)")
            // Try raw SQL as fallback
            log("Trying raw SQL fallback...")
            let rawRows = try db.prepare("SELECT ROWID, url FROM mailboxes")
            for row in rawRows {
                if let id = row[0] as? Int64 {
                    let urlStr = row[1] as? String
                    let (name, accountName) = parseMailboxUrl(urlStr)
                    result.append(Mailbox(id: id, name: name, url: urlStr, accountName: accountName))
                }
            }
            log("Raw SQL found \(result.count) mailboxes")
        }

        return result
    }

    private func parseMailboxUrl(_ urlStr: String?) -> (name: String, accountName: String?) {
        guard let urlStr = urlStr, let url = URL(string: urlStr) else {
            return ("Unknown", nil)
        }

        var name = "Unknown"
        var accountName: String?

        if url.scheme == "imap" || url.scheme == "local" {
            // IMAP URL: imap://AccountUUID/MailboxPath
            // e.g., imap://D34D0622-B00F-4C90-B2B4-34BCDE6BE4D5/INBOX
            // or imap://14E62692-215E-438C-9BD2-16048392B260/%5BGmail%5D/All%20Mail
            // Local URL: local://B1FE72F2-6AB9-42D2-9601-C136C6D4EA21/
            let path = url.path.removingPercentEncoding ?? url.path
            let pathComponents = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/")

            // The mailbox name is the last component (or nested like [Gmail]/All Mail)
            name = pathComponents.last ?? "Unknown"
            if name.isEmpty {
                name = "Inbox"  // Local mailboxes may not have a path
            }

            // Look up account info from the Accounts database cache
            if let accountUUID = url.host, !accountUUID.isEmpty {
                if let info = accountInfoCache[accountUUID] {
                    // Prefer: username (email) > description > UUID prefix
                    if let username = info.username, !username.isEmpty {
                        accountName = username
                    } else if let desc = info.description, !desc.isEmpty {
                        accountName = desc
                    } else {
                        accountName = String(accountUUID.prefix(8))
                    }
                } else {
                    // UUID not found in cache - use prefix as fallback
                    accountName = String(accountUUID.prefix(8))
                }
            }
        } else if url.scheme == "file" {
            // File URL: file:///Users/.../Library/Mail/V10/AccountName/Mailbox.mbox
            let pathComponents = url.pathComponents

            // Find V10 or similar version directory
            if let versionIndex = pathComponents.firstIndex(where: { $0.hasPrefix("V") && $0.dropFirst().allSatisfy({ $0.isNumber }) }) {
                let afterVersion = pathComponents.suffix(from: pathComponents.index(after: versionIndex))

                // First component after V10 is account name
                if afterVersion.count >= 1 {
                    accountName = String(afterVersion.first!)
                }

                // Last component is mailbox name
                if let last = afterVersion.last {
                    name = last.replacingOccurrences(of: ".mbox", with: "")
                }
            } else {
                name = url.lastPathComponent.replacingOccurrences(of: ".mbox", with: "")
            }
        } else {
            name = url.lastPathComponent.replacingOccurrences(of: ".mbox", with: "")
        }

        return (name, accountName)
    }

    // MARK: - Email Operations

    func searchEmails(
        query: String?,
        from: String?,
        to: String?,
        mailbox: String?,
        after: Date?,
        before: Date?,
        limit: Int
    ) throws -> [Email] {
        log("searchEmails called with query=\(query ?? "nil"), from=\(from ?? "nil"), mailbox=\(mailbox ?? "nil"), limit=\(limit)")

        // Build raw SQL query for better compatibility
        // Note: document_id is the .emlx filename, message_id is internal
        var sql = """
            SELECT m.ROWID, s.subject, a.address, a.comment, m.date_sent, m.date_received,
                   m.document_id, m.mailbox, mb.url
            FROM messages m
            LEFT JOIN subjects s ON m.subject = s.ROWID
            LEFT JOIN addresses a ON m.sender = a.ROWID
            LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
            WHERE 1=1
            """
        var bindings: [Binding?] = []

        if let query = query, !query.isEmpty {
            sql += " AND s.subject LIKE ?"
            bindings.append("%\(query)%")
        }

        if let from = from, !from.isEmpty {
            sql += " AND a.address LIKE ?"
            bindings.append("%\(from)%")
        }

        if let mailbox = mailbox, !mailbox.isEmpty {
            sql += " AND mb.url LIKE ?"
            bindings.append("%\(mailbox)%")
        }

        if let after = after {
            let timestamp = after.timeIntervalSinceReferenceDate
            sql += " AND m.date_received >= ?"
            bindings.append(timestamp)
        }

        if let before = before {
            let timestamp = before.timeIntervalSinceReferenceDate
            sql += " AND m.date_received <= ?"
            bindings.append(timestamp)
        }

        sql += " ORDER BY m.date_received DESC LIMIT ?"
        bindings.append(limit)

        log("Executing SQL: \(sql)")

        var result: [Email] = []

        do {
            let statement = try db.prepare(sql, bindings)
            for row in statement {
                let email = rowToEmailFromRaw(row: row)
                result.append(email)
            }
            log("Search returned \(result.count) emails")
        } catch {
            log("Search error: \(error)")
            throw MailDatabaseError.queryFailed(error.localizedDescription)
        }

        return result
    }

    private func rowToEmailFromRaw(row: Statement.Element) -> Email {
        let id = row[0] as? Int64 ?? 0
        let subject = row[1] as? String ?? "(No Subject)"
        let senderAddr = row[2] as? String ?? "Unknown"
        let senderName = row[3] as? String
        let sender = senderName != nil ? "\(senderName!) <\(senderAddr)>" : senderAddr

        // Try multiple type conversions for timestamps (could be Double or Int64)
        let dateSent = parseTimestamp(row[4])
        let dateReceived = parseTimestamp(row[5])

        // The ROWID is the .emlx filename (e.g., 2721815.emlx)
        // The document_id column is often empty, so we use ROWID instead
        let documentId = String(id)
        let mailboxId = row[7] as? Int64
        let mailboxUrl = row[8] as? String

        // Log the raw values for debugging
        log("rowToEmailFromRaw: id=\(id), dateSent raw=\(String(describing: row[4])), dateReceived raw=\(String(describing: row[5])), documentId=\(documentId), mailboxUrl=\(String(describing: mailboxUrl))")

        var mailboxName: String?
        if let urlStr = mailboxUrl, let url = URL(string: urlStr) {
            mailboxName = url.lastPathComponent.replacingOccurrences(of: ".mbox", with: "")
        }

        return Email(
            id: id,
            subject: subject,
            sender: sender,
            recipients: [],
            dateReceived: dateReceived,
            dateSent: dateSent,
            mailboxId: mailboxId,
            mailboxName: mailboxName,
            messageId: documentId, // Use documentId as messageId for now
            body: nil,
            attachments: nil
        )
    }

    private func parseTimestamp(_ value: Any?) -> Date? {
        guard let value = value else { return nil }

        var timestamp: Double?

        // Try Double first
        if let d = value as? Double {
            timestamp = d
        }
        // Try Int64 (common in SQLite)
        else if let i = value as? Int64 {
            timestamp = Double(i)
        }
        // Try Int
        else if let i = value as? Int {
            timestamp = Double(i)
        }

        guard let ts = timestamp else { return nil }

        // Apple's Core Data uses reference date (2001-01-01)
        // But some timestamps might be Unix timestamps (1970-01-01)
        // If timestamp is > 1 billion, it's likely Unix time
        if ts > 1_000_000_000 {
            // Unix timestamp
            return Date(timeIntervalSince1970: ts)
        } else {
            // Core Data timestamp (seconds since 2001-01-01)
            return Date(timeIntervalSinceReferenceDate: ts)
        }
    }

    func listEmails(mailbox: String, limit: Int, offset: Int) throws -> [Email] {
        log("listEmails called for mailbox=\(mailbox), limit=\(limit), offset=\(offset)")

        var sql: String
        var bindings: [Binding?]

        // Check if mailbox is a numeric ID
        if let mailboxId = Int64(mailbox) {
            // Query by mailbox ID directly
            sql = """
                SELECT m.ROWID, s.subject, a.address, a.comment, m.date_sent, m.date_received,
                       m.document_id, m.mailbox, mb.url
                FROM messages m
                LEFT JOIN subjects s ON m.subject = s.ROWID
                LEFT JOIN addresses a ON m.sender = a.ROWID
                LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
                WHERE m.mailbox = ?
                ORDER BY m.date_received DESC
                LIMIT ? OFFSET ?
                """
            bindings = [mailboxId, limit, offset]
        } else {
            // Query by mailbox name in URL
            sql = """
                SELECT m.ROWID, s.subject, a.address, a.comment, m.date_sent, m.date_received,
                       m.document_id, m.mailbox, mb.url
                FROM messages m
                LEFT JOIN subjects s ON m.subject = s.ROWID
                LEFT JOIN addresses a ON m.sender = a.ROWID
                LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
                WHERE mb.url LIKE ?
                ORDER BY m.date_received DESC
                LIMIT ? OFFSET ?
                """
            bindings = ["%\(mailbox)%", limit, offset]
        }

        var result: [Email] = []

        do {
            let statement = try db.prepare(sql, bindings)
            for row in statement {
                let email = rowToEmailFromRaw(row: row)
                result.append(email)
            }
            log("listEmails returned \(result.count) emails")
        } catch {
            log("listEmails error: \(error)")
            throw MailDatabaseError.queryFailed(error.localizedDescription)
        }

        return result
    }

    func getEmail(id: Int64) throws -> Email? {
        log("getEmail called for id=\(id)")

        // document_id is the .emlx filename (TEXT), message_id is internal INTEGER
        let sql = """
            SELECT m.ROWID, s.subject, a.address, a.comment, m.date_sent, m.date_received,
                   m.document_id, m.mailbox, mb.url
            FROM messages m
            LEFT JOIN subjects s ON m.subject = s.ROWID
            LEFT JOIN addresses a ON m.sender = a.ROWID
            LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
            WHERE m.ROWID = ?
            """

        do {
            let statement = try db.prepare(sql, [id])
            for row in statement {
                var email = rowToEmailFromRaw(row: row)

                // Get recipients
                let recipientList = try getRecipients(messageId: id)
                email = Email(
                    id: email.id,
                    subject: email.subject,
                    sender: email.sender,
                    recipients: recipientList,
                    dateReceived: email.dateReceived,
                    dateSent: email.dateSent,
                    mailboxId: email.mailboxId,
                    mailboxName: email.mailboxName,
                    messageId: email.messageId,
                    body: nil,
                    attachments: nil
                )

                // Get body and attachments using ROWID as the .emlx filename
                // The ROWID is the .emlx filename (e.g., 2721815.emlx)
                let documentId = String(id)
                let mailboxUrl = row[8] as? String

                log("getEmail: documentId=\(documentId), mailboxUrl=\(mailboxUrl ?? "nil")")

                if let mailboxUrl = mailboxUrl {
                    let emlxPath = findEMLXPath(mailboxUrl: mailboxUrl, documentId: documentId)
                    if let emlxPath = emlxPath {
                        log("getEmail: Parsing emlx at \(emlxPath)")
                        do {
                            let parsed = try emlxParser.parse(fileURL: URL(fileURLWithPath: emlxPath))
                            log("getEmail: Parsed body length=\(parsed.body?.count ?? 0), attachments=\(parsed.attachments.count), messageId=\(parsed.messageId ?? "nil")")
                            email = Email(
                                id: email.id,
                                subject: email.subject,
                                sender: email.sender,
                                recipients: email.recipients,
                                dateReceived: email.dateReceived,
                                dateSent: email.dateSent,
                                mailboxId: email.mailboxId,
                                mailboxName: email.mailboxName,
                                messageId: parsed.messageId ?? email.messageId,
                                body: parsed.body,
                                attachments: parsed.attachments
                            )
                        } catch {
                            log("getEmail: Error parsing emlx: \(error)")
                        }
                    } else {
                        log("getEmail: No emlx path found")
                    }
                } else {
                    log("getEmail: Missing documentId or mailboxUrl")
                }

                return email
            }
        } catch {
            log("getEmail error: \(error)")
            throw MailDatabaseError.queryFailed(error.localizedDescription)
        }

        return nil
    }

    private func getRecipients(messageId: Int64) throws -> [String] {
        let sql = """
            SELECT a.address
            FROM recipients r
            LEFT JOIN addresses a ON r.address = a.ROWID
            WHERE r.message = ?
            """

        var result: [String] = []

        do {
            let statement = try db.prepare(sql, [messageId])
            for row in statement {
                if let addr = row[0] as? String {
                    result.append(addr)
                }
            }
        } catch {
            log("getRecipients error: \(error)")
        }

        return result
    }

    private func findEMLXPath(mailboxUrl: String, documentId: String) -> String? {
        // mailboxUrl can be:
        // - file:///path/to/INBOX.mbox/ (local mailbox)
        // - imap://UUID/INBOX (IMAP mailbox)
        // documentId is the ROWID which matches the .emlx filename (e.g., "2721815" for 2721815.emlx)

        log("findEMLXPath: mailboxUrl=\(mailboxUrl), documentId=\(documentId)")

        guard let url = URL(string: mailboxUrl) else {
            log("findEMLXPath: Failed to parse mailboxUrl as URL")
            return nil
        }

        // Handle IMAP URLs by scanning the Mail folder
        if url.scheme == "imap" {
            return findEMLXPathForIMAP(url: url, documentId: documentId)
        }

        // Handle file:// URLs (traditional approach)
        let messagesDir = url.appendingPathComponent("Messages")
        log("findEMLXPath: messagesDir=\(messagesDir.path)")

        // Try standard .emlx file
        let emlxPath = messagesDir.appendingPathComponent("\(documentId).emlx")
        if FileManager.default.fileExists(atPath: emlxPath.path) {
            log("findEMLXPath: Found \(emlxPath.path)")
            return emlxPath.path
        }

        // Try partial.emlx for messages with attachments
        let partialPath = messagesDir.appendingPathComponent("\(documentId).partial.emlx")
        if FileManager.default.fileExists(atPath: partialPath.path) {
            log("findEMLXPath: Found partial \(partialPath.path)")
            return partialPath.path
        }

        log("findEMLXPath: No .emlx file found for documentId '\(documentId)'")
        return nil
    }

    private func findEMLXPathForIMAP(url: URL, documentId: String) -> String? {
        // IMAP URL format: imap://AccountUUID/MailboxName
        // Files are stored at: ~/Library/Mail/V10/AccountUUID/MailboxName.mbox/.../Messages/documentId.emlx

        let accountUUID = url.host ?? ""
        let mailboxPath = url.path.removingPercentEncoding ?? url.path

        log("findEMLXPathForIMAP: accountUUID=\(accountUUID), mailboxPath=\(mailboxPath)")

        // Build the account directory path
        let accountDir = mailDataURL.appendingPathComponent(accountUUID)

        // The mailbox path from IMAP URL is like /INBOX or /[Gmail]/Sent Mail
        // We need to convert to filesystem path: INBOX.mbox or [Gmail].mbox/Sent Mail.mbox
        let mailboxName = mailboxPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Try to find the .mbox directory
        var mboxPath: URL?

        // Handle nested mailboxes like [Gmail]/Sent Mail
        let pathComponents = mailboxName.components(separatedBy: "/")
        if pathComponents.count == 1 {
            mboxPath = accountDir.appendingPathComponent("\(mailboxName).mbox")
        } else {
            // Nested mailbox: [Gmail]/Sent Mail -> [Gmail].mbox/Sent Mail.mbox
            var currentPath = accountDir
            for (index, component) in pathComponents.enumerated() {
                if index < pathComponents.count - 1 {
                    currentPath = currentPath.appendingPathComponent("\(component).mbox")
                } else {
                    currentPath = currentPath.appendingPathComponent("\(component).mbox")
                }
            }
            mboxPath = currentPath
        }

        guard let mboxDir = mboxPath else {
            log("findEMLXPathForIMAP: Could not determine mbox path")
            return nil
        }

        log("findEMLXPathForIMAP: Looking in mbox directory: \(mboxDir.path)")

        // The .emlx files are in a nested structure like:
        // INBOX.mbox/UUID/Data/X/Y/Z/W/Messages/documentId.emlx
        // where X/Y/Z/W are derived from the documentId
        // Use find to locate the file

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = [mboxDir.path, "-name", "\(documentId).emlx", "-o", "-name", "\(documentId).partial.emlx"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let paths = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                if let firstPath = paths.first {
                    log("findEMLXPathForIMAP: Found \(firstPath)")
                    return firstPath
                }
            }
        } catch {
            log("findEMLXPathForIMAP: find command failed: \(error)")
        }

        log("findEMLXPathForIMAP: No .emlx file found for documentId '\(documentId)'")
        return nil
    }

    // MARK: - Attachment Operations

    func listAttachments(emailId: Int64) throws -> [Attachment] {
        // Query the attachments table directly - this is more reliable than parsing MIME
        let sql = """
            SELECT a.ROWID, a.attachment_id, a.name, m.mailbox, mb.url
            FROM attachments a
            JOIN messages m ON a.message = m.ROWID
            LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
            WHERE a.message = ?
        """

        log("listAttachments: querying database for emailId=\(emailId)")

        var attachments: [Attachment] = []

        do {
            let statement = try db.prepare(sql, [emailId])
            for row in statement {
                guard let attachmentId = row[1] as? String,
                      let name = row[2] as? String else {
                    continue
                }

                let mailboxUrl = row[4] as? String

                // Find the actual file path
                let path = findAttachmentFilePath(
                    emailId: emailId,
                    attachmentId: attachmentId,
                    filename: name,
                    mailboxUrl: mailboxUrl
                )

                let mimeType = guessMimeType(for: name)
                var size: Int64 = 0
                if let path = path {
                    size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
                }

                log("listAttachments: found attachment name=\(name), attachmentId=\(attachmentId), path=\(path ?? "nil")")

                attachments.append(Attachment(
                    filename: name,
                    mimeType: mimeType,
                    size: size,
                    path: path
                ))
            }
        } catch {
            log("listAttachments: query error: \(error)")
            throw MailDatabaseError.queryFailed(error.localizedDescription)
        }

        log("listAttachments: found \(attachments.count) attachments from database")
        return attachments
    }

    private func findAttachmentFilePath(emailId: Int64, attachmentId: String, filename: String, mailboxUrl: String?) -> String? {
        // For IMAP mailboxes, attachments are at:
        // .../AccountUUID/Mailbox.mbox/.../Data/X/Y/Z/W/Attachments/<emailId>/<attachmentId>/<filename>

        guard let mailboxUrl = mailboxUrl, let url = URL(string: mailboxUrl) else {
            return nil
        }

        if url.scheme == "imap" {
            return findIMAPAttachmentPath(emailId: emailId, attachmentId: attachmentId, filename: filename, url: url)
        }

        // For file:// URLs (local mailboxes)
        let attachmentsDir = url.appendingPathComponent("Attachments")
            .appendingPathComponent(String(emailId))
            .appendingPathComponent(attachmentId)
            .appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: attachmentsDir.path) {
            return attachmentsDir.path
        }

        return nil
    }

    private func findIMAPAttachmentPath(emailId: Int64, attachmentId: String, filename: String, url: URL) -> String? {
        let accountUUID = url.host ?? ""
        let mailboxPath = url.path.removingPercentEncoding ?? url.path
        let mailboxName = mailboxPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let accountDir = mailDataURL.appendingPathComponent(accountUUID)

        // Build mbox path
        let pathComponents = mailboxName.components(separatedBy: "/")
        var mboxPath = accountDir
        for component in pathComponents {
            mboxPath = mboxPath.appendingPathComponent("\(component).mbox")
        }

        // Use find to locate the attachment
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = [
            mboxPath.path,
            "-path", "*/Attachments/\(emailId)/\(attachmentId)/\(filename)",
            "-type", "f"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let paths = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                if let firstPath = paths.first {
                    return firstPath
                }
            }
        } catch {
            log("findIMAPAttachmentPath: find command failed: \(error)")
        }

        return nil
    }

    private func guessMimeType(for filename: String) -> String? {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "application/pdf"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "zip": return "application/zip"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        case "csv": return "text/csv"
        default: return "application/octet-stream"
        }
    }

    func getAttachmentContent(emailId: Int64, filename: String, extractText: Bool) throws -> String? {
        // Use the database-based attachment lookup
        let attachments = try listAttachments(emailId: emailId)

        guard let attachment = attachments.first(where: { $0.filename == filename }) else {
            throw MailDatabaseError.attachmentNotFound(filename)
        }

        guard let path = attachment.path else {
            return "Attachment path not available"
        }

        if extractText {
            return try AttachmentExtractor.extractText(from: URL(fileURLWithPath: path), mimeType: attachment.mimeType)
        } else {
            return "Attachment: \(filename) (\(attachment.mimeType ?? "unknown type"), \(attachment.size) bytes)\nPath: \(path)"
        }
    }

    func searchAttachments(query: String, limit: Int) throws -> [AttachmentSearchResult] {
        // First try Spotlight search
        var results = try searchAttachmentsViaSpotlight(query: query, limit: limit)

        // If we didn't get enough results, fall back to direct file search
        if results.count < limit {
            let directResults = try searchAttachmentsDirectly(query: query, limit: limit - results.count)
            results.append(contentsOf: directResults)
        }

        return results
    }

    private func searchAttachmentsViaSpotlight(query: String, limit: Int) throws -> [AttachmentSearchResult] {
        // Use mdfind to search via Spotlight
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [
            "-onlyin", mailDataURL.path,
            "kMDItemTextContent == '*\(query)*'cd"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        let paths = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var results: [AttachmentSearchResult] = []

        for path in paths.prefix(limit) {
            // Try to find the associated email
            if let result = try attachmentResultFromPath(path, query: query) {
                results.append(result)
            }
        }

        return results
    }

    private func attachmentResultFromPath(_ path: String, query: String) throws -> AttachmentSearchResult? {
        let url = URL(fileURLWithPath: path)
        let filename = url.lastPathComponent

        // Try to extract email ID from path
        // Path might be like: .../Messages/12345.2.emlxpart or .../Attachments/12345/file.pdf
        let pathComponents = url.pathComponents

        var emailId: Int64?
        for component in pathComponents {
            // Look for numeric component that could be email ID
            if let id = Int64(component.components(separatedBy: ".").first ?? "") {
                emailId = id
                break
            }
        }

        guard let id = emailId else {
            return nil
        }

        // Get email subject
        let email = try? getEmail(id: id)
        let subject = email?.subject ?? "Unknown"

        // Try to extract a snippet around the match
        var snippet = ""
        if let content = try? AttachmentExtractor.extractText(from: url, mimeType: nil) {
            if let range = content.range(of: query, options: .caseInsensitive) {
                let start = content.index(range.lowerBound, offsetBy: -50, limitedBy: content.startIndex) ?? content.startIndex
                let end = content.index(range.upperBound, offsetBy: 50, limitedBy: content.endIndex) ?? content.endIndex
                snippet = "..." + String(content[start..<end]) + "..."
            }
        }

        return AttachmentSearchResult(
            emailId: id,
            emailSubject: subject,
            filename: filename,
            matchSnippet: snippet
        )
    }

    private func searchAttachmentsDirectly(query: String, limit: Int) throws -> [AttachmentSearchResult] {
        // This is a fallback for when Spotlight doesn't have the content indexed
        // We'd need to scan .emlxpart files and Attachments directories
        // This is slower but guaranteed to work
        // For now, return empty - Spotlight should handle most cases
        return []
    }
}
