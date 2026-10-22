import Foundation
import ShouCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)
public enum NativeDirectorySelection {
    /// Foundation can turn /private/var back into the /var alias, even after
    /// resolving links. Preserve the physical selection for no-follow scans.
    public static func path(for url: URL) throws -> String {
        guard url.isFileURL, let pointer=url.path.withCString({ realpath($0, nil) }) else {
            throw ShouError("invalid_argument", "The selected folder could not be resolved.")
        }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
#endif
