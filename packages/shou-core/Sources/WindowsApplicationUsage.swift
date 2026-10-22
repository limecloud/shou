import Foundation

public struct WindowsApplicationUsageOptions: Sendable {
    public let maxEntries: Int
    public let maxSeconds: Double
    public init(maxEntries: Int = 100_000, maxSeconds: Double = 30) { self.maxEntries=maxEntries; self.maxSeconds=maxSeconds }
    public func validate() throws {
        guard (1...1_000_000).contains(maxEntries), maxSeconds.isFinite, (1...120).contains(maxSeconds) else {
            throw ShouError("invalid_argument", "Application measurement budgets are outside supported limits.")
        }
    }
}

/// Observed directory allocation, independent of ownership and removal rights.
/// Separate applications may declare the same or overlapping installation roots.
public struct WindowsApplicationUsage: Codable, Sendable, Equatable {
    public let application: RegisteredApplication
    public let checkedAt: Date
    public let path: String
    public let status: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let fileCount: Int
    public let visitedEntries: Int
    public let issues: [String]
    public init(application: RegisteredApplication, checkedAt: Date = Date(), path: String, status: String, logicalBytes: Int64,
                allocatedBytes: Int64, fileCount: Int, visitedEntries: Int, issues: [String]) {
        self.application=application; self.checkedAt=checkedAt; self.path=path; self.status=status; self.logicalBytes=logicalBytes
        self.allocatedBytes=allocatedBytes; self.fileCount=fileCount; self.visitedEntries=visitedEntries; self.issues=issues
    }
}

public protocol WindowsApplicationUsageReading: Sendable {
    func inventory() throws -> RegisteredApplicationCatalog
    func measure(_ application: RegisteredApplication, options: WindowsApplicationUsageOptions) throws -> WindowsApplicationUsage
}

public actor WindowsApplicationUsageService {
    private let reader: any WindowsApplicationUsageReading
    private let store: any RecordStore
    private let now: @Sendable () -> Date
    public init(reader: any WindowsApplicationUsageReading, store: any RecordStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader=reader; self.store=store; self.now=now
    }
    public func scan() throws -> RegisteredApplicationScan {
        try Task.checkCancellation()
        let catalog=try reader.inventory()
        try Task.checkCancellation()
        let scan=RegisteredApplicationScan(id: Codec.id("registeredscan"),createdAt: now(),catalog: catalog)
        try store.write("registered-app-scans",id: scan.id,data: Codec.encode(scan)); return scan
    }
    public func measure(scanId: String, applicationId: String, options: WindowsApplicationUsageOptions = .init()) throws -> WindowsApplicationUsage {
        try options.validate(); try Task.checkCancellation()
        guard let data=try store.read("registered-app-scans",id: scanId) else { throw ShouError("invalid_argument", "Unknown application registration scan.") }
        let scan: RegisteredApplicationScan
        do { scan=try Codec.decode(RegisteredApplicationScan.self,from: data) }
        catch { throw ShouError("store_corrupt", "The application registration scan is unreadable.") }
        let age=now().timeIntervalSince1970-scan.createdAt.timeIntervalSince1970
        guard scan.id==scanId, age>=0, age<600 else { throw ShouError("plan_stale", "Scan application registrations again before measuring.") }
        guard let app=scan.catalog.items.first(where: { $0.id==applicationId }) else { throw ShouError("invalid_argument", "Select one application from the registration scan.") }
        try require(app,in: scan.catalog)
        try require(app,in: reader.inventory())
        try Task.checkCancellation()
        let usage=try reader.measure(app,options: options)
        try Task.checkCancellation()
        try require(app,in: reader.inventory())
        try Task.checkCancellation()
        guard usage.application==app, let path=WindowsCacheAccess.comparisonPath(usage.path), path.count>3,
              app.kind=="msix" || app.installLocation.flatMap(WindowsCacheAccess.comparisonPath)==path,
              ["complete","partial"].contains(usage.status), usage.logicalBytes>=0, usage.allocatedBytes>=0,
              (1...options.maxEntries).contains(usage.visitedEntries), (0..<usage.visitedEntries).contains(usage.fileCount),
              usage.issues.count<=16, Set(usage.issues).count==usage.issues.count,
              usage.issues.allSatisfy({ $0.range(of: "^[a-z_]{1,64}$",options: .regularExpression) != nil }),
              (usage.status=="complete") == usage.issues.isEmpty else {
            throw ShouError("invalid_application_evidence", "The measured application directory or coverage is inconsistent.")
        }
        return usage
    }
    private func require(_ app: RegisteredApplication,in catalog: RegisteredApplicationCatalog) throws {
        guard catalog.scope=="windows_registered_applications", catalog.items.filter({ $0.id==app.id }).count==1,
              catalog.items.first(where: { $0.id==app.id })==app,
              catalog.sources.filter({ $0.source.id==app.sourceId && $0.status=="complete" }).count==1,
              app.id==Digest.sha256(Data((app.sourceId+"\0"+app.registration).utf8)),
              app.evidenceDigest.range(of: "^[a-f0-9]{64}$",options: .regularExpression) != nil,
              (app.kind=="msix" ? app.sourceId=="windows.user_packages" : ["desktop","msi"].contains(app.kind) &&
                ["windows.user_uninstall64","windows.user_uninstall32","windows.machine_uninstall64","windows.machine_uninstall32"].contains(app.sourceId)) else {
            throw ShouError("plan_stale", "Application registration or source coverage changed. Scan again.")
        }
    }
}
