import Foundation
import SwiftSoup

/// Result of parsing an .emlx file
struct ParsedEmail {
    let body: String?
    let htmlBody: String?
    let attachments: [Attachment]
    let messageId: String?
}

/// Parses .emlx files from Mail.app
class EMLXParser {

    /// Parse an .emlx or .partial.emlx file
    func parse(fileURL: URL) throws -> ParsedEmail {
        let data = try Data(contentsOf: fileURL)

        // .emlx files start with a byte count line, then the RFC822 message, then a plist
        guard let content = String(data: data, encoding: .utf8) else {
            throw ParserError.invalidEncoding
        }

        // Find the first line (byte count)
        guard let firstNewline = content.firstIndex(of: "\n") else {
            throw ParserError.invalidFormat
        }

        let byteCountStr = String(content[..<firstNewline]).trimmingCharacters(in: .whitespaces)
        guard let byteCount = Int(byteCountStr) else {
            throw ParserError.invalidFormat
        }

        // Extract the RFC822 message portion
        let messageStart = content.index(after: firstNewline)
        let messageEndOffset = min(content.utf8.count, byteCount + content.utf8.distance(from: content.startIndex, to: messageStart))

        // Convert to the message string
        let messageData = data.subdata(in: data.index(data.startIndex, offsetBy: content.utf8.distance(from: content.startIndex, to: messageStart))..<data.index(data.startIndex, offsetBy: messageEndOffset))

        guard let messageContent = String(data: messageData, encoding: .utf8) ?? String(data: messageData, encoding: .isoLatin1) else {
            throw ParserError.invalidEncoding
        }

        // Parse the MIME message
        // Note: For .partial.emlx files, attachments are stored externally and should be
        // queried from the database's attachments table via MailDatabase.listAttachments()
        return try parseMIME(content: messageContent, baseURL: fileURL)
    }

    private func parseMIME(content: String, baseURL: URL) throws -> ParsedEmail {
        // Split headers and body
        let parts = content.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 2 else {
            // Try with just \n\n
            let altParts = content.components(separatedBy: "\n\n")
            if altParts.count >= 2 {
                return try parseMIMEParts(headers: altParts[0], body: altParts.dropFirst().joined(separator: "\n\n"), baseURL: baseURL)
            }
            throw ParserError.invalidFormat
        }

        let headers = parts[0]
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")

        return try parseMIMEParts(headers: headers, body: body, baseURL: baseURL)
    }

    private func parseMIMEParts(headers: String, body: String, baseURL: URL) throws -> ParsedEmail {
        let headerDict = parseHeaders(headers)

        // Extract Message-ID from headers
        let messageId = headerDict["message-id"]

        // Check content type
        let contentType = headerDict["content-type"] ?? "text/plain"

        if contentType.contains("multipart/") {
            // Extract boundary
            if let boundary = extractBoundary(from: contentType) {
                let result = try parseMultipart(body: body, boundary: boundary, baseURL: baseURL)
                // Preserve the message-id from top-level headers
                return ParsedEmail(body: result.body, htmlBody: result.htmlBody, attachments: result.attachments, messageId: messageId)
            }
        }

        // Single part message
        let decodedBody = decodeBody(body, encoding: headerDict["content-transfer-encoding"])

        if contentType.contains("text/html") {
            let plainText = try htmlToPlainText(decodedBody)
            return ParsedEmail(body: plainText, htmlBody: decodedBody, attachments: [], messageId: messageId)
        } else {
            return ParsedEmail(body: decodedBody, htmlBody: nil, attachments: [], messageId: messageId)
        }
    }

    private func parseHeaders(_ headerString: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        var currentValue: String = ""

        for line in headerString.components(separatedBy: .newlines) {
            if line.isEmpty {
                continue
            }

            // Check if this is a continuation line (starts with whitespace)
            if line.first?.isWhitespace == true {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colonIndex = line.firstIndex(of: ":") {
                // Save previous header
                if let key = currentKey {
                    headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
                }

                // Start new header
                currentKey = String(line[..<colonIndex])
                currentValue = String(line[line.index(after: colonIndex)...])
            }
        }

        // Save last header
        if let key = currentKey {
            headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
        }

        return headers
    }

    private func extractBoundary(from contentType: String) -> String? {
        // Look for boundary="..." or boundary=...
        let pattern = #"boundary=(?:"([^"]+)"|([^\s;]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(contentType.startIndex..., in: contentType)
        guard let match = regex.firstMatch(in: contentType, range: range) else {
            return nil
        }

        // Try quoted group first, then unquoted
        if let range1 = Range(match.range(at: 1), in: contentType) {
            return String(contentType[range1])
        }
        if let range2 = Range(match.range(at: 2), in: contentType) {
            return String(contentType[range2])
        }

        return nil
    }

    private func parseMultipart(body: String, boundary: String, baseURL: URL) throws -> ParsedEmail {
        let delimiter = "--\(boundary)"
        let endDelimiter = "--\(boundary)--"

        var textBody: String?
        var htmlBody: String?
        var attachments: [Attachment] = []

        let parts = body.components(separatedBy: delimiter)

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "--" || trimmed.hasPrefix("--") {
                continue
            }

            // Remove trailing end delimiter
            let cleanPart = trimmed.replacingOccurrences(of: endDelimiter, with: "")

            // Split into headers and content
            let sections = cleanPart.components(separatedBy: "\r\n\r\n")
            guard sections.count >= 2 else {
                let altSections = cleanPart.components(separatedBy: "\n\n")
                if altSections.count >= 2 {
                    try processMultipartSection(
                        headers: altSections[0],
                        content: altSections.dropFirst().joined(separator: "\n\n"),
                        baseURL: baseURL,
                        textBody: &textBody,
                        htmlBody: &htmlBody,
                        attachments: &attachments
                    )
                }
                continue
            }

            try processMultipartSection(
                headers: sections[0],
                content: sections.dropFirst().joined(separator: "\r\n\r\n"),
                baseURL: baseURL,
                textBody: &textBody,
                htmlBody: &htmlBody,
                attachments: &attachments
            )
        }

        // Prefer HTML body converted to text, fall back to plain text
        let finalBody: String?
        if let html = htmlBody {
            finalBody = try? htmlToPlainText(html)
        } else {
            finalBody = textBody
        }

        // Note: messageId is nil here because this is called from parseMultipart
        // The caller (parseMIMEParts) will add the messageId from top-level headers
        return ParsedEmail(body: finalBody, htmlBody: htmlBody, attachments: attachments, messageId: nil)
    }

    private func processMultipartSection(
        headers: String,
        content: String,
        baseURL: URL,
        textBody: inout String?,
        htmlBody: inout String?,
        attachments: inout [Attachment]
    ) throws {
        let headerDict = parseHeaders(headers)
        let contentType = headerDict["content-type"] ?? "text/plain"
        let contentDisposition = headerDict["content-disposition"] ?? ""
        let encoding = headerDict["content-transfer-encoding"]

        let decoded = decodeBody(content, encoding: encoding)

        // Check if this is an attachment
        if contentDisposition.contains("attachment") || contentDisposition.contains("filename") {
            let filename = extractFilename(from: contentDisposition) ?? extractFilename(from: contentType) ?? "attachment"
            let mimeType = contentType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)

            // Try to find the actual attachment file
            let attachmentPath = findAttachmentPath(baseURL: baseURL, filename: filename)

            attachments.append(Attachment(
                filename: filename,
                mimeType: mimeType,
                size: Int64(decoded.utf8.count),
                path: attachmentPath
            ))
        } else if contentType.contains("text/plain") && textBody == nil {
            textBody = decoded
        } else if contentType.contains("text/html") && htmlBody == nil {
            htmlBody = decoded
        } else if contentType.contains("multipart/") {
            // Nested multipart
            if let boundary = extractBoundary(from: contentType) {
                let nested = try parseMultipart(body: decoded, boundary: boundary, baseURL: baseURL)
                if textBody == nil { textBody = nested.body }
                if htmlBody == nil { htmlBody = nested.htmlBody }
                attachments.append(contentsOf: nested.attachments)
            }
        }
    }

    private func extractFilename(from header: String) -> String? {
        // Look for filename="..." or filename=... or name="..." or name=...
        let patterns = [
            #"filename\*?=(?:"([^"]+)"|([^\s;]+))"#,
            #"name\*?=(?:"([^"]+)"|([^\s;]+))"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }

            let range = NSRange(header.startIndex..., in: header)
            guard let match = regex.firstMatch(in: header, range: range) else {
                continue
            }

            if let range1 = Range(match.range(at: 1), in: header), !header[range1].isEmpty {
                return String(header[range1])
            }
            if let range2 = Range(match.range(at: 2), in: header), !header[range2].isEmpty {
                return String(header[range2])
            }
        }

        return nil
    }

    private func findAttachmentPath(baseURL: URL, filename: String) -> String? {
        // Get the message ID from the base URL (e.g., 2721128 from 2721128.emlx)
        let messageId = baseURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ".partial", with: "")

        // For IMAP mailboxes, attachments are stored in a parallel Attachments directory:
        // Messages/2721128.emlx -> Attachments/2721128/{index}/{filename}
        let messagesDir = baseURL.deletingLastPathComponent()

        // Check if messagesDir is named "Messages" - if so, look for sibling Attachments folder
        if messagesDir.lastPathComponent == "Messages" {
            let parentDir = messagesDir.deletingLastPathComponent()
            let attachmentsDir = parentDir.appendingPathComponent("Attachments")
                .appendingPathComponent(messageId)

            // Use find to locate the file since it may be in a numbered subdirectory
            if let foundPath = findFileInDirectory(attachmentsDir.path, filename: filename) {
                return foundPath
            }
        }

        // Legacy: Check in traditional Attachments folder location
        let legacyAttachmentsDir = baseURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Attachments")
            .appendingPathComponent(messageId)

        let legacyPath = legacyAttachmentsDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: legacyPath.path) {
            return legacyPath.path
        }

        // Check for .emlxpart files in Messages directory
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: messagesDir.path) {
            for file in contents where file.hasPrefix(messageId) && file.hasSuffix(".emlxpart") {
                let partPath = messagesDir.appendingPathComponent(file)
                return partPath.path
            }
        }

        return nil
    }

    private func findFileInDirectory(_ directory: String, filename: String) -> String? {
        // Search recursively for the filename in the directory
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = [directory, "-name", filename, "-type", "f"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let paths = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                return paths.first
            }
        } catch {
            // Ignore errors
        }

        return nil
    }

    private func decodeBody(_ body: String, encoding: String?) -> String {
        guard let encoding = encoding?.lowercased() else {
            return body
        }

        switch encoding {
        case "base64":
            // Decode base64
            let cleaned = body.replacingOccurrences(of: "\r\n", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let data = Data(base64Encoded: cleaned),
               let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                return decoded
            }
            return body

        case "quoted-printable":
            return decodeQuotedPrintable(body)

        default:
            return body
        }
    }

    private func decodeQuotedPrintable(_ input: String) -> String {
        var result = ""
        var i = input.startIndex

        while i < input.endIndex {
            let char = input[i]

            if char == "=" {
                let next1 = input.index(after: i)
                if next1 < input.endIndex {
                    let nextChar = input[next1]

                    // Soft line break
                    if nextChar == "\r" || nextChar == "\n" {
                        i = next1
                        // Skip the newline
                        if i < input.endIndex && input[i] == "\r" {
                            i = input.index(after: i)
                        }
                        if i < input.endIndex && input[i] == "\n" {
                            i = input.index(after: i)
                        }
                        continue
                    }

                    // Hex encoded byte
                    let next2 = input.index(after: next1)
                    if next2 < input.endIndex {
                        let hex = String(input[next1...next2])
                        if let byte = UInt8(hex, radix: 16) {
                            result.append(Character(UnicodeScalar(byte)))
                            i = input.index(after: next2)
                            continue
                        }
                    }
                }
            }

            result.append(char)
            i = input.index(after: i)
        }

        return result
    }

    private func htmlToPlainText(_ html: String) throws -> String {
        do {
            let doc = try SwiftSoup.parse(html)

            // Remove script and style elements
            try doc.select("script, style").remove()

            // Get text content
            var text = try doc.text()

            // Clean up whitespace
            text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            return text
        } catch {
            // If parsing fails, do basic HTML stripping
            return html
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
        }
    }
}

enum ParserError: Error, LocalizedError {
    case invalidEncoding
    case invalidFormat
    case missingBoundary

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "Could not decode file content"
        case .invalidFormat:
            return "Invalid email file format"
        case .missingBoundary:
            return "Missing multipart boundary"
        }
    }
}
