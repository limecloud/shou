import Foundation

/// A package-scoped Windows operation. This never grants file deletion rights
/// to package installation directories or the AppData/Packages tree.
public struct WindowsPackageDataAction: Codable, Sendable, Equatable {
    public let application: RegisteredApplication
    public let dataPath: String
    public let dataIdentity: FileEntry
    public let actionDigest: String
    public init(application: RegisteredApplication, dataPath: String, dataIdentity: FileEntry, actionDigest: String) {
        self.application=application; self.dataPath=dataPath; self.dataIdentity=dataIdentity; self.actionDigest=actionDigest
    }
}
public struct WindowsPackageDataInvocation: Sendable {
    public let started: Bool
    public let completed: Bool
    public let issue: String?
    public init(started: Bool, completed: Bool = false, issue: String? = nil) { self.started=started; self.completed=completed; self.issue=issue }
}
public protocol WindowsPackageDataRunning: Sendable {
    func inventory() throws -> RegisteredApplicationCatalog
    func review(_ application: RegisteredApplication) throws -> WindowsPackageDataAction
    func clear(_ action: WindowsPackageDataAction, timeoutSeconds: Double) throws -> WindowsPackageDataInvocation
}
public struct WindowsPackageDataPlan: Codable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let expiresAt: Date
    public let actions: [WindowsPackageDataAction]
    public let includesUserData: Bool
    public var state: String
    public var digest: String
    public func calculatedDigest() throws -> String { var copy=self; copy.state="ready"; copy.digest=""; return try Digest.of(copy) }
}
public struct WindowsPackageDataItem: Codable, Sendable, Identifiable {
    public var id: String { action.application.id }
    public let action: WindowsPackageDataAction
    public var state: String
    public var error: String?
}
public struct WindowsPackageDataReceipt: Codable, Sendable, Identifiable {
    public let id: String
    public let planId: String
    public let createdAt: Date
    public var state: String
    public var items: [WindowsPackageDataItem]
}

public actor WindowsPackageDataService {
    public static let maximumApplications=20
    private let runner: any WindowsPackageDataRunning
    private let store: any RecordStore
    private let now: @Sendable () -> Date
    public init(runner: any WindowsPackageDataRunning, store: any RecordStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner=runner; self.store=store; self.now=now
    }
    public func scan() throws -> RegisteredApplicationScan {
        try Task.checkCancellation()
        let catalog=try runner.inventory()
        try Task.checkCancellation()
        let scan=RegisteredApplicationScan(id: Codec.id("registeredscan"), createdAt: now(), catalog: catalog)
        try store.write("registered-app-scans",id: scan.id,data: Codec.encode(scan)); return scan
    }
    public func createPlan(scanId: String, applicationIds: [String], includeUserData: Bool) throws -> WindowsPackageDataPlan {
        guard includeUserData else { throw ShouError("confirmation_required", "Separately consent to clearing all selected MSIX application data.") }
        guard (1...Self.maximumApplications).contains(applicationIds.count), Set(applicationIds).count==applicationIds.count else {
            throw ShouError("invalid_argument", "Select 1–20 distinct MSIX applications.")
        }
        let scan: RegisteredApplicationScan=try load("registered-app-scans",id: scanId)
        let age=now().timeIntervalSince1970-scan.createdAt.timeIntervalSince1970
        guard scan.id==scanId, age>=0, age<600, verified(scan.catalog) else { throw ShouError("plan_stale", "Review complete current-user MSIX registrations again.") }
        var actions=[WindowsPackageDataAction]()
        for id in applicationIds {
            try Task.checkCancellation()
            guard let app=scan.catalog.items.first(where: { $0.id==id }) else { throw ShouError("invalid_argument", "Unknown MSIX selection.") }
            try validate(app)
            let action=try runner.review(app); try validate(action)
            guard action.application==app,!actions.contains(where: { $0.application.packageFamilyName?.lowercased()==app.packageFamilyName?.lowercased() }) else {
                throw ShouError("invalid_application_evidence", "The MSIX data scope does not match a distinct selected package family.")
            }
            actions.append(action)
        }
        try Task.checkCancellation()
        let date=now()
        var plan=WindowsPackageDataPlan(id: Codec.id("packagedataplan"),createdAt: date,expiresAt: date.addingTimeInterval(120),actions: actions,includesUserData: true,state: "ready",digest: "")
        plan.digest=try plan.calculatedDigest()
        try store.write("windows-package-data-plans",id: plan.id,data: Codec.encode(plan)); return plan
    }
    public func plan(_ id: String) throws -> WindowsPackageDataPlan {
        let plan: WindowsPackageDataPlan=try load("windows-package-data-plans",id: id)
        guard plan.id==id, plan.includesUserData, (1...Self.maximumApplications).contains(plan.actions.count),
              Set(plan.actions.map { $0.application.id }).count==plan.actions.count,
              Set(plan.actions.compactMap { $0.application.packageFamilyName?.lowercased() }).count==plan.actions.count,
              plan.expiresAt>plan.createdAt, plan.expiresAt.timeIntervalSince(plan.createdAt)<=120,
              try plan.digest==plan.calculatedDigest() else { throw ShouError("store_corrupt", "The MSIX data-clear plan is inconsistent.") }
        for action in plan.actions { try validate(action) }; return plan
    }
    public func execute(planId: String, confirmedDigest: String) throws -> WindowsPackageDataReceipt {
        let lease=try store.lock(); defer { lease.release() }
        var plan=try plan(planId)
        guard plan.state=="ready",plan.createdAt<=now(),plan.expiresAt>now(),plan.digest==confirmedDigest else {
            throw ShouError("confirmation_required", "MSIX data-clear confirmation expired or was already used.")
        }
        for action in plan.actions {
            try Task.checkCancellation()
            guard try runner.review(action.application)==action else { throw ShouError("plan_stale", "MSIX registration, activity or data identity changed.") }
        }
        try Task.checkCancellation()
        guard plan.expiresAt>now() else { throw ShouError("confirmation_required", "MSIX data-clear review expired during revalidation.") }
        var receipt=WindowsPackageDataReceipt(id: Codec.id("packagedatarun"),planId: plan.id,createdAt: now(),state: "executing",
            items: plan.actions.map { .init(action: $0,state: "not_started") })
        try save(receipt)
        plan.state="executing"; try store.write("windows-package-data-plans",id: plan.id,data: Codec.encode(plan))
        for index in receipt.items.indices {
            if Task.isCancelled || now()>=plan.expiresAt {
                receipt.items[index].error=Task.isCancelled ? "cancelled" : "confirmation_expired"; break
            }
            do {
                guard try runner.review(plan.actions[index].application)==plan.actions[index] else { throw ShouError("plan_stale", "MSIX data changed before clearing.") }
            } catch {
                receipt.items[index].error=code(error); try save(receipt); break
            }
            let remaining=plan.expiresAt.timeIntervalSince(now())
            if Task.isCancelled || remaining<1 { receipt.items[index].error=Task.isCancelled ? "cancelled" : "confirmation_expired"; break }
            receipt.items[index].state="executing"
            // Persist intent before invoking a Windows operation that can
            // continue after the client stops waiting or loses its response.
            try save(receipt)
            do {
                let result=try runner.clear(plan.actions[index],timeoutSeconds: min(120,remaining))
                receipt.items[index].error=result.issue
                receipt.items[index].state = !result.started ? "not_started" : result.completed && result.issue==nil ? "completed" : "needs_verification"
            } catch {
                receipt.items[index].state="needs_verification"; receipt.items[index].error=code(error)
            }
            try save(receipt)
            if receipt.items[index].state != "completed" { break }
        }
        receipt.state=receipt.items.allSatisfy { $0.state=="completed" } ? "completed" :
            receipt.items.contains { ["executing","needs_verification"].contains($0.state) } ? "needs_verification" : "partial"
        try save(receipt)
        plan.state="consumed"; try store.write("windows-package-data-plans",id: plan.id,data: Codec.encode(plan)); return receipt
    }
    public func history() throws -> [WindowsPackageDataReceipt] {
        try store.ids("windows-package-data-history").map { try load("windows-package-data-history",id: $0) as WindowsPackageDataReceipt }.sorted { $0.createdAt>$1.createdAt }
    }
    private func verified(_ catalog: RegisteredApplicationCatalog) -> Bool {
        catalog.scope=="windows_registered_applications" && catalog.status=="complete" && catalog.sources.filter { $0.source.id=="windows.user_packages" }.count==1 &&
            catalog.sources.first { $0.source.id=="windows.user_packages" }?.status=="complete" &&
            catalog.issues.isEmpty
    }
    private func validate(_ app: RegisteredApplication) throws {
        guard app.kind=="msix",app.sourceId=="windows.user_packages",!app.systemComponent,
              app.id==Digest.sha256(Data((app.sourceId+"\0"+app.registration).utf8)), !app.name.isEmpty,
              app.registration.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]+$",options: .regularExpression) != nil,
              app.packageFamilyName?.range(of: "^[A-Za-z0-9.-]+_[A-Za-z0-9]+$",options: .regularExpression) != nil,
              app.evidenceDigest.range(of: "^[a-f0-9]{64}$",options: .regularExpression) != nil else {
            throw ShouError("package_data_unavailable", "A supported current-user MSIX registration is required.")
        }
    }
    private func validate(_ action: WindowsPackageDataAction) throws {
        try validate(action.application)
        guard let path=WindowsCacheAccess.comparisonPath(action.dataPath),let family=action.application.packageFamilyName,
              path.hasSuffix("/packages/"+family.lowercased()),action.dataIdentity.path==".",action.dataIdentity.kind=="directory",
              action.dataIdentity.windowsIdentity != nil, action.actionDigest.range(of: "^[a-f0-9]{64}$",options: .regularExpression) != nil else {
            throw ShouError("invalid_application_evidence", "The Windows-managed MSIX data scope is invalid.")
        }
    }
    private func code(_ error: Error) -> String { error is CancellationError ? "cancelled" : (error as? ShouError)?.code ?? "package_data_result_unavailable" }
    private func save(_ receipt: WindowsPackageDataReceipt) throws { try store.write("windows-package-data-history",id: receipt.id,data: Codec.encode(receipt)) }
    private func load<T: Decodable>(_ collection: String,id: String) throws -> T {
        guard let data=try store.read(collection,id: id) else { throw ShouError("invalid_argument", "Unknown MSIX data-clear record.") }
        do { return try Codec.decode(T.self,from: data) } catch { throw ShouError("store_corrupt", "The MSIX data-clear record is unreadable.") }
    }
}
