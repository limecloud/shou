import Foundation

/// Callers hold the mutation lease and reproduce their own policy before entry.
/// The journal and system mutation boundary are shared by all Trash workflows.
enum TrashExecution {
    static func run(planId: String, workspace: Workspace, items: [ItemReceipt], entryPoint: String,
                    store: any RecordStore, filesystem: any PlatformFileSystem, now: Date, operation: String? = nil,
                    progress: (ExecutionProgress) -> Void,
                    didBegin: (ExecutionReceipt) throws -> Void,
                    validateItem: (Int) throws -> String?) throws -> ExecutionReceipt {
        if Task.isCancelled { throw ShouError("cancelled", "Cleanup stopped before any files were moved.") }
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
            progress(ExecutionProgress(stage: "moving", processedCount: index, itemCount: items.count, path: path))
            do {
                let skip=try validateItem(index)
                if Task.isCancelled { receipt.state="cancelled"; break }
                if let skip {
                    receipt.items[index].state="skipped"; receipt.items[index].error=skip
                    try save()
                    progress(ExecutionProgress(stage: "moving", processedCount: index + 1, itemCount: items.count, path: path))
                    continue
                }
            } catch {
                if Task.isCancelled { receipt.state="cancelled"; break }
                receipt.items[index].state="failed"; receipt.items[index].error=diagnostic(error)
                try save()
                break
            }
            // A lost result write must leave a durable started-item intent.
            receipt.items[index].state="moving"
            try save()
            do {
                let moved=try filesystem.moveToTrash(path, expected: receipt.items[index].manifest)
                receipt.items[index].trashPath=moved.path; receipt.items[index].manifest=moved.manifest
                receipt.items[index].state=moved.verified ? "trashed" : "unknown"
                if !moved.verified { receipt.items[index].error="Moved identity or contents could not be verified." }
            } catch {
                receipt.items[index].state=(error as? ShouError)?.code == "trash_outcome_unknown" ? "unknown" : "failed"
                if let observed=(error as? ShouError)?.details["resulting_path"], !observed.isEmpty {
                    receipt.items[index].trashPath=observed
                }
                receipt.items[index].error=diagnostic(error)
            }
            try save()
            progress(ExecutionProgress(stage: "moving", processedCount: index + 1, itemCount: items.count, path: path))
            if receipt.items[index].state != "trashed" { break }
        }
        if receipt.state != "cancelled" { receipt.state=receipt.items.allSatisfy { $0.state == "trashed" } ? "completed" : "partial" }
        progress(ExecutionProgress(stage: "finalizing", processedCount: receipt.items.filter { !["pending", "moving"].contains($0.state) }.count, itemCount: items.count, path: workspace.path))
        receipt.volumeAvailableAfter=filesystem.availableBytes(workspace.path)
        try save()
        return receipt
    }

    static func diagnostic(_ error: Error) -> String {
        let reasons=(error as? ShouError)?.details["reasons"]?.split(separator: ",").map(String.init) ?? []
        let observed=(error as? ShouError)?.details["resulting_path"].flatMap { $0.isEmpty ? nil : "Observed result: " + $0 }
        return ([error.localizedDescription] + reasons + (observed.map { [$0] } ?? [])).joined(separator: "\n")
    }
}
