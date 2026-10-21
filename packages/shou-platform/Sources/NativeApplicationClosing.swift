import Foundation
import ShouCore
#if os(macOS)
import AppKit
import Darwin
#endif

public struct NativeApplicationClosing: ApplicationClosing {
    public init() {}
    public func requestClose(_ application: ApplicationDefinition) async throws {
        #if os(macOS)
        guard try NativeApplicationCatalog().application(at: application.path) == application,
              let identifier=application.bundleIdentifier else { throw ShouError("plan_stale", "Application identity changed before closing.") }
        let accepted=await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter {
                $0.bundleURL?.standardizedFileURL.path == application.path && $0.processIdentifier != getpid()
            }.allSatisfy { $0.terminate() }
        }
        guard accepted else { throw ShouError("application_running", "The application declined to quit. Save your work and close it, then retry.") }
        #else
        throw ShouError("capability_unavailable", "Application closing is unavailable on this platform.")
        #endif
    }
}
