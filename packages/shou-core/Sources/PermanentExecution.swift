import Foundation

/// Executes a root-bound permanent cleanup plan. The caller has already held
/// the mutation lease and frozen the selected scope. Each item's policy and
/// native manifest boundary run immediately before that item. Both removal modes
/// share the journal contract; permanent removal creates no Trash location.
enum PermanentExecution {
    static func run(planId: String, workspace: Workspace, items: [ItemReceipt], entryPoint: String,
                    store: any RecordStore, filesystem: any PlatformFileSystem, now: Date, operation: String = "permanent_cleanup",
                    progress: @Sendable (ExecutionProgress) -> Void,
                    didBegin: (ExecutionReceipt) throws -> Void,
                    validateItem: (Int, [FileEntry]) throws -> String?) throws -> ExecutionReceipt {
        if Task.isCancelled { throw ShouError("cancelled", "Permanent cleanup stopped before any files were removed.") }
        var receipt=ExecutionReceipt(id: Codec.id("execution"), planId: planId, workspace: workspace,
            createdAt: now, entryPoint: entryPoint, state: "executing", items: items,
            volumeAvailableBefore: filesystem.availableBytes(workspace.path), volumeAvailableAfter: nil)
        receipt.operation=operation
        var journal=ReceiptJournal()
        func save() throws { try journal.save(receipt, store: store) }
        try save()
        try didBegin(receipt)
        var removalContext=PermanentRemovalContext()
        for index in receipt.items.indices {
            if Task.isCancelled { receipt.state="cancelled"; break }
            let path=receipt.items[index].originalPath
            progress(ExecutionProgress(stage: "checking", processedCount: index, itemCount: items.count, path: path))
            do {
                let skip=try validateItem(index, removalContext.reconciled(receipt.items[index].manifest))
                if Task.isCancelled { receipt.state="cancelled"; break }
                if let skip {
                    receipt.items[index].state="skipped"; receipt.items[index].error=skip
                    try save()
                    progress(ExecutionProgress(stage: "purging", processedCount: index + 1, itemCount: items.count, path: path))
                    continue
                }
            } catch {
                if Task.isCancelled { receipt.state="cancelled"; break }
                receipt.items[index].state="failed"; receipt.items[index].error=TrashExecution.diagnostic(error)
                receipt.items[index].accessRequirement=(error as? ShouError)?.accessRequirement
                try save()
                if ExecutionFailurePolicy.continues(after: error) {
                    progress(ExecutionProgress(stage: "purging", processedCount: index + 1, itemCount: items.count, path: path))
                    continue
                }
                break
            }
            // A lost result write must leave a durable started-item intent.
            receipt.items[index].state="purging"
            try save()
            var continueRemoval=false
            do {
                try filesystem.purge(path, expected: receipt.items[index].manifest, context: &removalContext, progress: { completed, total, current in
                    progress(ExecutionProgress(stage: "purging", processedCount: index, itemCount: items.count, path: current,
                        currentItemProcessedCount: completed, currentItemCount: total))
                }, checking: { update in
                    let current=update.currentPath.isEmpty ? path : update.currentPath.hasPrefix("/") ? update.currentPath : path + "/" + update.currentPath
                    progress(ExecutionProgress(stage: "checking", processedCount: index, itemCount: items.count, path: current))
                })
                receipt.items[index].state="purged"
            } catch {
                continueRemoval=ExecutionFailurePolicy.continues(after: error)
                if ExecutionFailurePolicy.authorizationCancelled(error) {
                    receipt.items[index].state="skipped"; receipt.state="cancelled"
                } else {
                    receipt.items[index].state=["cancelled", "purge_outcome_unknown", "authorization_channel_lost"].contains((error as? ShouError)?.code ?? "") ? "unknown" : "failed"
                }
                receipt.items[index].error=TrashExecution.diagnostic(error)
                receipt.items[index].accessRequirement=(error as? ShouError)?.accessRequirement
            }
            try save()
            progress(ExecutionProgress(stage: "purging", processedCount: index + 1, itemCount: items.count, path: path))
            if receipt.state == "cancelled" || (receipt.items[index].state != "purged" && !continueRemoval) { break }
        }
        if receipt.state != "cancelled" { receipt.state=receipt.items.allSatisfy { $0.state == "purged" } ? "completed" : "partial" }
        progress(ExecutionProgress(stage: "finalizing", processedCount: receipt.items.filter { !["pending", "purging"].contains($0.state) }.count, itemCount: items.count, path: workspace.path))
        receipt.volumeAvailableAfter=filesystem.availableBytes(workspace.path)
        try save()
        HistorySummaries.save(receipt, store: store)
        return receipt
    }
}
