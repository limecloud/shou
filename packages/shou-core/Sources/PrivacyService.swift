import Foundation

public enum PrivacySourcePolicy {
    public static let chromiumRoots: [(String, String, String)] = [
        ("Google Chrome", "com.google.Chrome", "Library/Application Support/Google/Chrome"),
        ("Chromium", "org.chromium.Chromium", "Library/Application Support/Chromium"),
        ("Microsoft Edge", "com.microsoft.edgemac", "Library/Application Support/Microsoft Edge"),
        ("Brave", "com.brave.Browser", "Library/Application Support/BraveSoftware/Brave-Browser")
    ]
    public static func valid(_ source: PrivacySourceDefinition) -> Bool {
        guard StorageRemovalPolicy.validRelative(source.relativePath), !source.profile.isEmpty,
              !source.profile.contains("/"), !source.profile.contains("\\"), ![".", ".."].contains(source.profile),
              source.profile.rangeOfCharacter(from: .controlCharacters) == nil,
              source.platform == nil || source.platform == "macos" else { return false }
        switch source.browser {
        case .safari:
            return source.bundleIdentifier == "com.apple.Safari" && source.relativePath == "Library/Safari/History.db" && source.kind == .history
        case .firefox:
            let suffix=source.kind == .history ? "places.sqlite" : "cookies.sqlite"
            let root="Library/Application Support/Firefox/Profiles"
            return [.history, .cookies].contains(source.kind) && source.bundleIdentifier == "org.mozilla.firefox" && source.relativePath == root + "/\(source.profile)/\(suffix)"
        case .chromium:
            guard let root=chromiumRoots.first(where: { $0.1 == source.bundleIdentifier }), source.profile == "Default" || source.profile.range(of: "^Profile [0-9]+$", options: .regularExpression) != nil else { return false }
            let prefix=root.2 + "/" + source.profile + "/"
            return source.kind == .history ? source.relativePath == prefix + "History" : source.kind == .cookies && [prefix + "Cookies", prefix + "Network/Cookies"].contains(source.relativePath)
        }
    }
}

/// Privacy has its own explicit scope and receipts, while sharing engine storage and leases.
public actor PrivacyService {
    private let store: any RecordStore
    private let filesystem: any PlatformFileSystem
    private let activity: any ApplicationActivityChecking
    private let catalog: any PrivacySourceDiscovering
    private let home: URL
    private let now: @Sendable () -> Date
    public init(store: any RecordStore, filesystem: any PlatformFileSystem, activity: any ApplicationActivityChecking, sources: any PrivacySourceDiscovering, home: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store=store; self.filesystem=filesystem; self.activity=activity; self.catalog=sources; self.home=home; self.now=now
    }
    public func scan(range: PrivacyTimeRange = .lastHour, progress: @Sendable (ExecutionProgress) -> Void = { _ in }) throws -> PrivacyScan {
        let lease=try store.lock(); defer { lease.release() }
        try cancelled()
        let date=now(), config=try configuration(), homeIdentity=try filesystem.analysisRootIdentity(home.path)
        progress(ExecutionProgress(stage: "privacy-scanning", processedCount: 0, itemCount: 0))
        let discovery=try catalog.discoverWithCoverage(home: home)
        let definitions=discovery.sources
        guard definitions.count <= 512 else { throw ShouError("privacy_source_limit", "Too many browser sources; no privacy scan was saved.") }
        let identifiers=Set(definitions.filter { !$0.unsupported }.map(\.bundleIdentifier))
        let running: Set<String>?
        do { running=try activity.runningBundleIdentifiers(in: identifiers) } catch { running=nil }
        var sources=[PrivacySource]()
        for definition in definitions {
            try cancelled()
            progress(ExecutionProgress(stage: "privacy-scanning", processedCount: sources.count, itemCount: definitions.count, path: definition.browserName + " · " + definition.profile))
            var source=PrivacySource(id: Codec.id("privacy-source"), definition: definition, status: .unavailable, recordCount: nil, reason: nil, evidence: [])
            if definition.unsupported {
                source.status = .unsupported; source.reason="privacy_source_unsupported"
            } else if !PrivacySourcePolicy.valid(definition) {
                source.reason="privacy_source_out_of_scope"
            } else if running == nil {
                source.reason="application_activity_unavailable"
            } else if running!.contains(definition.bundleIdentifier) {
                source.status = .browserRunning; source.reason="application_running"
            } else {
                do {
                    try protected(definition, configuration: config)
                    let access=try catalog.acquire(source: definition, home: home, writable: false)
                    defer { access.release() }
                    let evidence=try catalog.evidence(source: definition, home: home, writable: false)
                    let database=try PrivacyDatabase(path: absolute(definition), source: definition, start: range.start(at: date), end: date, writable: false)
                    defer { database.close() }
                    let count=try database.count()
                    database.close()
                    guard Self.matches(try catalog.evidence(source: definition, home: home, writable: false), evidence) else { throw ShouError("plan_stale", "Privacy database changed during scanning.") }
                    source.status=count == 0 ? .empty : .ready; source.recordCount=count; source.evidence=evidence
                } catch let error as ShouError {
                    if error.code == "cancelled" { throw error }
                    source.reason=error.code
                    source.status=error.code == "privacy_schema_unsupported" ? .schemaUnsupported : error.code == "permission_denied" ? .permissionRequired : .unavailable
                } catch { source.reason="privacy_database_unavailable" }
            }
            sources.append(source)
            progress(ExecutionProgress(stage: "privacy-scanning", processedCount: sources.count, itemCount: definitions.count, path: definition.browserName + " · " + definition.profile))
        }
        let issues=Array(Set(discovery.issues + (running == nil ? ["application_activity_unavailable"] : []))).sorted()
        let result=PrivacyScan(id: Codec.id("privacy-scan"), createdAt: date, expiresAt: date.addingTimeInterval(900), range: range, rangeStart: range.start(at: date), rangeEnd: date, configurationDigest: try Digest.of(config), homeIdentity: homeIdentity, sources: sources, issues: issues)
        try save(result, "privacy-scans", result.id); return result
    }
    public func scan(id: String) throws -> PrivacyScan { try load(PrivacyScan.self, "privacy-scans", id) }
    public func plan(id: String) throws -> PrivacyPlan {
        let value=try load(PrivacyPlan.self, "privacy-plans", id)
        guard value.digest == (try value.calculatedDigest()) else { throw ShouError("store_corrupt", "Privacy plan integrity verification failed.") }
        return value
    }
    public func preparePlan(scanId: String, sourceIDs: [String], acknowledgeSignOut: Bool = false) throws -> PrivacyPlan {
        let lease=try store.lock(); defer { lease.release() }
        let scan=try scan(id: scanId), selected=Set(sourceIDs)
        guard !selected.isEmpty, selected.count == sourceIDs.count, selected.isSubset(of: Set(scan.sources.map(\.id))) else { throw ShouError("invalid_argument", "Select exact privacy source IDs from the current scan.") }
        let sources=scan.sources.filter { selected.contains($0.id) }
        guard sources.allSatisfy(\.eligible) else { throw ShouError("privacy_source_unavailable", "Only ready privacy sources can be selected.") }
        guard acknowledgeSignOut || !sources.contains(where: \.requiresSignOutConsent) else { throw ShouError("privacy_sign_out_consent_required", "Cookie removal can sign you out; explicit consent is required.") }
        var result=PrivacyPlan(id: Codec.id("privacy-plan"), scanId: scan.id, createdAt: now(), expiresAt: min(scan.expiresAt, now().addingTimeInterval(300)), range: scan.range, rangeStart: scan.rangeStart, rangeEnd: scan.rangeEnd, configurationDigest: scan.configurationDigest, homeIdentity: scan.homeIdentity, sources: sources, signOutAcknowledged: acknowledgeSignOut)
        try preflight(result)
        result.digest=try result.calculatedDigest(); try save(result, "privacy-plans", result.id); return result
    }
    public func execute(planId: String, digest: String, consent: PrivacyConsent, progress: @Sendable (ExecutionProgress) -> Void = { _ in }) throws -> PrivacyReceipt {
        let lease=try store.lock(); defer { lease.release() }
        var plan=try plan(id: planId)
        guard plan.state == "ready", plan.digest == digest else { throw ShouError("plan_stale", "The privacy plan is stale or was already used.") }
        guard consent.irreversibleDeletion else { throw ShouError("confirmation_required", "Privacy deletion is permanent; explicit confirmation is required.") }
        guard !plan.requiresSignOutConsent || (plan.signOutAcknowledged && consent.signOut) else { throw ShouError("privacy_sign_out_consent_required", "Cookie removal can sign you out; explicit consent is required.") }
        progress(ExecutionProgress(stage: "preflight", processedCount: 0, itemCount: plan.sources.count))
        try preflight(plan, progress: progress)
        var receipt=PrivacyReceipt(id: Codec.id("privacy-execution"), planId: plan.id, createdAt: now(), range: plan.range, rangeStart: plan.rangeStart, rangeEnd: plan.rangeEnd, state: "executing", items: plan.sources.map { PrivacyItemResult(sourceId: $0.id, state: "pending", removedRecords: 0, reason: nil) })
        // Persist intent before the first database transaction. Interrupted results are never retried.
        plan.state="executing"; try save(plan, "privacy-plans", plan.id); try save(receipt, "privacy-history", receipt.id)
        for (index, source) in plan.sources.enumerated() {
            let label=source.definition.browserName + " · " + source.definition.profile
            progress(ExecutionProgress(stage: "privacy-cleaning", processedCount: index, itemCount: plan.sources.count, path: label))
            do {
                let access=try catalog.acquire(source: source.definition, home: home, writable: true)
                defer { access.release() }
                try cancelled(); try verify(source, plan: plan)
                receipt.items[index].state="executing"; try save(receipt, "privacy-history", receipt.id)
                let database=try PrivacyDatabase(path: absolute(source.definition), source: source.definition, start: plan.rangeStart, end: plan.rangeEnd, writable: true)
                defer { database.close() }
                let count=try database.remove(expectedCount: source.recordCount ?? 0) {
                    try self.verify(source, plan: plan, count: false)
                }
                receipt.items[index].state="completed"; receipt.items[index].removedRecords=count
            } catch {
                receipt.items[index].state="failed"
                receipt.items[index].reason=(error as? ShouError)?.code ?? "privacy_database_unavailable"
                if Task.isCancelled {
                    for remaining in receipt.items.indices where remaining > index { receipt.items[remaining].state="cancelled" }
                    break
                }
            }
            try save(receipt, "privacy-history", receipt.id)
            progress(ExecutionProgress(stage: "privacy-cleaning", processedCount: index + 1, itemCount: plan.sources.count, path: label))
        }
        receipt.state=receipt.items.allSatisfy { $0.state == "completed" } ? "completed" : "partial"
        plan.state=receipt.state; try save(receipt, "privacy-history", receipt.id); try save(plan, "privacy-plans", plan.id)
        return receipt
    }
    public func history() throws -> [PrivacyReceipt] {
        try store.ids("privacy-history").map { try load(PrivacyReceipt.self, "privacy-history", $0) }.sorted { $0.createdAt > $1.createdAt }
    }
    private func preflight(_ plan: PrivacyPlan, progress: (ExecutionProgress) -> Void = { _ in }) throws {
        try cancelled()
        let currentHome=try filesystem.analysisRootIdentity(home.path)
        guard now() < plan.expiresAt, !plan.sources.isEmpty, Set(plan.sources.map(\.id)).count == plan.sources.count,
              currentHome.sameObject(as: plan.homeIdentity), currentHome.hasSameOwner(as: plan.homeIdentity),
              try Digest.of(configuration()) == plan.configurationDigest else { throw ShouError("plan_stale", "The privacy plan expired or its protection settings changed; scan again.") }
        for source in plan.sources {
            progress(ExecutionProgress(stage: "preflight", processedCount: 0, itemCount: plan.sources.count, path: source.definition.browserName + " · " + source.definition.profile))
            try verify(source, plan: plan)
        }
    }
    private func verify(_ source: PrivacySource, plan: PrivacyPlan, count: Bool = true) throws {
        try cancelled()
        let currentHome=try filesystem.analysisRootIdentity(home.path)
        guard currentHome.sameObject(as: plan.homeIdentity), currentHome.hasSameOwner(as: plan.homeIdentity) else { throw ShouError("plan_stale", "The privacy home directory changed; scan again.") }
        guard source.eligible, !source.definition.unsupported, PrivacySourcePolicy.valid(source.definition) else { throw ShouError("privacy_source_unavailable", "The privacy source is outside supported scope.") }
        guard try activity.runningBundleIdentifiers(in: [source.definition.bundleIdentifier]).isEmpty else { throw ShouError("application_running", "Close the browser before privacy cleaning.") }
        let config=try configuration()
        guard try Digest.of(config) == plan.configurationDigest else { throw ShouError("plan_stale", "Privacy protection settings changed; scan again.") }
        try protected(source.definition, configuration: config)
        let access=try catalog.acquire(source: source.definition, home: home, writable: true)
        defer { access.release() }
        let evidence=try catalog.evidence(source: source.definition, home: home, writable: true)
        let comparable=count ? evidence : evidence.filter { item in
            // BEGIN IMMEDIATE may create an empty WAL before any record mutation.
            !(item.path == "database-wal" && item.logicalBytes <= 32 && !source.evidence.contains { $0.path == item.path })
        }
        guard Self.matches(comparable, source.evidence) else { throw ShouError("plan_stale", "The privacy database changed; scan again.") }
        if count {
            let database=try PrivacyDatabase(path: absolute(source.definition), source: source.definition, start: plan.rangeStart, end: plan.rangeEnd, writable: false)
            defer { database.close() }
            guard try database.count() == source.recordCount else { throw ShouError("plan_stale", "Privacy record counts changed; scan again.") }
        }
    }
    private static func matches(_ current: [FileEntry], _ expected: [FileEntry]) -> Bool {
        guard current.count == expected.count else { return false }
        for (a, b) in zip(current, expected) {
            guard a.path == b.path else { return false }
            if a.kind == "directory" {
                guard a.sameObject(as: b), a.hasSameOwner(as: b), a.mode == b.mode else { return false }
            } else if a != b { return false }
        }
        return true
    }
    private func protected(_ source: PrivacySourceDefinition, configuration: Configuration) throws {
        let path=absolute(source)
        func key(_ path: String) -> String {
            filesystem.caseSensitivePaths ? path : path.replacingOccurrences(of: "\\", with: "/").lowercased()
        }
        let compared=key(path)
        guard !store.protectedPaths.contains(where: { compared == key($0) || compared.hasPrefix(key($0) + "/") || key($0).hasPrefix(compared + "/") }) else { throw ShouError("permission_denied", "The privacy source overlaps protected application data.") }
        let paths=[source.relativePath, source.relativePath + "-wal", source.relativePath + "-shm", source.relativePath + "-journal"]
        for relative in paths {
            let parts=relative.split(separator: "/").map(String.init)
            let ancestors=(1...parts.count).map { parts.prefix($0).joined(separator: "/") }
            if (configuration.globalExclusions ?? []).contains(where: { pattern in ancestors.contains { PathPattern.matches(pattern, $0, caseSensitive: false) } }) { throw ShouError("permission_denied", "The privacy source matches a protected exclusion.") }
            let absolute=home.appendingPathComponent(relative).path
            for workspace in configuration.workspaces where key(absolute).hasPrefix(key(workspace.path) + "/") {
                let scoped=String(absolute.dropFirst(workspace.path.count + 1)), pieces=scoped.split(separator: "/").map(String.init)
                if workspace.exclusions.contains(where: { pattern in (1...pieces.count).contains { PathPattern.matches(pattern, pieces.prefix($0).joined(separator: "/"), caseSensitive: false) } }) { throw ShouError("permission_denied", "The privacy source matches a workspace exclusion.") }
            }
        }
    }
    private func configuration() throws -> Configuration {
        guard let data=try store.read("configuration", id: "current") else { var empty=Configuration(); empty.revision="unconfigured"; return empty }
        do {
            let config=try Codec.decode(Configuration.self, from: data)
            guard [1,2].contains(config.version) else { throw ShouError("store_corrupt", "Unsupported protection configuration.") }
            for pattern in (config.globalExclusions ?? []) + config.workspaces.flatMap(\.exclusions) { try PathPattern.validate(pattern) }
            return config
        } catch { throw ShouError("store_corrupt", "Privacy protection settings could not be verified.") }
    }
    private func absolute(_ source: PrivacySourceDefinition) -> String { home.appendingPathComponent(source.relativePath).path }
    private func cancelled() throws { if Task.isCancelled { throw ShouError("cancelled", "Privacy operation cancelled.") } }
    private func save<T: Encodable>(_ value: T, _ collection: String, _ id: String) throws { try store.write(collection, id: id, data: Codec.encode(value)) }
    private func load<T: Decodable>(_ type: T.Type, _ collection: String, _ id: String) throws -> T {
        guard let data=try store.read(collection, id: id) else { throw ShouError("invalid_argument", "Privacy record does not exist.") }
        do { return try Codec.decode(type, from: data) } catch { throw ShouError("store_corrupt", "Privacy metadata could not be decoded.") }
    }
}
