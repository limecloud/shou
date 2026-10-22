import Foundation
import ShouCore

/// Registration coverage and process activity are independent facts. Never use
/// a failed/partial registry read to turn a data directory into an orphan.
public struct WindowsApplicationDataEvidence: WindowsApplicationDataChecking {
    public static func makeEngine(store: any RecordStore) throws -> ShouEngine {
        #if os(Windows)
        let home=FileManager.default.homeDirectoryForCurrentUser
        return ShouEngine(store: store,filesystem: NativeFileSystem(applicationDataAccess: try WindowsApplicationDataAccess(homeDirectory: home)),homeDirectory: home)
        #else
        throw ShouError("unsupported_platform", "Windows application data requires Windows.")
        #endif
    }
    private let inventory: WindowsRegisteredApplications
    private let activity: any ApplicationActivityChecking
    public init(inventory: WindowsRegisteredApplications = .init(),activity: any ApplicationActivityChecking = NativeApplicationActivity()) {
        self.inventory=inventory;self.activity=activity
    }
    public func read() throws -> WindowsApplicationDataPresence {
        let catalog=try inventory.read(options: .init(includeSystem: true,maxEntries: 20_000,maxSeconds: 30))
        let running=try activity.runningBundleIdentifiers(in: Set(WindowsApplicationDataOwner.all.map(\.id)))
        try Task.checkCancellation()
        return .init(catalog: catalog,runningOwnerIds: running)
    }
}
