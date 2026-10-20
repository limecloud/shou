import Foundation
import ShouCore

/// A user-owned launcher. App updates keep the executable path stable.
public enum NativeCLIInstallation {
    public static func launcher(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/bin/shou")
    }
    public static func install(app: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let executable=app.appendingPathComponent("Contents/Helpers/shou")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ShouError("capability_unavailable", "The packaged CLI is unavailable. Install Shou in Applications first.")
        }
        let destination=launcher(home: home), directory=destination.deletingLastPathComponent()
        for parent in [destination, directory] + Array(directory.pathComponents.indices.dropFirst()).map({ index in
            URL(fileURLWithPath: NSString.path(withComponents: Array(directory.pathComponents.prefix(index))))
        }) {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: parent.path)) != nil {
                throw ShouError("permission_denied", "An existing CLI entry or parent is a symbolic link. It has been preserved.")
            }
        }
        let safe=CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        let quoted=executable.path.rangeOfCharacter(from: safe.inverted) == nil ? executable.path :
            "'" + executable.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let content=Data(("#!/bin/sh\n# Managed by Shou CLI installer.\nexec " + quoted + " \"$@\"\n").utf8)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard (try? Data(contentsOf: destination)) == content, FileManager.default.isExecutableFile(atPath: destination.path) else {
                throw ShouError("conflict", "An existing shou command differs. It has been preserved.")
            }
            return destination
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Exclusive creation preserves entries created concurrently.
        try content.write(to: destination, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }
}
