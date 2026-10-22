import Foundation
import ShouCore
#if os(Windows)
import CShouWindows
#endif

public struct WindowsRegisteredApplicationUninstall: RegisteredApplicationUninstallRunning {
    public init() {}
    public func inventory(options: ApplicationCatalogOptions) throws -> RegisteredApplicationCatalog {
        try WindowsRegisteredApplications().read(options: options)
    }
    public func review(_ application: RegisteredApplication) throws -> RegisteredUninstallAction {
        #if os(Windows)
        if Task.isCancelled { throw ShouError("cancelled", "Application review stopped.") }
        let value=try WindowsNative.string({ result in
            shou_win_application_uninstall_review(application.sourceId, application.registration, application.evidenceDigest, result)
        }, path: "Registered application installer")
        struct Payload: Decodable { let route: String; let executablePath: String?; let actionDigest: String }
        guard value.utf8.count <= 65536 else { throw ShouError("invalid_application_evidence", "The installer review exceeds its limit.") }
        let payload=try Codec.decode(Payload.self, from: Data(value.utf8))
        return .init(application: application, route: payload.route, executablePath: payload.executablePath, actionDigest: payload.actionDigest)
        #else
        throw ShouError("unsupported_platform", "Registered installer operations require Windows.")
        #endif
    }
    public func uninstall(_ action: RegisteredUninstallAction, timeoutSeconds: Double) throws -> RegisteredUninstallInvocation {
        guard timeoutSeconds.isFinite, (1...900).contains(timeoutSeconds) else { throw ShouError("invalid_argument", "Invalid installer time limit.") }
        #if os(Windows)
        var started: Int32=0, restart: Int32=0, exitCode=UInt32.max
        let app=action.application
        let code=shou_win_application_uninstall_execute(app.sourceId, app.registration, app.evidenceDigest, action.actionDigest,
            UInt32(timeoutSeconds * 1000), { _ in Task.isCancelled ? 1 : 0 }, nil, &started, &exitCode, &restart)
        let issue: String?
        switch code {
        case 0: issue=nil
        case 1223: issue="cancelled"
        case 1460: issue="installer_timeout"
        case 2, 3, 1168, 1006: issue="installer_changed"
        case 5: issue="permission_denied"
        case 50, 87: issue="uninstall_unavailable"
        case 234: issue="resource_limit"
        case 1067: issue="installer_failed"
        default: issue="installer_result_unavailable"
        }
        return .init(started: started != 0, exitCode: exitCode == UInt32.max ? nil : exitCode, restartRequired: restart != 0, issue: issue)
        #else
        throw ShouError("unsupported_platform", "Registered installer operations require Windows.")
        #endif
    }
}
