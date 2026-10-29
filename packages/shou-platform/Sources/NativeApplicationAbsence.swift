import Foundation
import ShouCore
#if os(macOS)
import AppKit
#endif

public struct NativeApplicationAbsence: ApplicationAbsenceChecking {
    public init() {}
    public func absentIdentifiers(in identifiers: Set<String>) throws -> Set<String> {
        #if os(macOS)
        let inventory=try NativeApplicationCatalog().read(options: .init(includeSystem: true))
        guard inventory.status == "complete" else {
            throw ShouError("ownership_unverified", "Application discovery is incomplete. Review application coverage before checking leftovers.",
                details: ["reason": "application_inventory_incomplete"])
        }
        let installed=Set(inventory.items.compactMap(\.bundleIdentifier))
        let running=Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Set(identifiers.filter { identifier in
            guard ReceiptIdentifier.valid(identifier), !installed.contains(identifier),
                  !running.contains(where: { $0 == identifier || $0.hasPrefix(identifier + ".") }) else { return false }
            if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                // A stale registration is not sufficient evidence to delete.
                // Treat inaccessible and unresolved registrations as present.
                if !url.path.isEmpty { return false }
            }
            return true
        })
        #else
        throw ShouError("capability_unavailable", "Application leftovers are available on macOS.")
        #endif
    }
}
private enum ReceiptIdentifier {
    static func valid(_ value: String) -> Bool { ApplicationDefinition.isValidBundleIdentifier(value) }
}
