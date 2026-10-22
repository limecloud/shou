import Foundation
import ShouCore
#if os(Windows)
import CShouWindows
#endif

public struct WindowsApplicationUsageReader: WindowsApplicationUsageReading {
    public init() {}
    public func inventory() throws -> RegisteredApplicationCatalog {
        try WindowsRegisteredApplications().read(options: .init(includeSystem: true,maxEntries: 20_000,maxSeconds: 30))
    }
    public func measure(_ application: RegisteredApplication,options: WindowsApplicationUsageOptions) throws -> WindowsApplicationUsage {
        try options.validate(); try Task.checkCancellation()
        #if os(Windows)
        var pointer: UnsafeMutablePointer<CChar>?
        let code=shou_win_application_usage(application.sourceId,application.registration,application.evidenceDigest,
            options.maxEntries,UInt32(options.maxSeconds*1000),{ _ in Task.isCancelled ? 1 : 0 },nil,&pointer)
        defer { shou_win_free(pointer) }
        guard code==0 else {
            let issue=code==1223 ? "cancelled" : [2,3,1006,1168].contains(code) ? "plan_stale" : code==5 ? "permission_denied" : "application_measurement_unavailable"
            throw ShouError(issue,"The registered installation directory could not be measured.")
        }
        guard let pointer,let text=String(validatingCString: pointer),text.utf8.count<=65536 else {
            throw ShouError("invalid_application_evidence", "Invalid application measurement response.")
        }
        struct Payload: Decodable {
            let path: String; let status: String; let logicalBytes: Int64; let allocatedBytes: Int64
            let fileCount: Int; let visitedEntries: Int; let issues: [String]
        }
        let value=try Codec.decode(Payload.self,from: Data(text.utf8))
        return .init(application: application,path: value.path,status: value.status,logicalBytes: value.logicalBytes,
            allocatedBytes: value.allocatedBytes,fileCount: value.fileCount,visitedEntries: value.visitedEntries,issues: value.issues)
        #else
        throw ShouError("unsupported_platform", "Registered installation measurement requires Windows.")
        #endif
    }
}
