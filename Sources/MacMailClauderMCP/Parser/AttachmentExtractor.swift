import Foundation
import PDFKit

/// Extracts text content from various attachment file types
enum AttachmentExtractor {

    /// Extract text from an attachment file
    static func extractText(from url: URL, mimeType: String?) throws -> String {
        let fileExtension = url.pathExtension.lowercased()
        let effectiveMimeType = mimeType?.lowercased() ?? mimeTypeForExtension(fileExtension)

        // Handle based on file type
        switch effectiveMimeType {
        case let type where type.contains("pdf"):
            return try extractPDFText(from: url)

        case let type where type.contains("text/plain"):
            return try String(contentsOf: url, encoding: .utf8)

        case let type where type.contains("text/html"):
            let html = try String(contentsOf: url, encoding: .utf8)
            return stripHTML(html)

        case let type where type.contains("text/rtf"), let type where type.contains("rtf"):
            return try extractRTFText(from: url)

        case let type where type.contains("csv"):
            return try String(contentsOf: url, encoding: .utf8)

        case let type where type.contains("json"):
            return try String(contentsOf: url, encoding: .utf8)

        case let type where type.contains("xml"):
            return try extractXMLText(from: url)

        case let type where type.contains("word") || type.contains("docx"):
            return try extractDocxText(from: url)

        default:
            // Try to read as plain text
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
            return "Cannot extract text from this file type (\(effectiveMimeType))"
        }
    }

    // MARK: - PDF Extraction

    private static func extractPDFText(from url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.cannotOpenFile
        }

        var text = ""
        for pageIndex in 0..<document.pageCount {
            if let page = document.page(at: pageIndex),
               let pageText = page.string {
                text += pageText
                text += "\n\n"
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - RTF Extraction

    private static func extractRTFText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)

        // Use NSAttributedString to parse RTF
        guard let attributedString = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else {
            // Try RTFD
            if let rtfdString = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtfd],
                documentAttributes: nil
            ) {
                return rtfdString.string
            }
            throw ExtractionError.cannotParseFile
        }

        return attributedString.string
    }

    // MARK: - XML Extraction

    private static func extractXMLText(from url: URL) throws -> String {
        let content = try String(contentsOf: url, encoding: .utf8)
        return stripXML(content)
    }

    // MARK: - DOCX Extraction

    private static func extractDocxText(from url: URL) throws -> String {
        // DOCX files are ZIP archives containing XML
        // The main content is in word/document.xml

        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        // Unzip the file
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", url.path, "-d", tempDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ExtractionError.cannotOpenFile
        }

        // Read the document.xml file
        let documentPath = tempDir.appendingPathComponent("word/document.xml")
        guard fileManager.fileExists(atPath: documentPath.path) else {
            throw ExtractionError.cannotParseFile
        }

        let xmlContent = try String(contentsOf: documentPath, encoding: .utf8)
        return extractTextFromWordXML(xmlContent)
    }

    private static func extractTextFromWordXML(_ xml: String) -> String {
        // Extract text from <w:t> tags
        var result = ""
        var inTextTag = false
        var currentText = ""

        let scanner = Scanner(string: xml)
        scanner.charactersToBeSkipped = nil

        while !scanner.isAtEnd {
            if scanner.scanString("<w:t") != nil {
                // Skip attributes until >
                _ = scanner.scanUpToString(">")
                _ = scanner.scanString(">")
                inTextTag = true
                currentText = ""
            } else if scanner.scanString("</w:t>") != nil {
                if inTextTag {
                    result += currentText
                }
                inTextTag = false
            } else if scanner.scanString("<w:p") != nil || scanner.scanString("<w:br") != nil {
                // Paragraph or line break
                if !result.isEmpty && !result.hasSuffix("\n") {
                    result += "\n"
                }
                _ = scanner.scanUpToString(">")
                _ = scanner.scanString(">")
            } else if scanner.scanString("<") != nil {
                // Skip other tags
                _ = scanner.scanUpToString(">")
                _ = scanner.scanString(">")
            } else {
                // Regular character
                if let chars = scanner.scanCharacters(from: CharacterSet(charactersIn: "<").inverted) {
                    if inTextTag {
                        currentText += chars
                    }
                }
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func stripHTML(_ html: String) -> String {
        return html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripXML(_ xml: String) -> String {
        return xml
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mimeTypeForExtension(_ ext: String) -> String {
        switch ext {
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        case "rtf": return "text/rtf"
        case "rtfd": return "text/rtfd"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "doc": return "application/msword"
        default: return "application/octet-stream"
        }
    }
}

enum ExtractionError: Error, LocalizedError {
    case cannotOpenFile
    case cannotParseFile
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .cannotOpenFile:
            return "Cannot open file"
        case .cannotParseFile:
            return "Cannot parse file content"
        case .unsupportedFormat:
            return "Unsupported file format"
        }
    }
}
