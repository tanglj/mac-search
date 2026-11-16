import Foundation
import MacSearchCore

public struct SearchResponse: Sendable {
    public let files: [FileRecord]
    public let milliseconds: Double
}

/// Keeps the blocking SQLite work off the UI actor and respects the calling Task's cancellation.
public actor SearchService {
    private let databasePath: String
    private var reader: IndexStore?

    public init(databasePath: String) { self.databasePath = databasePath }

    public func search(_ options: SearchOptions) throws -> SearchResponse {
        try Task.checkCancellation()
        if reader == nil { reader = try IndexStore(databasePath: databasePath) }
        let started = ProcessInfo.processInfo.systemUptime
        guard let reader else { throw SearchError.message("索引尚未就绪。") }
        let files = try reader.search(options, shouldCancel: { Task.isCancelled })
        try Task.checkCancellation()
        return SearchResponse(files: files, milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }
}
