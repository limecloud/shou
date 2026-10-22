import Foundation
import ShouCore

/// A human review of selected roots, separate from the full evidence returned by read commands.
struct TerminalReviewScope: Encodable {
    struct WorkspaceScope: Encodable {
        let id: String
        let rootRef: String
        let path: String

        init(id: String, rootRef: String, path: String) { self.id=id; self.rootRef=rootRef; self.path=path }
        init(_ workspace: Workspace) {
            id=workspace.id; rootRef=workspace.rootRef; path=workspace.path
        }
        init(application: ApplicationDefinition) {
            id=application.id; rootRef="application-uninstall"; path=application.path
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
        init(component: UninstallComponent) {
            id=component.id; originalPath=component.path; trashPath=nil; allocatedBytesEstimate=component.allocatedBytesEstimate
            risk=component.requiresUserDataConsent ? "personal_data" : "application_removal"
            rebuildNotes=[]; limitations=["exact_bundle_identifier_association"] + component.warnings; ruleVersions=[:]
        }
        init(applicationData component: WindowsApplicationDataComponent) {
            id=component.id;originalPath=component.path;trashPath=nil;allocatedBytesEstimate=component.allocatedBytesEstimate
            risk="personal_data";rebuildNotes=[];limitations=["Settings, profiles, sign-ins and local databases; permanent removal has no restore."];ruleVersions=[:]
        }
        init(uninstallItem item: ItemReceipt) {
            id=item.id; originalPath=item.originalPath; trashPath=item.trashPath; allocatedBytesEstimate=item.allocatedBytesEstimate
            risk=item.uninstallOrigin?.kind.requiresUserDataConsent == true ? "personal_data" : "application_removal"
            rebuildNotes=[]; limitations=["exact_bundle_identifier_association"]; ruleVersions=[:]
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

    init(storage plan: StorageRemovalPlan, locale: String) {
        action=plan.action; planId=plan.id; executionId=nil; digest=plan.digest
        workspace=WorkspaceScope(id: plan.scanId, rootRef: "space-analysis", path: plan.rootPath)
        selectedItemCount=plan.items.count; allocatedBytesEstimate=plan.allocatedBytesEstimate; irreversible=plan.action == "permanent"
        notes=[locale == "zh-CN" ? "仅删除用户明确选中的项目。永久删除不可恢复；移入废纸篓可在历史记录恢复，但不会立即释放空间。" : "Only explicitly selected items are removed. Permanent deletion is irreversible. Trash supports restoration from history but does not free disk space."]
        items=plan.items.map { Item(id: $0.path, originalPath: StorageRemovalPolicy.absolute(root: plan.rootPath, relative: $0.path), trashPath: nil, bytes: $0.allocatedBytesEstimate, candidate: nil, locale: locale) }
    }

    init(uninstall plan: ApplicationUninstallPlan, locale: String) {
        action=plan.effectiveAction == "permanent" ? "permanent_uninstall" : "uninstall"
        planId=plan.id; executionId=nil; digest=plan.digest; workspace=WorkspaceScope(application: plan.application)
        selectedItemCount=plan.components.count; allocatedBytesEstimate=plan.allocatedBytesEstimate; irreversible=plan.effectiveAction == "permanent"
        notes=Self.uninstallNotes(permanent: irreversible, locale: locale)
        items=plan.components.map(Item.init(component:))
    }

    init(applicationData plan: WindowsApplicationDataPlan,locale: String) {
        action="windows_application_data_cleanup";planId=plan.id;executionId=nil;digest=plan.digest
        workspace=WorkspaceScope(id: plan.id,rootRef: "windows-application-data",path: plan.components.map(\.path).joined(separator: "\n"))
        selectedItemCount=plan.components.count;allocatedBytesEstimate=plan.components.reduce(0) { $0+$1.allocatedBytesEstimate };irreversible=true
        notes=[locale=="zh-CN" ? "永久删除所选应用的个人数据，包括设置、登录状态和本地数据库，无法恢复。便携或自定义安装仍可能使用这些数据。" : "Permanently remove selected settings, sign-ins and local databases. No restore; portable/custom installations may still use this data."]
        items=plan.components.map(Item.init(applicationData:))
    }

    init(uninstallBatch plan: ApplicationUninstallBatchPlan, locale: String) {
        action=plan.action == "permanent" ? "permanent_batch_uninstall" : "batch_uninstall"
        planId=plan.id; executionId=nil; digest=plan.digest
        workspace=WorkspaceScope(id: plan.id, rootRef: "application-batch-uninstall", path: plan.plans.map(\.application.path).joined(separator: "\n"))
        selectedItemCount=plan.plans.reduce(0) { $0 + $1.components.count }; allocatedBytesEstimate=plan.allocatedBytesEstimate
        irreversible=plan.action == "permanent"; notes=Self.uninstallNotes(permanent: irreversible, locale: locale)
        items=plan.plans.flatMap(\.components).map(Item.init(component:))
    }

    private static func uninstallNotes(permanent: Bool, locale: String) -> [String] {
        if permanent {
            return [locale == "zh-CN" ? "永久删除以下明确选中的应用组件，此操作不可恢复。个人数据仅在单独同意后纳入；执行前重新核验所有应用与组件。" : "Permanently remove only these selected application components. This cannot be undone. Personal data requires separate consent. All applications and components are rechecked before execution."]
        }
        return [locale == "zh-CN" ? "将以下明确选中的应用组件移入废纸篓。个人数据仅在单独同意后纳入；可从历史记录恢复，不覆盖已有文件。移入废纸篓不代表已释放空间。" : "Move only these selected application components to Trash. Personal data is included only with separate consent. Restore from history without overwriting existing files. Moving to Trash does not free disk space."]
    }

    init(plan: CleanupPlan, locale: String) {
        action=plan.action; planId=plan.id; executionId=nil; digest=plan.digest
        workspace=WorkspaceScope(plan.workspace); selectedItemCount=plan.items.count
        allocatedBytesEstimate=plan.allocatedBytesEstimate; irreversible=plan.action == "permanent"
        notes=plan.action == "permanent"
            ? [locale == "zh-CN" ? "此操作不可恢复，将永久删除以下明确选中的项目。执行前将重新核验当前规则与文件证据。" : "This is irreversible. Only the explicitly selected items below will be permanently removed after current rules and file evidence are rechecked."]
            : [locale == "zh-CN" ? "移入废纸篓不代表已释放磁盘空间。执行前将重新核验当前规则与文件证据。" : "Moving to Trash does not mean disk space has been freed. Current rules and file evidence will be verified again before execution."]
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
            if item.uninstallOrigin != nil { return Item(uninstallItem: item) }
            let candidate=plan?.items.first { $0.id == item.id && $0.candidate.relativePath == item.relativePath }?.candidate
            return Item(id: item.id, originalPath: item.originalPath, trashPath: item.trashPath,
                        bytes: item.allocatedBytesEstimate, candidate: candidate, locale: locale)
        }
    }
}

struct StartupControlReviewScope: Encodable {
    let action: String
    let label: String
    let path: String
    let source: String
    let notes: [String]
}
