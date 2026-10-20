import Foundation

public struct HistoryObjectObservation: Codable, Sendable {
    public let path: String?
    public let state: String
    public let issue: String?
}

public struct HistoryItemInspection: Codable, Sendable, Identifiable {
    public let id: String
    public let relativePath: String
    public let recordedState: String
    public let original: HistoryObjectObservation
    public let trash: HistoryObjectObservation
    public let followUp: FollowUpReceipt?
    public let state: String
}

public struct HistoryInspection: Codable, Sendable {
    public let executionId: String
    public let checkedAt: Date
    public let recordedState: String
    public let unfinished: Bool
    public let status: String
    public let items: [HistoryItemInspection]
}

enum HistoryInspector {
    static func inspect(_ receipt: ExecutionReceipt, followUps: [FollowUpReceipt], filesystem: any PlatformFileSystem,
                        homeDirectory: URL, budget: ScanBudget, checkedAt: Date) throws -> HistoryInspection {
        try budget.validate()
        let deadline=ContinuousClock.now.advanced(by: .seconds(budget.maxSeconds))
        var remainingEntries=budget.maxEntries
        func observe(_ path: String?, manifest: [FileEntry], permitted: Bool) throws -> HistoryObjectObservation {
            if Task.isCancelled { throw ShouError("cancelled", "History verification cancelled.") }
            guard let path else { return HistoryObjectObservation(path: nil, state: "not_recorded", issue: nil) }
            guard permitted else { return HistoryObjectObservation(path: path, state: "unavailable", issue: "unverified_location") }
            let duration=ContinuousClock.now.duration(to: deadline).components
            let seconds=Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            guard seconds >= 1, remainingEntries > 0 else { return HistoryObjectObservation(path: path, state: "unavailable", issue: "resource_limit") }
            switch filesystem.targetAvailability(path) {
            case .missing: return HistoryObjectObservation(path: path, state: "missing", issue: nil)
            case .unavailable: return HistoryObjectObservation(path: path, state: "unavailable", issue: "permission_or_type_unavailable")
            case .available: break
            }
            do {
                let tree=try filesystem.inspectStorageTarget(path, budget: ScanBudget(maxEntries: remainingEntries, maxSeconds: min(seconds, budget.maxSeconds), maxDepth: budget.maxDepth), cancelled: { Task.isCancelled })
                remainingEntries=max(0, remainingEntries - tree.entries.count)
                if Task.isCancelled { throw ShouError("cancelled", "History verification cancelled.") }
                guard tree.complete else { return HistoryObjectObservation(path: path, state: "unavailable", issue: "incomplete_manifest") }
                let matches=tree.entries.count == manifest.count && zip(tree.entries, manifest).allSatisfy { $0 == $1 || $0.matchesTrashRoot(as: $1) }
                return HistoryObjectObservation(path: path, state: matches ? "matches" : "changed", issue: matches ? nil : "manifest_changed")
            } catch let error as ShouError where error.code == "cancelled" { throw error }
            catch { return HistoryObjectObservation(path: path, state: "unavailable", issue: "inspection_failed") }
        }
        var items: [HistoryItemInspection]=[]
        for item in receipt.items {
            let origin=try ReceiptOrigins.resolve(receipt: receipt, item: item, homeDirectory: homeDirectory)
            let workspaceMatches=(try? ReceiptOrigins.identity(origin, filesystem: filesystem).sameObject(as: origin.identity)) == true
            guard item.manifest.first?.path == ".",
                  item.manifest.first?.kind == "directory" || (item.manifest.first?.kind == "file" && item.manifest.count == 1) else {
                throw ShouError("store_corrupt", "Receipt does not identify a complete workspace target.")
            }
            let original=try observe(item.originalPath, manifest: item.manifest, permitted: workspaceMatches)
            let trash=try observe(item.trashPath, manifest: item.manifest, permitted: item.trashPath.map(filesystem.isTrashLocation) ?? false)
            let followUp=followUps.filter { $0.executionId == receipt.id && $0.itemId == item.id }.max { $0.createdAt < $1.createdAt }
            let state: String
            if let followUp, followUp.state == "completed" {
                state=followUp.action == "restore" && original.state == "matches" ? "restored" :
                    followUp.action == "purge" && trash.state == "missing" ? "purged" : "needs_verification"
            } else if followUp?.state == "pending" { state="needs_verification" }
            else if item.state == "purged", original.state == "missing", item.trashPath == nil,
                    ["storage_permanent_removal", "permanent_cleanup"].contains(receipt.operation ?? "") { state="purged" }
            else if trash.state == "matches" { state=original.state == "missing" ? "verified_trash" : "restore_conflict" }
            else if original.state == "matches" { state="verified_original" }
            else if original.state == "missing" && ["missing", "not_recorded"].contains(trash.state) { state="missing" }
            else { state="needs_verification" }
            items.append(HistoryItemInspection(id: item.id, relativePath: item.relativePath, recordedState: item.state,
                original: original, trash: trash, followUp: followUp, state: state))
        }
        let unfinished=receipt.state == "executing" || receipt.items.contains { ["moving", "purging"].contains($0.state) } || items.contains { $0.followUp?.state == "pending" }
        let partial=items.contains { ["missing", "needs_verification", "restore_conflict"].contains($0.state) }
        return HistoryInspection(executionId: receipt.id, checkedAt: checkedAt, recordedState: receipt.state, unfinished: unfinished,
            status: partial ? "partial" : "complete", items: items)
    }
}
