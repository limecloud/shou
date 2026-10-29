import Foundation

/// Callers hold the mutation lease and reproduce their own policy before entry.
/// The journal and system mutation boundary are shared by all Trash workflows.
enum TrashExecution {
    static func run(planId: String, workspace: Workspace, items: [ItemReceipt], entryPoint: String,
                    store: any RecordStore, filesystem: any PlatformFileSystem, now: Date, operation: String? = nil,
                    manifestSources: [String: FileManifestSource] = [:],
                    progress: (ExecutionProgress) -> Void,
                    didBegin: (ExecutionReceipt) throws -> Void,
                    validateItem: (Int) throws -> String?) throws -> ExecutionReceipt {
        if Task.isCancelled { throw ShouError("cancelled", "Cleanup stopped before any files were moved.") }
        var receipt=ExecutionReceipt(id: Codec.id("execution"), planId: planId, workspace: workspace,
            createdAt: now, entryPoint: entryPoint, state: "executing", items: items,
            volumeAvailableBefore: filesystem.availableBytes(workspace.path), volumeAvailableAfter: nil)
        receipt.operation=operation
        var journal=ReceiptJournal(sources: manifestSources)
        func save() throws { try journal.save(receipt, store: store) }
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
                receipt.items[index].accessRequirement=(error as? ShouError)?.accessRequirement
                try save()
                if ExecutionFailurePolicy.continues(after: error) { continue }
                break
            }
            // A lost result write must leave a durable started-item intent.
            receipt.items[index].state="moving"
            try save()
            do {
                let item=receipt.items[index]
                let moved=try item.uninstallOrigin?.kind == .application
                    ? filesystem.moveApplicationToTrash(path, expected: item.manifest)
                    : filesystem.moveToTrash(path, expected: item.manifest)
                receipt.items[index].trashPath=moved.path; receipt.items[index].manifest=moved.manifest
                receipt.items[index].state=moved.verified ? "trashed" : "unknown"
                if !moved.verified { receipt.items[index].error="Moved identity or contents could not be verified." }
            } catch {
                let nativeError=error as NSError
                let cancelled=ExecutionFailurePolicy.authorizationCancelled(error) || (nativeError.domain == NSCocoaErrorDomain && nativeError.code == NSUserCancelledError) ||
                    (nativeError.domain == NSOSStatusErrorDomain && nativeError.code == -128)
                if cancelled {
                    receipt.items[index].state="skipped"
                    receipt.state="cancelled"
                } else {
                    receipt.items[index].state=["trash_outcome_unknown", "authorization_channel_lost"].contains((error as? ShouError)?.code ?? "") ? "unknown" : "failed"
                }
                if let observed=(error as? ShouError)?.details["resulting_path"], !observed.isEmpty {
                    receipt.items[index].trashPath=observed
                }
                receipt.items[index].error=diagnostic(error)
                receipt.items[index].accessRequirement=(error as? ShouError)?.accessRequirement
            }
            try save()
            progress(ExecutionProgress(stage: "moving", processedCount: index + 1, itemCount: items.count, path: path))
            if receipt.state == "cancelled" || receipt.items[index].state == "unknown" { break }
        }
        if receipt.state != "cancelled" { receipt.state=receipt.items.allSatisfy { $0.state == "trashed" } ? "completed" : "partial" }
        progress(ExecutionProgress(stage: "finalizing", processedCount: receipt.items.filter { !["pending", "moving"].contains($0.state) }.count, itemCount: items.count))
        receipt.volumeAvailableAfter=filesystem.availableBytes(workspace.path)
        try save()
        HistorySummaries.save(receipt, store: store)
        return receipt
    }

    static func diagnostic(_ error: Error) -> String {
        let reasons=(error as? ShouError)?.details["reasons"]?.split(separator: ",").map(String.init) ?? []
        let observed=(error as? ShouError)?.details["resulting_path"].flatMap { $0.isEmpty ? nil : "Observed result: " + $0 }
        let failures=(error as? ShouError)?.details["failures"].map { [$0] } ?? []
        let code=(error as? ShouError)?.code ?? ""
        let message=code.hasPrefix("authorization_") ? code : error.localizedDescription
        return ([message] + reasons + failures + (observed.map { [$0] } ?? [])).joined(separator: "\n")
    }
}
