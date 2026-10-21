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
        let names=["com.google.Chrome": "chrome.exe", "com.microsoft.edgemac": "msedge.exe", "com.microsoft.VSCode": "Code.exe"]
        var running=Set<String>()
        for identifier in identifiers {
            guard let name=names[identifier] else { throw ShouError("application_activity_unavailable", "Unknown application activity mapping.") }
            var present: Int32=0
            try WindowsNative.check(name.withCString { shou_win_process_running($0, &present) }, path: name)
            if present != 0 { running.insert(identifier) }
        }
        return running
        #else
        throw ShouError("application_activity_unavailable", "Application activity checking is unavailable on this platform.")
        #endif
    }
}
