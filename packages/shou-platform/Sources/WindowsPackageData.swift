import Foundation
import ShouCore
#if os(Windows)
import CShouWindows
#endif

public struct WindowsPackageData: WindowsPackageDataRunning {
    public init() {}
    public func inventory() throws -> RegisteredApplicationCatalog {
        try WindowsRegisteredApplications().read(options: .init(includeSystem: true,maxEntries: 20_000,maxSeconds: 30))
    }
    public func review(_ application: RegisteredApplication) throws -> WindowsPackageDataAction {
        guard application.kind=="msix",application.sourceId=="windows.user_packages" else { throw ShouError("package_data_unavailable", "Select a current-user MSIX application.") }
        #if os(Windows)
        try Task.checkCancellation()
        var identity=shou_win_info()
        var pointer: UnsafeMutablePointer<CChar>?
        let status=shou_win_package_data_review(application.registration,application.evidenceDigest,{ _ in Task.isCancelled ? 1 : 0 },nil,&identity,&pointer)
        defer { shou_win_free(pointer) }
        if let issue=Self.issue(status) { throw ShouError(issue,"The MSIX registration, stopped activity or data-store identity could not be verified.") }
        guard let pointer,let value=String(validatingCString: pointer) else { throw ShouError("invalid_application_evidence","Invalid MSIX data evidence.") }
        struct Payload: Decodable { let dataPath: String; let actionDigest: String }
        guard value.utf8.count<=65536 else { throw ShouError("invalid_application_evidence", "MSIX data evidence exceeds its limit.") }
        let payload=try Codec.decode(Payload.self,from: Data(value.utf8))
        return .init(application: application,dataPath: payload.dataPath,dataIdentity: WindowsNative.entry(identity,path: "."),actionDigest: payload.actionDigest)
        #else
        throw ShouError("unsupported_platform", "MSIX application data requires Windows.")
        #endif
    }
    public func clear(_ action: WindowsPackageDataAction,timeoutSeconds: Double) throws -> WindowsPackageDataInvocation {
        guard timeoutSeconds.isFinite,(1...120).contains(timeoutSeconds) else { throw ShouError("invalid_argument", "Invalid MSIX data-clear timeout.") }
        #if os(Windows)
        var started: Int32=0,completed: Int32=0
        let code=shou_win_package_data_clear(action.application.registration,action.application.evidenceDigest,action.actionDigest,UInt32(timeoutSeconds*1000),
            { _ in Task.isCancelled ? 1 : 0 },nil,&started,&completed)
        return .init(started: started != 0,completed: completed != 0,issue: Self.issue(code))
        #else
        throw ShouError("unsupported_platform", "MSIX application data requires Windows.")
        #endif
    }
    private static func issue(_ code: Int32) -> String? {
        switch code {
        case 0: nil
        case 1223: "cancelled"
        case 1460: "package_data_timeout"
        case 170: "application_running"
        case 2,3,1168,1006: "package_data_changed"
        case 5: "permission_denied"
        case 50,87: "package_data_unavailable"
        default: "package_data_result_unavailable"
        }
    }
}
