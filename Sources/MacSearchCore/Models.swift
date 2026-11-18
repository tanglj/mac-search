import Foundation

public enum SearchError: Error, LocalizedError {
    case message(String)
    case cancelled
    case searchCancelled

    public var errorDescription: String? {
        switch self {
        case .message(let message): message
        case .cancelled: "扫描已取消，保留原有索引。"
        case .searchCancelled: "搜索已取消。"
        }
    }
}

public struct IndexRoot: Codable, Sendable {
    public let id: Int64
    public let path: String
    public let status: String
    public let lastScanAt: Int64?
    public let lastError: String?
    public let entryCount: Int64
    public let lastEventID: String?
}

public struct FileRecord: Codable, Sendable {
    public let path: String
    public let name: String
    public let parentPath: String
    public let `extension`: String
    public let size: Int64?
    public let modifiedAt: Int64?
    public let isDirectory: Bool
    public let rootStatus: String
}

public enum EntryKind: String, Sendable, Hashable {
    case all, file, directory
}

public enum SearchSortField: String, Sendable, Hashable {
    case relevance, name, parentPath, modifiedAt, size
}

public enum SearchSortDirection: String, Sendable, Hashable {
    case ascending, descending
}

public struct SearchOptions: Sendable {
    public var query: String
    public var directory: String?
    public var extensions: [String]
    public var kind: EntryKind
    public var limit: Int
    public var sort: SearchSortField
    public var direction: SearchSortDirection

    public init(query: String, directory: String? = nil, extensions: [String] = [],
                kind: EntryKind = .all, limit: Int = 100,
                sort: SearchSortField = .relevance, direction: SearchSortDirection = .ascending) {
        self.query = query
        self.directory = directory
        self.extensions = extensions
        self.kind = kind
        self.limit = limit
        self.sort = sort
        self.direction = direction
    }
}

public struct IndexStatistics: Codable, Sendable {
    public let rootCount: Int64
    public let entryCount: Int64
    public let fileCount: Int64
    public let directoryCount: Int64
    public let databaseBytes: Int64
    public let sqliteVersion: String
    public let trigramEnabled: Bool
}

public struct ScanReport: Codable, Sendable {
    public let rootID: Int64
    public let path: String
    public let entryCount: Int
    public let durationSeconds: Double
}
