import Foundation
import Observation
import ShouCore
import ShouPlatform

@MainActor @Observable final class PackageUpdatesSession {
    var source="homebrew"
    var inventories=[PackageUpdateProvider: PackageUpdateInventory]()
    var selection=Set<String>()
    var plan: PackageUpdatePlan?
    var results=[PackageUpdateResult]()
    var loading=false
    var executing=false
    var progress: PackageUpdateProgress?
    var failure: String?
    private let service: PackageUpdateService
    private var operation=UUID()
    private var task: Task<Void, Never>?

    init(service: PackageUpdateService = .native()) { self.service=service }

    var provider: PackageUpdateProvider? { PackageUpdateProvider(rawValue: source) }
    var inventory: PackageUpdateInventory? { provider.flatMap { inventories[$0] } }

    func changeSource() {
        selection=[]; plan=nil; results=[]; failure=nil
    }

    func load(app: AppModel) {
        guard let provider, !app.busy else { return }
        let token=UUID(); operation=token
        loading=true; app.busy=true; failure=nil; plan=nil; results=[]; selection=[]
        app.statusKey="Checking installed software…"
        task=Task {
            defer { if operation == token { loading=false; app.busy=false } }
            do {
                let value=try await service.inventory(provider)
                try Task.checkCancellation()
                guard operation == token else { return }
                inventories[provider]=value
                if value.issue != nil { failure="The package manager could not check available versions. Installed packages are shown without upgrade eligibility." }
                app.statusKey=value.issue == nil ? "Software update check finished." : "Software update check incomplete."
            } catch {
                if !Task.isCancelled { failure=reason(error) }
                app.statusKey="Software update check stopped."
            }
        }
    }

    func prepare(_ ids: Set<String>, app: AppModel) {
        guard let inventory, !app.busy, !ids.isEmpty else { return }
        loading=true; app.busy=true; failure=nil; results=[]
        task=Task {
            defer { loading=false; app.busy=false }
            do {
                let value=try await service.prepare(inventory, selectedIDs: ids)
                try Task.checkCancellation()
                selection=Set(value.items.map(\.id)); plan=value
            } catch { if !Task.isCancelled { failure=reason(error) } }
        }
    }

    func execute(app: AppModel) {
        guard let plan, !app.busy else { return }
        let token=UUID(); operation=token
        self.plan=nil; failure=nil; results=[]; progress=nil
        executing=true; app.busy=true; app.isExecuting=true; app.stopRequested=false; app.operationHadError=false
        app.statusKey="Updating software…"
        task=Task {
            defer {
                if operation == token {
                    executing=false; app.isExecuting=false; app.busy=false; app.stopRequested=false; selection=[]
                }
            }
            do {
                results=try await service.execute(plan, progress: { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.operation == token, self.executing else { return }
                        self.progress=value
                    }
                })
                app.operationHadError=results.contains { $0.state != "succeeded" }
                // A new check is required before another mutation, including after cancellation.
                inventories[plan.provider]=nil
                app.statusKey="Software update results are ready."
            } catch {
                app.operationHadError=true; inventories[plan.provider]=nil
                failure=reason(error)
                app.statusKey="Review the package manager before retrying."
            }
        }
    }

    func stop() { task?.cancel() }
    func waitForOperation() async { await task?.value }

    private func reason(_ error: Error) -> String {
        if error is CancellationError || Task.isCancelled { return "The update was stopped. Some software may have changed; check again before retrying." }
        return switch (error as? ShouError)?.code {
        case "tool_not_installed": "The package manager is not installed in a supported location."
        case "tool_changed", "plan_stale", "package_changed", "update_changed": "Installed software or update metadata changed. Check again before upgrading."
        case "permission_denied": "Open the package manager to authorize this operation, then refresh in Shou."
        case "cancelled": "The update was stopped. Some software may have changed; check again before retrying."
        default: "The package manager could not finish. Open the owning tool or check again."
        }
    }
}
