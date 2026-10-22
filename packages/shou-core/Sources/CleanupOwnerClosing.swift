import Foundation

public struct CleanupOwnerProcess: Codable, Sendable, Equatable {
    public let pid: UInt32
    public let created: UInt64
    public let session: UInt32
    public let ownerSid: String
    public let executablePath: String
    public let executableIdentity: FileEntry
    public init(pid: UInt32, created: UInt64, session: UInt32, ownerSid: String, executablePath: String, executableIdentity: FileEntry) {
        self.pid=pid; self.created=created; self.session=session; self.ownerSid=ownerSid
        self.executablePath=executablePath; self.executableIdentity=executableIdentity
    }
}
public struct CleanupOwnerTarget: Codable, Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let processes: [CleanupOwnerProcess]
    public init(identifier: String, name: String, processes: [CleanupOwnerProcess]) {
        self.identifier=identifier; self.name=name; self.processes=processes
    }
}
public protocol CleanupOwnerClosing: Sendable {
    func inspect(identifiers: Set<String>) throws -> [CleanupOwnerTarget]
    func requestClose(_ target: CleanupOwnerTarget) throws
    func isRunning(identifier: String) throws -> Bool
}
public struct CleanupOwnerCloseReview: Codable, Sendable {
    public let scanIds: [String]
    public let configurationDigest: String
    public let createdAt: Date
    public let expiresAt: Date
    public let targets: [CleanupOwnerTarget]
    public let affectedWorkspaceIds: [String]
    public let affectedPaths: [String]
    public var digest: String
    public func calculatedDigest() throws -> String { var copy=self; copy.digest=""; return try Digest.of(copy) }
}
public struct CleanupOwnerCloseReceipt: Codable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let reviewDigest: String
    public var state: String
    public var items: [ApplicationCloseResult]
}

extension ShouEngine {
    /// Closing authorizes normal window requests only. Fresh cleanup evidence
    /// and a separate deletion review are still required afterwards.
    public func cleanupOwnerCloseReview(scanIds: [String], controller: any CleanupOwnerClosing) throws -> CleanupOwnerCloseReview {
        let lease=try store.lock(); defer { lease.release() }
        let scope=try cleanupOwnerCloseScope(scanIds)
        let targets=try controller.inspect(identifiers: scope.identifiers)
        guard targets.count <= 32, Set(targets.map(\.identifier)).count == targets.count,
              Set(targets.map(\.identifier)).isSubset(of: scope.identifiers),
              targets.allSatisfy({ !$0.processes.isEmpty && $0.processes.count <= 256 && Set($0.processes.map(\.pid)).count == $0.processes.count &&
                  $0.processes.allSatisfy { $0.pid > 0 && $0.created > 0 && $0.session > 0 && !$0.ownerSid.isEmpty && !$0.executablePath.isEmpty && $0.executableIdentity.kind == "file" && $0.executableIdentity.windowsIdentity != nil }
              }) else {
            throw ShouError("application_activity_unavailable", "Application process evidence was incomplete or exceeded its bounds.")
        }
        let date=now()
        var review=CleanupOwnerCloseReview(scanIds: scanIds, configurationDigest: try Digest.of(configuration()), createdAt: date,
            expiresAt: date.addingTimeInterval(120), targets: targets, affectedWorkspaceIds: scope.workspaces,
            affectedPaths: scope.paths, digest: "")
        review.digest=try review.calculatedDigest()
        return review
    }

    public func closeCleanupOwners(review: CleanupOwnerCloseReview, confirmedDigest: String, controller: any CleanupOwnerClosing,
                                   timeoutSeconds: Double = 10) async throws -> CleanupOwnerCloseReceipt {
        guard review.digest == confirmedDigest, try review.calculatedDigest() == review.digest,
              review.expiresAt > now(), timeoutSeconds.isFinite, (0...30).contains(timeoutSeconds), !review.targets.isEmpty else {
            throw ShouError("confirmation_required", "Application-close review expired or changed.")
        }
        // Revalidate the entire selection before any normal-close request.
        let intent=try beginCleanupOwnerClose(review, controller: controller)
        var receipt=intent
        for (index, target) in review.targets.enumerated() {
            if Task.isCancelled { break }
            do {
                try controller.requestClose(target)
                let deadline=ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
                var running=try controller.isRunning(identifier: target.identifier)
                while running && ContinuousClock.now < deadline && !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(100))
                    running=try controller.isRunning(identifier: target.identifier)
                }
                receipt.items[index] = .init(applicationId: target.identifier, name: target.name, state: running ? "still_running" : "closed")
            } catch {
                receipt.items[index] = .init(applicationId: target.identifier, name: target.name, state: "failed", error: (error as? ShouError)?.code ?? (Task.isCancelled ? "cancelled" : "application_activity_unavailable"))
            }
            try saveCleanupOwnerClose(receipt)
        }
        receipt.items=receipt.items.map { $0.state == "pending" ? .init(applicationId: $0.applicationId, name: $0.name, state: "cancelled") : $0 }
        receipt.state=receipt.items.allSatisfy { $0.state == "closed" } ? "completed" : "partial"
        try saveCleanupOwnerClose(receipt)
        return receipt
    }

    private func beginCleanupOwnerClose(_ review: CleanupOwnerCloseReview, controller: any CleanupOwnerClosing) throws -> CleanupOwnerCloseReceipt {
        let lease=try store.lock(); defer { lease.release() }
        if Task.isCancelled { throw ShouError("cancelled", "Application close cancelled.") }
        let scope=try cleanupOwnerCloseScope(review.scanIds)
        guard try Digest.of(configuration()) == review.configurationDigest,
              scope.workspaces == review.affectedWorkspaceIds, scope.paths == review.affectedPaths,
              Set(review.targets.map(\.identifier)).isSubset(of: scope.identifiers),
              try controller.inspect(identifiers: Set(review.targets.map(\.identifier))) == review.targets else {
            throw ShouError("plan_stale", "Applications or cleanup settings changed; review again before closing.")
        }
        // Digest-keyed intent consumes this review even if the process is
        // interrupted after sending a close message. No automatic replay.
        let recordId="close_" + review.digest.dropFirst("sha256:".count)
        guard try store.read("cleanup-close-history", id: recordId) == nil else { throw ShouError("plan_stale", "This application-close review was already used.") }
        let receipt=CleanupOwnerCloseReceipt(id: recordId, createdAt: now(), reviewDigest: review.digest, state: "executing",
            items: review.targets.map { .init(applicationId: $0.identifier, name: $0.name, state: "pending") })
        try store.write("cleanup-close-history", id: receipt.id, data: Codec.encode(receipt))
        return receipt
    }
    private func saveCleanupOwnerClose(_ receipt: CleanupOwnerCloseReceipt) throws {
        let lease=try store.lock(); defer { lease.release() }
        try store.write("cleanup-close-history", id: receipt.id, data: Codec.encode(receipt))
    }
    private func cleanupOwnerCloseScope(_ scanIds: [String]) throws -> (identifiers: Set<String>, workspaces: [String], paths: [String]) {
        guard !scanIds.isEmpty, scanIds.count <= 200, Set(scanIds).count == scanIds.count else { throw ShouError("invalid_argument", "Select distinct current cleanup scans.") }
        let snapshots=try scanIds.map { try scanSnapshot($0) }, config=try Digest.of(configuration())
        guard snapshots.allSatisfy({ !$0.previewOnly && $0.configurationDigest == config }) else { throw ShouError("plan_stale", "Cleanup settings changed; scan again.") }
        let rules=try BuiltinCatalog.templates()
        var identifiers=Set<String>(), workspaces=Set<String>(), paths=Set<String>()
        for scan in snapshots {
            let blocked=scan.candidates.filter { $0.reasons.contains("application_running") }
            let ruleIds=Set(blocked.flatMap(\.ruleIds))
            let owners=Set(rules.filter { ruleIds.contains($0.id) }.flatMap { $0.applicationBundleIdentifiers ?? [] })
            if !owners.isEmpty {
                identifiers.formUnion(owners); workspaces.insert(scan.workspace.id)
                paths.formUnion(blocked.map { StorageRemovalPolicy.absolute(root: scan.workspace.path, relative: $0.relativePath) })
            }
        }
        return (identifiers, workspaces.sorted(), paths.sorted())
    }
}
