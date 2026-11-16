import Darwin
import Foundation

extension IndexStore {
    /// Publish a confirmed removal without enumerating unrelated siblings. An existing
    /// replacement, inaccessible parent or changed volume must never imply deletion.
    @discardableResult
    public func removeMissingEntry(rootID: Int64, path: String) throws -> Bool {
        try requireWriter()
        guard !path.utf8.contains(0), path.hasPrefix("/"),
              let root = try roots().first(where: { $0.id == rootID }) else {
            throw SearchError.message("删除索引条目的路径或根目录无效。")
        }
        let target = Paths.lexical(path)
        guard target != root.path, Paths.contains(root.path, target) else {
            throw SearchError.message("只能清理索引根目录内的条目。")
        }
        let configuration = try database.prepare("SELECT volume_identifier FROM index_roots WHERE id = ?")
        try configuration.bind([.integer(rootID)])
        guard try configuration.step() else { throw SearchError.message("索引根目录已移除。") }
        let expectedVolume = configuration.optionalText(0)
        _ = try configuration.step()
        let parent = (target as NSString).deletingLastPathComponent
        let rootInfo = try FileScanner.inspect(root.path)
        let parentInfo = try FileScanner.inspect(parent)

        return try database.transaction {
            guard rootInfo.isDirectory, parentInfo.isDirectory,
                  !rootInfo.isSymbolicLink, !parentInfo.isSymbolicLink,
                  Paths.canonical(parent) == parent, parentInfo.device == rootInfo.device else {
                throw SearchError.message("上级目录或挂载点已变化，保留旧索引。")
            }
            let volume = try FileScanner.volumeIdentity(root.path)
            if let expectedVolume, expectedVolume != volume && expectedVolume != String(rootInfo.device) {
                throw SearchError.message("根目录所在卷身份不匹配，保留旧索引。")
            }
            let finalRoot = try FileScanner.inspect(root.path)
            let finalParent = try FileScanner.inspect(parent)
            guard finalRoot.device == rootInfo.device, finalRoot.inode == rootInfo.inode,
                  finalParent.device == parentInfo.device, finalParent.inode == parentInfo.inode else {
                throw SearchError.message("检查期间上级目录被替换，保留旧索引。")
            }
            var info = stat()
            if lstat(target, &info) == 0 { return false }
            guard errno == ENOENT else {
                throw SearchError.message("无法确认文件已移走，保留旧索引：\(String(cString: strerror(errno)))")
            }
            // The path index bounds preserve similarly named neighbours and FTS triggers
            // remove the matching terms in the same transaction. Checkpoints stay unchanged.
            try database.execute("DELETE FROM files WHERE root_id = ? AND path = ?",
                                 [.integer(rootID), .text(target)])
            try database.execute("""
                DELETE FROM files WHERE root_id = ? AND id IN
                    (SELECT id FROM files WHERE path >= ? AND path < ?)
                """, [.integer(rootID), .text(target + "/"), .text(target + "0")])
            return true
        }
    }
}
