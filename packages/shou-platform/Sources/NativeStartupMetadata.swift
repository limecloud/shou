import Foundation
import ShouCore
#if os(macOS)
import Darwin
import AppKit

enum NativeStartupMetadata {
    private static func unavailableMedia(_ path: String) -> Bool {
        ["/Volumes", "/Network", "/net", "/System/Volumes/Data/Volumes"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    static func targetState(_ path: String?) -> String {
        guard let path, path.hasPrefix("/"), path.rangeOfCharacter(from: .controlCharacters) == nil,
              let parts=try? SecurePaths.components(path), "/" + parts.joined(separator: "/") == path else { return "unknown" }
        // Missing media and remote targets do not establish a removed application.
        guard !unavailableMedia(path) else { return "unknown" }
        var metadata=stat()
        var prefix=""
        for part in parts {
            prefix += "/" + part
            if lstat(prefix, &metadata) != 0 { return errno == ENOENT || errno == ENOTDIR ? "missing" : "unknown" }
            if metadata.st_mode & S_IFMT == S_IFLNK { return "unknown" }
        }
        return "exists"
    }

    static func identity(program: String?, associatedBundle: String? = nil, deadline: ContinuousClock.Instant) -> (name: String?, application: String?) {
        var application: String?
        if let program {
            let parts=program.split(separator: "/")
            if let end=parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) {
                application="/" + parts[...end].joined(separator: "/")
            }
        }
        if application == nil, let associatedBundle, associatedBundle.utf8.count <= 255,
           associatedBundle.rangeOfCharacter(from: .controlCharacters) == nil, ContinuousClock.now < deadline {
            application=NSWorkspace.shared.urlForApplication(withBundleIdentifier: associatedBundle)?.path
        }
        guard let application else { return (nil, nil) }
        var name=URL(fileURLWithPath: application).deletingPathExtension().lastPathComponent
        let info=application + "/Contents/Info.plist"
        if !unavailableMedia(application), ContinuousClock.now < deadline, let (parent, file)=try? SecurePaths.parent(info) {
            defer { close(parent) }
            if let data=try? NativeDefinitionFiles.bytes(directory: parent, name: file, path: info, deadline: deadline),
               let dictionary=try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                if let value=(dictionary["CFBundleDisplayName"] ?? dictionary["CFBundleName"]) as? String,
                   !value.isEmpty, value.utf8.count <= 512, value.rangeOfCharacter(from: .controlCharacters) == nil { name=value }
            }
        }
        return (name, application)
    }
}
#endif
