import Foundation
import ShouCore

/// A human review of selected roots, separate from the full evidence returned by read commands.
struct TerminalReviewScope: Encodable {
    struct WorkspaceScope: Encodable {
        let id: String
        let rootRef: String
        let path: String

        init(_ workspace: Workspace) {
            id=workspace.id; rootRef=workspace.rootRef; path=workspace.path
        }
    }

    struct Item: Encodable {
        let id: String
        let originalPath: String
        let trashPath: String?
        let allocatedBytesEstimate: Int64
        let risk: String
        let rebuildNotes: [String]
        let limitations: [String]
        let ruleVersions: [String: String]

        init(id: String, originalPath: String, trashPath: String?, bytes: Int64, candidate: Candidate?, locale: String) {
            self.id=id; self.originalPath=originalPath; self.trashPath=trashPath
            allocatedBytesEstimate=bytes
            risk=candidate?.risk ?? "unavailable"
            rebuildNotes=candidate?.rebuildNotes ?? []
            limitations=candidate?.limitations ?? [locale == "zh-CN" ? "原清理计划的风险和重建信息不可用；请先核对操作记录与具体路径。" : "Original cleanup risk and rebuild metadata are unavailable; review history and the exact paths before continuing."]
            ruleVersions=candidate?.ruleVersions ?? [:]
        }
    }

    let action: String
    let planId: String
    let executionId: String?
    let digest: String
    let workspace: WorkspaceScope
    let selectedItemCount: Int
    let allocatedBytesEstimate: Int64
    let irreversible: Bool
    let notes: [String]
    let items: [Item]

    init(plan: CleanupPlan, locale: String) {
        action="trash"; planId=plan.id; executionId=nil; digest=plan.digest
        workspace=WorkspaceScope(plan.workspace); selectedItemCount=plan.items.count
        allocatedBytesEstimate=plan.allocatedBytesEstimate; irreversible=false
        notes=[locale == "zh-CN" ? "移入废纸篓不代表已释放磁盘空间。执行前将重新核验当前规则与文件证据。" : "Moving to Trash does not mean disk space has been freed. Current rules and file evidence will be verified again before execution."]
        items=plan.items.map {
            Item(id: $0.id, originalPath: plan.workspace.path + "/" + $0.candidate.relativePath,
                 trashPath: nil, bytes: $0.candidate.allocatedBytesEstimate, candidate: $0.candidate, locale: locale)
        }
    }

    init(receipt: ExecutionReceipt, selected: [ItemReceipt], action: String, digest: String, originalPlan: CleanupPlan?, locale: String) {
        self.action=action; planId=receipt.planId; executionId=receipt.id; self.digest=digest
        workspace=WorkspaceScope(receipt.workspace); selectedItemCount=selected.count
        allocatedBytesEstimate=selected.reduce(0) { $0 + $1.allocatedBytesEstimate }; irreversible=action == "purge"
        if action == "purge" {
            notes=[locale == "zh-CN" ? "此操作不可撤销。仅永久删除以下明确选中的废纸篓项目。执行前将重新核验文件证据。" : "This cannot be undone. Only the explicitly selected Trash items below will be permanently removed. File evidence will be verified again before execution."]
        } else {
            notes=[locale == "zh-CN" ? "仅恢复以下明确选中的废纸篓项目，不覆盖目标路径已有文件。执行前将重新核验文件证据。" : "Only the explicitly selected Trash items below will be restored, without overwriting existing destination files. File evidence will be verified again before execution."]
        }
        let plan=originalPlan.flatMap { $0.id == receipt.planId && $0.workspace.id == receipt.workspace.id ? $0 : nil }
        items=selected.map { item in
            let candidate=plan?.items.first { $0.id == item.id && $0.candidate.relativePath == item.relativePath }?.candidate
            return Item(id: item.id, originalPath: item.originalPath, trashPath: item.trashPath,
                        bytes: item.allocatedBytesEstimate, candidate: candidate, locale: locale)
        }
    }
}
