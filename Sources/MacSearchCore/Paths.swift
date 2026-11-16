import Foundation
import Darwin

enum Paths {
    private static let systemAliases = ["/var", "/tmp", "/etc"].map { ($0, canonical($0)) }

    /// Normalize spelling without following user-controlled symlinks or requiring the path to exist.
    static func lexical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        var parts: [Substring] = []
        for part in absolute.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        var result = "/" + parts.joined(separator: "/")
        for (alias, target) in systemAliases where alias != target && contains(alias, result) {
            result = target + result.dropFirst(alias.count)
            break
        }
        return result
    }

    static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(expanded, &buffer) != nil {
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let parent = url.deletingLastPathComponent().path
        guard parent != url.path else { return url.path }
        let resolvedParent = canonical(parent)
        return resolvedParent == "/" ? "/" + url.lastPathComponent : resolvedParent + "/" + url.lastPathComponent
    }

    static func contains(_ parent: String, _ child: String) -> Bool {
        parent == child || child.hasPrefix(parent == "/" ? "/" : parent + "/")
    }

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}
