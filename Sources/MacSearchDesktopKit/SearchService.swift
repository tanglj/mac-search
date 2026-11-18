import Foundation
import MacSearchCore

public struct SearchResponse: Sendable {
    public let files: [FileRecord]
    public let milliseconds: Double
}

private struct SearchCacheKey: Hashable {
    let query: String
    let directory: String?
    let extensions: [String]
    let kind: EntryKind
    let limit: Int
    let sort: SearchSortField
    let direction: SearchSortDirection

    init(_ options: SearchOptions) {
        query = options.query
        directory = options.directory
        extensions = options.extensions
        kind = options.kind
        limit = options.limit
        sort = options.sort
        direction = options.direction
    }
}

/// Keeps the blocking SQLite work off the UI actor and respects the calling Task's cancellation.
public actor SearchService {
    private let databasePath: String
    private var reader: IndexStore?
    private var cache: [SearchCacheKey: (version: Int64, expiresAt: TimeInterval, response: SearchResponse)] = [:]
    private var cacheOrder: [SearchCacheKey] = []
    private let cacheLimit = 24

    public init(databasePath: String) { self.databasePath = databasePath }

    public func search(_ options: SearchOptions) throws -> SearchResponse {
        try Task.checkCancellation()
        if reader == nil { reader = try IndexStore(databasePath: databasePath) }
        guard let reader else { throw SearchError.message("索引尚未就绪。") }
        let key = SearchCacheKey(options)
        let version = try reader.dataVersion()
        let started = ProcessInfo.processInfo.systemUptime
        if let cached = cache[key], cached.version == version, cached.expiresAt > started {
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            return SearchResponse(files: cached.response.files, milliseconds: 0)
        }
        let files = try reader.search(options, shouldCancel: { Task.isCancelled })
        try Task.checkCancellation()
        let response = SearchResponse(files: files, milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
        // Never associate an older transaction snapshot with a newer commit.
        guard try reader.dataVersion() == version else { return response }
        cache[key] = (version: version, expiresAt: ProcessInfo.processInfo.systemUptime + 5, response: response)
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return response
    }

}
