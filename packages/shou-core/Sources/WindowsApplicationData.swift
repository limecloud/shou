import Foundation

/// Maintained associations name complete personal-data roots, never installation
/// directories or mixed publisher parents. Registration labels only establish
/// presence; portable/custom installations remain an explicit coverage limit.
public struct WindowsApplicationDataOwner: Sendable {
    public let id: String
    public let name: String
    public let registrationNames: [String]
    public let relativePaths: [String]
    public static let all: [Self] = [
        .init(id: "com.google.Chrome", name: "Google Chrome", registrationNames: ["Google Chrome"], relativePaths: ["AppData/Local/Google/Chrome/User Data"]),
        .init(id: "org.chromium.Chromium", name: "Chromium", registrationNames: ["Chromium"], relativePaths: ["AppData/Local/Chromium/User Data"]),
        .init(id: "com.microsoft.edgemac", name: "Microsoft Edge", registrationNames: ["Microsoft Edge"], relativePaths: ["AppData/Local/Microsoft/Edge/User Data"]),
        .init(id: "com.brave.Browser", name: "Brave", registrationNames: ["Brave", "Brave Browser"], relativePaths: ["AppData/Local/BraveSoftware/Brave-Browser/User Data"]),
        .init(id: "com.vivaldi.Vivaldi", name: "Vivaldi", registrationNames: ["Vivaldi"], relativePaths: ["AppData/Local/Vivaldi/User Data"]),
        .init(id: "org.mozilla.firefox", name: "Firefox", registrationNames: ["Mozilla Firefox", "Mozilla Firefox (x64 en-US)", "Mozilla Firefox (x64 zh-CN)", "Mozilla Firefox (x86 en-US)", "Mozilla Firefox (x86 zh-CN)"], relativePaths: ["AppData/Roaming/Mozilla/Firefox", "AppData/Local/Mozilla/Firefox"]),
        .init(id: "com.microsoft.VSCode", name: "Visual Studio Code", registrationNames: ["Microsoft Visual Studio Code", "Microsoft Visual Studio Code (User)"], relativePaths: ["AppData/Roaming/Code"]),
        .init(id: "com.microsoft.VSCodeInsiders", name: "Visual Studio Code Insiders", registrationNames: ["Microsoft Visual Studio Code Insiders", "Microsoft Visual Studio Code Insiders (User)"], relativePaths: ["AppData/Roaming/Code - Insiders"]),
        .init(id: "com.tinyspeck.slackmacgap", name: "Slack", registrationNames: ["Slack"], relativePaths: ["AppData/Roaming/Slack"]),
        .init(id: "com.hnc.Discord", name: "Discord", registrationNames: ["Discord"], relativePaths: ["AppData/Roaming/discord"]),
        .init(id: "notion.id", name: "Notion", registrationNames: ["Notion"], relativePaths: ["AppData/Roaming/Notion"]),
        .init(id: "md.obsidian", name: "Obsidian", registrationNames: ["Obsidian"], relativePaths: ["AppData/Roaming/obsidian"]),
        .init(id: "com.github.GitHubClient", name: "GitHub Desktop", registrationNames: ["GitHub Desktop"], relativePaths: ["AppData/Roaming/GitHub Desktop"]),
        .init(id: "com.insomnia.app", name: "Insomnia", registrationNames: ["Insomnia"], relativePaths: ["AppData/Roaming/Insomnia"]),
        .init(id: "com.postmanlabs.mac", name: "Postman", registrationNames: ["Postman"], relativePaths: ["AppData/Roaming/Postman"]),
        .init(id: "com.todesktop.230313mzl4w4u92", name: "Cursor", registrationNames: ["Cursor", "Cursor (User)"], relativePaths: ["AppData/Roaming/Cursor"])
    ]
    public func registrations(in catalog: RegisteredApplicationCatalog) -> [RegisteredApplication] {
        catalog.items.filter { application in
            let name=application.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Firefox localizes the architecture/locale suffix in its label.
            return registrationNames.contains { $0.lowercased() == name } ||
                (id == "org.mozilla.firefox" && name.range(of: "^mozilla firefox \\(x(?:64|86) [a-z]{2,3}(?:-[a-z0-9]+)*\\)$", options: .regularExpression) != nil)
        }.sorted { $0.id < $1.id }
    }
    public func paths(homeDirectory: URL) -> [String] {
        var home=homeDirectory.path.replacingOccurrences(of: "\\", with: "/")
        if home.hasPrefix("/"), home.dropFirst().range(of: "^[A-Za-z]:/", options: .regularExpression) != nil { home.removeFirst() }
        while home.hasSuffix("/") { home.removeLast() }
        return relativePaths.map { home + "/" + $0 }
    }
}

/// Only a dedicated application-data engine receives this access. Normal cache,
/// workspace and storage engines cannot use it to expand their AppData scope.
public struct WindowsApplicationDataAccess: Sendable {
    private let targets: Set<String>
    private let parents: Set<String>
    public init(homeDirectory: URL) throws {
        let paths=WindowsApplicationDataOwner.all.flatMap { $0.paths(homeDirectory: homeDirectory) }
        let normalized=paths.compactMap(WindowsCacheAccess.comparisonPath)
        guard normalized.count == paths.count else { throw ShouError("invalid_argument", "Application data home is invalid.") }
        targets=Set(normalized)
        parents=Set(normalized.map { String($0[..<$0.lastIndex(of: "/")!]) })
    }
    public func permitsTarget(_ path: String) -> Bool { WindowsCacheAccess.comparisonPath(path).map(targets.contains) ?? false }
    public func permitsParent(_ path: String) -> Bool { WindowsCacheAccess.comparisonPath(path).map(parents.contains) ?? false }
}

public struct WindowsApplicationDataPresence: Sendable {
    public let catalog: RegisteredApplicationCatalog
    public let runningOwnerIds: Set<String>
    public init(catalog: RegisteredApplicationCatalog, runningOwnerIds: Set<String>) { self.catalog=catalog; self.runningOwnerIds=runningOwnerIds }
}
public protocol WindowsApplicationDataChecking: Sendable {
    func read() throws -> WindowsApplicationDataPresence
}
public struct WindowsApplicationDataOrigin: Codable, Sendable, Equatable {
    public let ownerId: String
    public let parentPath: String
    public let parentIdentity: FileEntry
}
public struct WindowsApplicationDataComponent: Codable, Sendable, Identifiable {
    public let id: String
    public let ownerId: String
    public let name: String
    public let path: String
    public let registered: Bool
    public let registrationDigest: String
    public let origin: WindowsApplicationDataOrigin?
    public let manifest: [FileEntry]
    public let allocatedBytesEstimate: Int64
    public let reasons: [String]
    public var eligible: Bool { reasons.isEmpty && origin != nil && !manifest.isEmpty }
}
public struct WindowsApplicationDataReview: Codable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let configurationDigest: String
    public let leftoversOnly: Bool
    public let components: [WindowsApplicationDataComponent]
    public let limitations: [String]
    public let budget: ScanBudget
}
public struct WindowsApplicationDataPlan: Codable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let expiresAt: Date
    public let configurationDigest: String
    public let leftoversOnly: Bool
    public let components: [WindowsApplicationDataComponent]
    public let includesUserData: Bool
    public let budget: ScanBudget
    public var state: String
    public var executionId: String?
    public var digest: String
    public func calculatedDigest() throws -> String {
        var copy=self;copy.digest="";copy.state="ready";copy.executionId=nil;return try Digest.of(copy)
    }
}

extension ShouEngine {
    public func reviewWindowsApplicationData(presence: any WindowsApplicationDataChecking, leftoversOnly: Bool = true,
        budget: ScanBudget = .init(), progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> WindowsApplicationDataReview {
        guard filesystem.platform == "windows" else { throw ShouError("unsupported_platform", "Windows application data requires Windows.") }
        try budget.validate()
        let config=try configuration(), facts=try presence.read()
        try validateWindowsDataPresence(facts)
        var components=[WindowsApplicationDataComponent](), remaining=budget.maxEntries
        let deadline=ContinuousClock.now.advanced(by: .seconds(budget.maxSeconds))
        for owner in WindowsApplicationDataOwner.all {
            let registrations=owner.registrations(in: facts.catalog)
            if leftoversOnly && !registrations.isEmpty { continue }
            for path in owner.paths(homeDirectory: homeDirectory) {
                try Task.checkCancellation()
                if case .missing=filesystem.targetAvailability(path) { continue }
                var reasons=[String](), manifest=[FileEntry](), origin: WindowsApplicationDataOrigin?, bytes: Int64=0
                if facts.runningOwnerIds.contains(owner.id) { reasons.append("application_running") }
                if registrations.contains(where: \.systemComponent) { reasons.append("system_application") }
                progress(ScanProgress(stage: "scanning", entryCount: budget.maxEntries-remaining, currentPath: path))
                do {
                    let duration=ContinuousClock.now.duration(to: deadline).components
                    let seconds=Double(duration.seconds)+Double(duration.attoseconds)/1e18
                    guard remaining>0, seconds>=1 else { throw ShouError("resource_limit", "Application data scan budget reached.") }
                    let parent=String(path[..<path.lastIndex(of: "/")!]), identity=try filesystem.rootIdentity(parent)
                    let tree=try filesystem.inspectTarget(path, budget: .init(maxEntries: remaining,maxSeconds: min(seconds,600),maxDepth: budget.maxDepth),cancelled: { Task.isCancelled })
                    manifest=tree.entries;remaining-=manifest.count
                    if !tree.complete { reasons.append("incomplete_scan") }
                    if !windowsDataManifestSafe(manifest,parent: identity) { reasons.append("protected_content") }
                    if uninstallExcluded(target: path,manifest: manifest,configuration: config,caseSensitive: false) { reasons.append("excluded") }
                    var measured=Set<String>()
                    for entry in manifest where measured.insert(entry.objectIdentityKey).inserted {
                        let value=bytes.addingReportingOverflow(max(0,entry.allocatedBytes))
                        guard !value.overflow else { throw ShouError("resource_limit", "Application data size exceeds its limit.") };bytes=value.partialValue
                    }
                    origin = .init(ownerId: owner.id,parentPath: parent,parentIdentity: identity)
                } catch {
                    try Task.checkCancellation();reasons.append((error as? ShouError)?.code ?? "io_error")
                }
                components.append(.init(id: Digest.sha256(Data((owner.id+"\0"+path.lowercased()).utf8)),ownerId: owner.id,name: owner.name,path: path,
                    registered: !registrations.isEmpty,registrationDigest: try Digest.of(registrations),origin: origin,manifest: manifest,allocatedBytesEstimate: bytes,reasons: Array(Set(reasons)).sorted()))
            }
        }
        let review=WindowsApplicationDataReview(id: Codec.id("appdatareview"),createdAt: now(),configurationDigest: try Digest.of(config),leftoversOnly: leftoversOnly,
            components: components,limitations: ["maintained_default_user_data_paths_only", "custom_portable_and_other_account_installations_not_proven_absent", "msix_and_undeclared_applications_not_covered", "all_components_contain_personal_data", "permanent_removal_has_no_restore"],budget: budget)
        try store.write("windows-app-data-reviews",id: review.id,data: Codec.encode(review));return review
    }
    public func createWindowsApplicationDataPlan(reviewId: String, componentIds: [String], includeUserData: Bool) throws -> WindowsApplicationDataPlan {
        let lease=try store.lock();defer { lease.release() }
        let review: WindowsApplicationDataReview=try windowsDataRecord("windows-app-data-reviews",id: reviewId)
        let age=now().timeIntervalSince1970-review.createdAt.timeIntervalSince1970
        let selected=review.components.filter { componentIds.contains($0.id) }
        guard includeUserData, review.id==reviewId, age>=0, age<900, (1...32).contains(componentIds.count),
              Set(componentIds).count==componentIds.count, selected.count==componentIds.count, selected.allSatisfy(\.eligible),
              review.configurationDigest == (try Digest.of(configuration())) else { throw ShouError("confirmation_required", "Review eligible application data and separately consent to personal data removal.") }
        let createdAt=now()
        var plan=WindowsApplicationDataPlan(id: Codec.id("appdataplan"),createdAt: createdAt,expiresAt: createdAt.addingTimeInterval(120),configurationDigest: review.configurationDigest,
            leftoversOnly: review.leftoversOnly,components: selected.sorted { $0.path < $1.path },includesUserData: true,budget: review.budget,state: "ready",digest: "")
        plan.digest=try plan.calculatedDigest();try store.write("windows-app-data-plans",id: plan.id,data: Codec.encode(plan));return plan
    }
    public func windowsApplicationDataPlan(_ id: String) throws -> WindowsApplicationDataPlan {
        let plan: WindowsApplicationDataPlan=try windowsDataRecord("windows-app-data-plans",id: id)
        guard plan.id==id,plan.includesUserData,(1...32).contains(plan.components.count),Set(plan.components.map(\.id)).count==plan.components.count,
              Set(plan.components.map { $0.path.lowercased() }).count==plan.components.count,plan.expiresAt>plan.createdAt,
              plan.expiresAt.timeIntervalSince(plan.createdAt)<=120,try plan.digest==plan.calculatedDigest() else { throw ShouError("store_corrupt", "Application data plan is invalid.") }
        return plan
    }
    public func executeWindowsApplicationData(planId: String, confirmedDigest: String, presence: any WindowsApplicationDataChecking, entryPoint: String,
        progress: @Sendable (ExecutionProgress) -> Void = { _ in }) throws -> ExecutionReceipt {
        guard filesystem.platform=="windows" else { throw ShouError("unsupported_platform", "Windows application data requires Windows.") }
        let lease=try store.lock();defer { lease.release() }
        var plan=try windowsApplicationDataPlan(planId)
        guard plan.state=="ready",plan.executionId==nil,plan.digest==confirmedDigest,plan.createdAt<=now(),plan.expiresAt>now(),
              plan.configurationDigest == (try Digest.of(configuration())) else { throw ShouError("plan_stale", "Review application data again before cleaning.") }
        let reviewed=plan
        let validate: (Int) throws -> String? = { [self] index in
            try Task.checkCancellation()
            let component=reviewed.components[index]
            let facts=try presence.read();try validateWindowsDataPresence(facts)
            guard let owner=WindowsApplicationDataOwner.all.first(where: { $0.id==component.ownerId }),component.eligible,
                  owner.paths(homeDirectory: homeDirectory).contains(component.path),let origin=component.origin,origin.ownerId==owner.id,
                  component.id==Digest.sha256(Data((owner.id+"\0"+component.path.lowercased()).utf8)),
                  origin.parentPath==String(component.path[..<component.path.lastIndex(of: "/")!]),
                  !facts.runningOwnerIds.contains(owner.id),reviewed.includesUserData,reviewed.expiresAt>now(),
                  reviewed.configurationDigest == (try Digest.of(configuration())),
                  try filesystem.rootIdentity(origin.parentPath).sameObject(as: origin.parentIdentity) else { throw ShouError("ownership_unverified", "Application data owner, activity or scope changed.") }
            let registered=owner.registrations(in: facts.catalog)
            guard !registered.contains(where: \.systemComponent),component.registered == !registered.isEmpty,
                  (!reviewed.leftoversOnly || registered.isEmpty),try Digest.of(registered)==component.registrationDigest else { throw ShouError("plan_stale", "Application registration changed after review.") }
            let tree=try filesystem.inspectTarget(component.path,budget: reviewed.budget,cancelled: { Task.isCancelled })
            guard tree.complete,tree.entries==component.manifest,windowsDataManifestSafe(tree.entries,parent: origin.parentIdentity),
                  !uninstallExcluded(target: component.path,manifest: tree.entries,configuration: try configuration(),caseSensitive: false) else { throw ShouError("plan_stale", "Application data changed after review.") }
            return nil
        }
        for index in plan.components.indices { _=try validate(index) }
        let first=plan.components[0].origin!
        let workspace=Workspace(id: plan.id,rootRef: "windows-application-data",path: first.parentPath,identity: first.parentIdentity,exclusions: [],addedAt: plan.createdAt)
        let items=plan.components.map { component in
            var item=ItemReceipt(id: component.id,originalPath: component.path,relativePath: String(component.path.split(separator: "/").last!),trashPath: nil,
                manifest: component.manifest,state: "pending",allocatedBytesEstimate: component.allocatedBytesEstimate,error: nil)
            item.windowsApplicationDataOrigin=component.origin;return item
        }
        let receipt=try PermanentExecution.run(planId: plan.id,workspace: workspace,items: items,entryPoint: entryPoint,store: store,filesystem: filesystem,now: now(),
            operation: "windows_application_data_cleanup",progress: progress,didBegin: { receipt in
                var started=reviewed;started.state="executing";started.executionId=receipt.id
                try self.store.write("windows-app-data-plans",id: started.id,data: Codec.encode(started))
            },validateItem: { index,_ in try validate(index) })
        plan.state=receipt.state;plan.executionId=receipt.id
        try store.write("windows-app-data-plans",id: plan.id,data: Codec.encode(plan));return receipt
    }
    private func validateWindowsDataPresence(_ facts: WindowsApplicationDataPresence) throws {
        let expected: Set<String>=["windows.user_uninstall64","windows.user_uninstall32","windows.machine_uninstall64","windows.machine_uninstall32","windows.user_packages"]
        guard facts.catalog.status=="complete",facts.catalog.scope=="windows_registered_applications",facts.catalog.sources.count==expected.count,
              Set(facts.catalog.sources.map { $0.source.id })==expected,facts.catalog.sources.allSatisfy({ ["complete","missing"].contains($0.status) }) else {
            throw ShouError("application_evidence_unavailable", "Application registrations are incomplete; absence cannot be established.")
        }
    }
    private func windowsDataManifestSafe(_ entries: [FileEntry],parent: FileEntry) -> Bool {
        entries.first(where: { $0.path=="." })?.kind=="directory" && parent.windowsIdentity != nil && !entries.isEmpty &&
            entries.allSatisfy { $0.windowsIdentity != nil && $0.hasSameOwner(as: parent) && ["file","directory"].contains($0.kind) && ($0.kind != "file" || $0.links==1) }
    }
    private func windowsDataRecord<T: Decodable>(_ collection: String,id: String) throws -> T {
        guard let data=try store.read(collection,id: id) else { throw ShouError("invalid_argument", "Unknown application data review or plan.") }
        return try Codec.decode(T.self,from: data)
    }
}
