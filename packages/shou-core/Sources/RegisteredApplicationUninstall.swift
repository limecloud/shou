import Foundation

/// Windows installer registrations authorize an installer operation, never
/// direct deletion of the registered installation or guessed data directories.
public struct RegisteredUninstallAction: Codable, Sendable, Equatable {
    public let application: RegisteredApplication
    public let route: String
    public let executablePath: String?
    public let actionDigest: String
    public init(application: RegisteredApplication, route: String, executablePath: String?, actionDigest: String) {
        self.application=application; self.route=route; self.executablePath=executablePath; self.actionDigest=actionDigest
    }
}
public struct RegisteredUninstallInvocation: Sendable {
    public let started: Bool
    public let exitCode: UInt32?
    public let restartRequired: Bool
    public let issue: String?
    public init(started: Bool, exitCode: UInt32? = nil, restartRequired: Bool = false, issue: String? = nil) {
        self.started=started; self.exitCode=exitCode; self.restartRequired=restartRequired; self.issue=issue
    }
}
public protocol RegisteredApplicationUninstallRunning: Sendable {
    func inventory(options: ApplicationCatalogOptions) throws -> RegisteredApplicationCatalog
    func review(_ application: RegisteredApplication) throws -> RegisteredUninstallAction
    func uninstall(_ action: RegisteredUninstallAction, timeoutSeconds: Double) throws -> RegisteredUninstallInvocation
}
public struct RegisteredApplicationScan: Codable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let catalog: RegisteredApplicationCatalog
}
public struct RegisteredUninstallPlan: Codable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let expiresAt: Date
    public let actions: [RegisteredUninstallAction]
    public var state: String
    public var digest: String
    public func calculatedDigest() throws -> String { var copy=self; copy.state="ready"; copy.digest=""; return try Digest.of(copy) }
}
public struct RegisteredUninstallItem: Codable, Sendable, Identifiable {
    public var id: String { action.application.id }
    public let action: RegisteredUninstallAction
    public var state: String
    public var exitCode: UInt32?
    public var restartRequired: Bool
    public var error: String?
}
public struct RegisteredUninstallReceipt: Codable, Sendable, Identifiable {
    public let id: String
    public let planId: String
    public let createdAt: Date
    public var state: String
    public var items: [RegisteredUninstallItem]
}

public actor RegisteredApplicationUninstallService {
    public static let maximumApplications=20
    private let runner: any RegisteredApplicationUninstallRunning
    private let store: any RecordStore
    private let now: @Sendable () -> Date
    public init(runner: any RegisteredApplicationUninstallRunning, store: any RecordStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner=runner; self.store=store; self.now=now
    }
    public func scan(options: ApplicationCatalogOptions = .init()) throws -> RegisteredApplicationScan {
        try options.validate(); try checkCancellation()
        let catalog=try runner.inventory(options: options)
        try checkCancellation()
        let scan=RegisteredApplicationScan(id: Codec.id("registeredscan"), createdAt: now(), catalog: catalog)
        try store.write("registered-app-scans", id: scan.id, data: Codec.encode(scan))
        return scan
    }
    public func createPlan(scanId: String, applicationIds: [String]) throws -> RegisteredUninstallPlan {
        guard (1...Self.maximumApplications).contains(applicationIds.count), Set(applicationIds).count == applicationIds.count else {
            throw ShouError("invalid_argument", "Select 1–20 distinct registered applications.")
        }
        let scan: RegisteredApplicationScan=try load("registered-app-scans", id: scanId)
        // Compare at the same epoch precision used by the record codec.
        let age=now().timeIntervalSince1970 - scan.createdAt.timeIntervalSince1970
        guard scan.id == scanId, age >= 0, age < 600 else {
            throw ShouError("plan_stale", "Scan registered applications again before uninstalling.")
        }
        var actions=[RegisteredUninstallAction]()
        for id in applicationIds {
            try checkCancellation()
            guard let app=scan.catalog.items.first(where: { $0.id == id }), sourceVerified(scan.catalog, id: app.sourceId) else {
                throw ShouError("application_evidence_unavailable", "The selected installation source could not be verified.")
            }
            try validate(app)
            let action=try runner.review(app)
            try validate(action, application: app)
            actions.append(action)
        }
        try checkCancellation()
        let createdAt=now()
        var plan=RegisteredUninstallPlan(id: Codec.id("registereduninstall"), createdAt: createdAt, expiresAt: createdAt.addingTimeInterval(900), actions: actions, state: "ready", digest: "")
        plan.digest=try plan.calculatedDigest()
        try store.write("registered-uninstall-plans", id: plan.id, data: Codec.encode(plan))
        return plan
    }
    public func plan(_ id: String) throws -> RegisteredUninstallPlan {
        let plan: RegisteredUninstallPlan=try load("registered-uninstall-plans", id: id)
        guard plan.id == id, (1...Self.maximumApplications).contains(plan.actions.count),
              Set(plan.actions.map { $0.application.id }).count == plan.actions.count,
              plan.expiresAt > plan.createdAt, plan.expiresAt.timeIntervalSince(plan.createdAt) <= 900,
              try plan.calculatedDigest() == plan.digest else { throw ShouError("store_corrupt", "The uninstall plan is inconsistent.") }
        for action in plan.actions { try validate(action, application: action.application) }
        return plan
    }
    public func execute(planId: String, confirmedDigest: String) throws -> RegisteredUninstallReceipt {
        let lease=try store.lock(); defer { lease.release() }
        var plan=try plan(planId)
        guard plan.state == "ready", plan.expiresAt > now(), plan.createdAt.timeIntervalSince1970 <= now().timeIntervalSince1970, plan.digest == confirmedDigest else {
            throw ShouError("confirmation_required", "Uninstall confirmation expired or was already used.")
        }
        // Every installation is revalidated before the first installer starts.
        for action in plan.actions {
            try checkCancellation()
            guard try runner.review(action.application) == action else { throw ShouError("plan_stale", "The registered installer changed after review.") }
        }
        guard plan.expiresAt > now() else { throw ShouError("confirmation_required", "Uninstall review expired during revalidation.") }
        try checkCancellation()
        var receipt=RegisteredUninstallReceipt(id: Codec.id("registeredrun"), planId: plan.id, createdAt: now(), state: "executing",
            items: plan.actions.map { .init(action: $0, state: "not_started", restartRequired: false) })
        try save(receipt)
        plan.state="executing"; try store.write("registered-uninstall-plans", id: plan.id, data: Codec.encode(plan))
        for index in receipt.items.indices {
            if Task.isCancelled || now() >= plan.expiresAt {
                receipt.items[index].state="not_started"
                receipt.items[index].error=Task.isCancelled ? "cancelled" : "confirmation_expired"
                continue
            }
            receipt.items[index].state="executing"
            // Durable intent precedes the call that can launch an installer.
            try save(receipt)
            let remaining=plan.expiresAt.timeIntervalSince(now())
            guard remaining >= 1 else {
                receipt.items[index].state="not_started"; receipt.items[index].error="confirmation_expired"
                try save(receipt); break
            }
            do {
                let result=try runner.uninstall(plan.actions[index], timeoutSeconds: min(900, remaining))
                receipt.items[index].exitCode=result.exitCode
                receipt.items[index].restartRequired=result.restartRequired
                receipt.items[index].error=result.issue
                if !result.started {
                    receipt.items[index].state="not_started"
                } else if result.issue != nil {
                    receipt.items[index].state="needs_verification"
                } else {
                    // A process exit alone does not establish that uninstalling
                    // finished; launchers can delegate to another process.
                    let catalog=try runner.inventory(options: .init(includeSystem: true, maxEntries: 20_000, maxSeconds: 30))
                    let app=plan.actions[index].application
                    let stillRegistered=catalog.items.contains { $0.sourceId == app.sourceId && $0.registration == app.registration }
                    let samePackageFamily=app.packageFamilyName.map { family in catalog.items.contains { $0.packageFamilyName == family } } ?? false
                    receipt.items[index].state=sourceVerified(catalog, id: app.sourceId) && !stillRegistered && !samePackageFamily ? "completed" : "needs_verification"
                    if receipt.items[index].state != "completed" { receipt.items[index].error="registration_not_verified_absent" }
                }
            } catch {
                receipt.items[index].state="needs_verification"
                receipt.items[index].error=(error as? ShouError)?.code ?? "installer_result_unavailable"
            }
            try save(receipt)
            // An uncertain installation can still be running. Do not begin
            // another installer until the user has checked its actual state.
            if receipt.items[index].state != "completed" { break }
        }
        receipt.state=receipt.items.allSatisfy { $0.state == "completed" } ? "completed"
            : receipt.items.contains { $0.state == "executing" || $0.state == "needs_verification" } ? "needs_verification" : "partial"
        try save(receipt)
        plan.state="consumed"; try store.write("registered-uninstall-plans", id: plan.id, data: Codec.encode(plan))
        return receipt
    }
    public func history() throws -> [RegisteredUninstallReceipt] {
        try store.ids("registered-uninstall-history").map { try load("registered-uninstall-history", id: $0) as RegisteredUninstallReceipt }
            .sorted { $0.createdAt > $1.createdAt }
    }
    private func checkCancellation() throws { if Task.isCancelled { throw ShouError("cancelled", "Application uninstall stopped before starting another installer.") } }
    private func sourceVerified(_ catalog: RegisteredApplicationCatalog, id: String) -> Bool {
        catalog.sources.first { $0.source.id == id }.map { ["complete", "missing"].contains($0.status) } ?? false
    }
    private func validate(_ app: RegisteredApplication) throws {
        let registry=["windows.user_uninstall64", "windows.user_uninstall32", "windows.machine_uninstall64", "windows.machine_uninstall32"]
        guard !app.systemComponent, app.id == Digest.sha256(Data((app.sourceId + "\0" + app.registration).utf8)),
              app.evidenceDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              !app.name.isEmpty, !app.registration.isEmpty,
              (registry.contains(app.sourceId) && ["desktop", "msi"].contains(app.kind) && app.uninstallAvailable == true)
                || (app.sourceId == "windows.user_packages" && app.kind == "msix" && app.packageFamilyName != nil) else {
            throw ShouError("uninstall_unavailable", "A supported, removable installation registration is required.")
        }
    }
    private func validate(_ action: RegisteredUninstallAction, application: RegisteredApplication) throws {
        try validate(application)
        guard action.application == application, ["desktop", "msi", "msix"].contains(action.route), action.route == application.kind,
              action.actionDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              action.route == "msix" ? action.executablePath == nil : action.executablePath?.range(of: "^[A-Za-z]:/[^\r\n]+\\.exe$", options: [.regularExpression, .caseInsensitive]) != nil else {
            throw ShouError("invalid_application_evidence", "The installer review does not match the selected application.")
        }
    }
    private func save(_ receipt: RegisteredUninstallReceipt) throws { try store.write("registered-uninstall-history", id: receipt.id, data: Codec.encode(receipt)) }
    private func load<T: Decodable>(_ collection: String, id: String) throws -> T {
        guard let data=try store.read(collection, id: id) else { throw ShouError("invalid_argument", "Unknown application review record.") }
        do { return try Codec.decode(T.self, from: data) } catch { throw ShouError("store_corrupt", "The application review record is unreadable.") }
    }
}
