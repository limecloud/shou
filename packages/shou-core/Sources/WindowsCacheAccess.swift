import Foundation

/// Only bundled Windows cache locations and their declared cache subtrees can
/// cross the AppData root boundary. Profile data and arbitrary personal rules
/// cannot expand this permission.
public struct WindowsCacheAccess: Sendable {
    private struct Scope: Sendable {
        let root: String
        let patterns: [PathPattern.Compiled]
    }
    private let scopes: [Scope]

    public init(homeDirectory: URL) throws {
        let templates=try BuiltinCatalog.templates().filter { $0.supportedPlatforms.contains("windows") && $0.location != "projects" }
        scopes=try KnownLocations.catalog(homeDirectory: homeDirectory, platform: "windows").map { location in
            guard let root=Self.comparisonPath(location.path) else { throw ShouError("invalid_argument", "The Windows cache home directory is invalid.") }
            return Scope(root: root, patterns: templates.filter { $0.location == location.id }.flatMap(\.patterns).map { PathPattern.Compiled($0, caseSensitive: false) })
        }
    }

    public func permitsRoot(_ path: String) -> Bool {
        guard let path=Self.comparisonPath(path) else { return false }
        return scopes.contains { $0.root == path }
    }

    public func permitsTarget(_ path: String) -> Bool {
        guard let path=Self.comparisonPath(path) else { return false }
        for scope in scopes where path.hasPrefix(scope.root + "/") {
            let parts=path.dropFirst(scope.root.count + 1).split(separator: "/").map(String.init)
            // A selected child of a declared cache is safe as well. Ancestors
            // such as a browser profile or the cache scan root are never safe.
            for count in 1...parts.count where scope.patterns.contains(where: { $0.matches(Array(parts.prefix(count))) }) { return true }
        }
        return false
    }

    static func comparisonPath(_ value: String) -> String? {
        var path=value.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("/"), path.count > 3, path.dropFirst(2).hasPrefix(":/") { path.removeFirst() }
        guard path.rangeOfCharacter(from: .controlCharacters) == nil, !path.hasPrefix("//"),
              path.hasPrefix("/") || path.range(of: "^[A-Za-z]:/", options: .regularExpression) != nil else { return nil }
        while path.hasSuffix("/"), path.count > 1 { path.removeLast() }
        let parts=path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasSuffix(".") || $0.hasSuffix(" ") || $0.contains(":") }) else { return nil }
        return path.lowercased()
    }
}
