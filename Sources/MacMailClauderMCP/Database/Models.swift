import Foundation

/// Represents a mailbox/folder in Mail.app
struct Mailbox {
    let id: Int64
    let name: String
    let url: String?
    let accountName: String?
}

/// Represents an email message
struct Email {
    let id: Int64
    let subject: String
    let sender: String
    let recipients: [String]
    let dateReceived: Date?
    let dateSent: Date?
    let mailboxId: Int64?
    let mailboxName: String?
    let messageId: String?
    let body: String?
    let attachments: [Attachment]?
}

/// Represents an email attachment
struct Attachment {
    let filename: String
    let mimeType: String?
    let size: Int64
    let path: String?
}

/// Represents a search result for attachment content
struct AttachmentSearchResult {
    let emailId: Int64
    let emailSubject: String
    let filename: String
    let matchSnippet: String
}
