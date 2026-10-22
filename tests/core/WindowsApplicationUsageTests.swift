import Foundation
import ShouCore
import ShouPlatform

private func usageFixtureApplication(kind: String = "desktop") throws -> RegisteredApplication {
    let source=kind=="msix" ? "windows.user_packages" : "windows.user_uninstall64"
    let registration=kind=="msix" ? "Generated.Usage_1.0.0.0_x64__fixture1234" : "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\GeneratedUsage"
    let data: [String: Any]=["id": Digest.sha256(Data((source+"\0"+registration).utf8)),"source_id": source,"registration": registration,
        "name": "Generated usage application","kind": kind,"system_component": false,"install_location": kind=="msix" ? NSNull() : "C:/generated/usage",
        "evidence_digest": String(repeating: "a",count: 64),"package_family_name": kind=="msix" ? "Generated.Usage_fixture1234" : NSNull()]
    return try Codec.decode(RegisteredApplication.self,from: JSONSerialization.data(withJSONObject: data))
}
private final class UsageFixture: WindowsApplicationUsageReading,@unchecked Sendable {
    var app: RegisteredApplication
    var partialSource=false,missing=false,mode="complete",changedAfter=false
    private(set) var measurements=0
    init(kind: String = "desktop") throws { app=try usageFixtureApplication(kind: kind) }
    func inventory() throws -> RegisteredApplicationCatalog {
        .init(checkedAt: Date(),sources: [.init(source: .init(id: app.sourceId,path: "generated"),status: partialSource || changedAfter && measurements>0 ? "partial" : "complete",entryCount: 1,applicationCount: 1)],items: missing ? [] : [app],issues: [])
    }
    func measure(_ application: RegisteredApplication,options: WindowsApplicationUsageOptions) throws -> WindowsApplicationUsage {
        measurements+=1
        if mode=="cancelled" { throw CancellationError() }
        let partial=mode=="partial"
        return .init(application: application,path: mode=="path" ? "C:/generated/other" : app.kind=="msix" ? "C:/Program Files/WindowsApps/Generated.Usage" : "C:/generated/usage",
            status: partial ? "partial" : "complete",logicalBytes: mode=="negative" ? -1 : 5000,allocatedBytes: 8192,
            fileCount: 1,visitedEntries: mode=="limit" ? options.maxEntries+1 : 2,
            issues: partial ? ["entry_limit"] : mode=="coverage" ? ["entry_unavailable"] : [])
    }
}
func windowsApplicationUsageBindsCurrentRegistrationWithoutMutationGrants() async throws {
    for kind in ["desktop","msi","msix"] {
        let fixture=try Fixture(),reader=try UsageFixture(kind: kind),service=WindowsApplicationUsageService(reader: reader,store: fixture.store)
        try fixture.put("retained.txt","keep generated installation data")
        let scan=try await service.scan(),result=try await service.measure(scanId: scan.id,applicationId: reader.app.id)
        try expect(result.application==reader.app && result.status=="complete" && result.allocatedBytes==8192 && result.logicalBytes==5000)
        try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("retained.txt"),encoding: .utf8)=="keep generated installation data")
        for collection in ["plans","history","registered-uninstall-plans","windows-package-data-plans"] { try expect(try fixture.store.ids(collection).isEmpty) }
    }
}
func windowsApplicationUsageRejectsStaleSourcesExpiryAndWrongSelections() async throws {
    let fixture=try Fixture(),reader=try UsageFixture(),date=Date(timeIntervalSince1970: 1_800_000_000)
    let service=WindowsApplicationUsageService(reader: reader,store: fixture.store,now: { date })
    let scan=try await service.scan()
    try await expectThrows { try await service.measure(scanId: scan.id,applicationId: "unknown") }
    for mode in ["partial","missing"] {
        reader.partialSource=mode=="partial";reader.missing=mode=="missing"
        try await expectThrows { try await service.measure(scanId: scan.id,applicationId: reader.app.id) }
    }
    reader.partialSource=false;reader.missing=false
    let expired=WindowsApplicationUsageService(reader: reader,store: fixture.store,now: { date.addingTimeInterval(601) })
    try await expectThrows { try await expired.measure(scanId: scan.id,applicationId: reader.app.id) }
    try expect(reader.measurements==0)
    reader.changedAfter=true
    try await expectThrows { try await service.measure(scanId: scan.id,applicationId: reader.app.id) }
    try expect(reader.measurements==1)
}
func windowsApplicationUsageKeepsPartialObservationsAndRejectsForgedCounts() async throws {
    let fixture=try Fixture(),reader=try UsageFixture(),service=WindowsApplicationUsageService(reader: reader,store: fixture.store)
    let scan=try await service.scan();reader.mode="partial"
    let partial=try await service.measure(scanId: scan.id,applicationId: reader.app.id)
    try expect(partial.status=="partial" && partial.issues==["entry_limit"] && partial.allocatedBytes==8192)
    for mode in ["path","negative","limit","coverage"] {
        reader.mode=mode
        try await expectThrows { try await service.measure(scanId: scan.id,applicationId: reader.app.id) }
    }
}
func windowsApplicationUsageValidatesBudgetsAndCooperatesWithCancellation() async throws {
    let fixture=try Fixture(),reader=try UsageFixture(),service=WindowsApplicationUsageService(reader: reader,store: fixture.store)
    let scan=try await service.scan()
    for options in [WindowsApplicationUsageOptions(maxEntries: 0),.init(maxEntries: 1_000_001),.init(maxSeconds: 0),.init(maxSeconds: 121),.init(maxSeconds: .nan)] {
        try await expectThrows { try await service.measure(scanId: scan.id,applicationId: reader.app.id,options: options) }
    }
    try expect(reader.measurements==0)
    let task=Task { while !Task.isCancelled { await Task.yield() };return try await service.measure(scanId: scan.id,applicationId: reader.app.id) }
    task.cancel();try await expectThrows { try await task.value };try expect(reader.measurements==0)
    reader.mode="cancelled";try await expectThrows { try await service.measure(scanId: scan.id,applicationId: reader.app.id) }
    try expect(try fixture.store.ids("history").isEmpty)
}
