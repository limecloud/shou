import Foundation
import ShouCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)
public struct NativeCleanupLocations: CleanupLocationReading {
    public init() {}

    public func childDirectories(_ path: String) throws -> CleanupDirectoryListing {
        let directory=try SecurePaths.directory(path)
        defer { close(directory) }
        let listing=try NativeDefinitionFiles.names(directory, limit: 4_096, deadline: .now.advanced(by: .seconds(2)))
        var paths=[String](), complete = !listing.truncated
        for name in listing.names where !name.hasPrefix(".") {
            try Task.checkCancellation()
            var metadata=stat()
            guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                complete=false; continue
            }
            if metadata.st_mode & S_IFMT == S_IFDIR { paths.append(URL(fileURLWithPath: path).appendingPathComponent(name).path) }
        }
        return CleanupDirectoryListing(paths: paths, complete: complete)
    }

    public func localVolumes() throws -> [CleanupScanVolume] {
        #if os(macOS)
        let system="/System/Volumes/Data"
        let name=(try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
        var result=[CleanupScanVolume(path: system, name: name, isSystem: true)]
        guard let volumes=FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey, .volumeIsLocalKey], options: [.skipHiddenVolumes]) else {
            throw ShouError("io_error", "Local disk discovery is unavailable on this platform.")
        }
        for url in volumes where url.path != "/" && url.path != system {
            let values=try url.resourceValues(forKeys: [.volumeNameKey, .volumeIsLocalKey])
            if values.volumeIsLocal == true { result.append(CleanupScanVolume(path: url.path, name: values.volumeName ?? url.lastPathComponent, isSystem: false)) }
        }
        return result
        #else
        throw ShouError("capability_unavailable", "Local disk discovery is unavailable on this platform.")
        #endif
    }
}
#endif
