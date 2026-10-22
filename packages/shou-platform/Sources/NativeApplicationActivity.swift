import Foundation
import ShouCore
#if os(macOS)
import AppKit
#endif

public struct NativeApplicationActivity: ApplicationActivityChecking {
    public init() {}
    public func runningBundleIdentifiers(in identifiers: Set<String>) throws -> Set<String> {
        #if os(macOS)
        return Set(identifiers.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
        #else
        throw ShouError("application_activity_unavailable", "Application activity checking is unavailable on this platform.")
        #endif
    }
}
