import Foundation

/// Configuration for MacMailClauder permissions and scope
public struct MacMailClauderConfig: Codable {
    public var version: Int
    public var permissions: Permissions
    public var scope: Scope

    public init(
        version: Int = 1,
        permissions: Permissions = Permissions(),
        scope: Scope = Scope()
    ) {
        self.version = version
        self.permissions = permissions
        self.scope = scope
    }

    public struct Permissions: Codable {
        public var searchEmails: Bool
        public var searchAttachments: Bool
        public var getEmail: Bool
        public var getEmailBody: Bool
        public var getAttachment: Bool
        public var extractAttachmentContent: Bool
        public var listMailboxes: Bool
        public var listEmails: Bool
        public var listAttachments: Bool
        public var getEmailLink: Bool

        public init(
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

    public struct Scope: Codable {
        public var dateRange: DateRange
        public var customStartDate: Date?
        public var excludedMailboxes: [String]
        public var allowedMailboxes: [String]?
        public var maxResults: Int

        public init(
            dateRange: DateRange = .all,
            customStartDate: Date? = nil,
            excludedMailboxes: [String] = ["Trash", "Junk"],
            allowedMailboxes: [String]? = nil,
            maxResults: Int = 100
        ) {
            self.dateRange = dateRange
            self.customStartDate = customStartDate
            self.excludedMailboxes = excludedMailboxes
            self.allowedMailboxes = allowedMailboxes
            self.maxResults = maxResults
        }
    }

    public enum DateRange: String, Codable {
        case all
        case lastYear
        case lastSixMonths
        case lastMonth
        case lastWeek
        case custom

        public var startDate: Date? {
            let calendar = Calendar.current
            let now = Date()
            switch self {
            case .all:
                return nil
            case .lastYear:
                return calendar.date(byAdding: .year, value: -1, to: now)
            case .lastSixMonths:
                return calendar.date(byAdding: .month, value: -6, to: now)
            case .lastMonth:
                return calendar.date(byAdding: .month, value: -1, to: now)
            case .lastWeek:
                return calendar.date(byAdding: .weekOfYear, value: -1, to: now)
            case .custom:
                return nil // Use customStartDate
            }
        }
    }
}
