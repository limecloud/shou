import Foundation

/// Executes a root-bound permanent cleanup plan. The caller has already held
/// the mutation lease, rechecked the current policy and verified each full
/// manifest. This loop deliberately has the same journal boundaries as the
/// Trash path, but never creates a recoverable Trash location.
enum PermanentExecution {
    static func run(planId: String, workspace: Workspace, items: [ItemReceipt], entryPoint: String,
                    store: any RecordStore, filesystem: any PlatformFileSystem, now: Date, operation: String = "permanent_cleanup",
                    progress: (ExecutionProgress) -> Void,
                    didBegin: (ExecutionReceipt) throws -> Void,
                    validateItem: (Int) throws -> String?) throws -> ExecutionReceipt {
        if Task.isCancelled { throw ShouError("cancelled", "Permanent cleanup stopped before any files were removed.") }
        var receipt=ExecutionReceipt(id: Codec.id("execution"), planId: planId, workspace: workspace,
            createdAt: now, entryPoint: entryPoint, state: "executing", items: items,
            volumeAvailableBefore: filesystem.availableBytes(workspace.path), volumeAvailableAfter: nil)
        receipt.operation=operation
        func save() throws { try store.write("history", id: receipt.id, data: Codec.encode(receipt)) }
        try save()
        try didBegin(receipt)
        for index in receipt.items.indices {
            if Task.isCancelled { receipt.state="cancelled"; break }
            let path=receipt.items[index].originalPath
            progress(ExecutionProgress(stage: "purging", processedCount: index, itemCount: items.count, path: path))
            do {
                let skip=try validateItem(index)
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
                try save()
                break
            }
            // A lost result write must leave a durable started-item intent.
            receipt.items[index].state="purging"
            try save()
            do {
                try filesystem.purge(path, expected: receipt.items[index].manifest)
                receipt.items[index].state="purged"
            } catch {
                receipt.items[index].state=["cancelled", "purge_outcome_unknown"].contains((error as? ShouError)?.code ?? "") ? "unknown" : "failed"
                receipt.items[index].error=TrashExecution.diagnostic(error)
            }
            try save()
            progress(ExecutionProgress(stage: "purging", processedCount: index + 1, itemCount: items.count, path: path))
            if receipt.items[index].state != "purged" { break }
        }
        if receipt.state != "cancelled" { receipt.state=receipt.items.allSatisfy { $0.state == "purged" } ? "completed" : "partial" }
        progress(ExecutionProgress(stage: "finalizing", processedCount: receipt.items.filter { !["pending", "purging"].contains($0.state) }.count, itemCount: items.count, path: workspace.path))
        receipt.volumeAvailableAfter=filesystem.availableBytes(workspace.path)
        try save()
        return receipt
    }
}
