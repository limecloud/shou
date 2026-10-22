import Foundation
import ShouCore
#if os(macOS)
import AppKit
#endif
#if os(Windows)
import CShouWindows
#endif

public struct NativeApplicationActivity: ApplicationActivityChecking {
    public init() {}
    public func runningBundleIdentifiers(in identifiers: Set<String>) throws -> Set<String> {
        #if os(macOS)
        return Set(identifiers.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
        #elseif os(Windows)
        return try WindowsApplicationActivity { name in
            var present: Int32=0
            try WindowsNative.check(name.withCString { shou_win_process_running($0, &present) }, path: name)
            return present != 0
        }.runningBundleIdentifiers(in: identifiers)
        #else
        throw ShouError("application_activity_unavailable", "Application activity checking is unavailable on this platform.")
        #endif
    }
}
