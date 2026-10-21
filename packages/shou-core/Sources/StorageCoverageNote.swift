import Foundation

public struct StorageCoverageNote: Sendable {
    public let code: String
    public let path: String
    public let systemManaged: Bool
    public init(issue: String, root: String) {
        let parts=issue.components(separatedBy: ": ")
        code=parts[0]; path=parts.dropFirst().joined(separator: ": ")
        let absolute=StorageRemovalPolicy.canonical(StorageRemovalPolicy.absolute(root: root, relative: path.isEmpty ? "." : path))
        let system=["/.DocumentRevisions-V100", "/.Spotlight-V100", "/.fseventsd", "/System", "/dev", "/home", "/net", "/private/var/db", "/private/var/agentx", "/private/var/OOPJit", "/private/var/run", "/private/var/audit", "/private/var/spool"]
        let folded=absolute.lowercased()
        let protectedLocation=system.contains { absolute == $0 || absolute.hasPrefix($0 + "/") } ||
            ["/$recycle.bin", "/system volume information", "/windows"].contains { folded.dropFirst(2).hasPrefix($0 + "/") || String(folded.dropFirst(2)) == $0 }
        systemManaged=["authorization_required", "unreadable", "unreadable_directory"].contains(code) && protectedLocation
    }
    public func concerns(_ directory: String) -> Bool {
        directory == "." || path.isEmpty || path == "." || path == directory || path.hasPrefix(directory + "/") || directory.hasPrefix(path + "/")
    }
}
