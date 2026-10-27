import Foundation
import Observation
import ShouCore
import ShouPlatform

@MainActor @Observable final class DeveloperToolsSession {
    let catalog: DeveloperToolCatalog?
    let mysql=MySQLWorkbenchSession()
    let configuration=DeveloperConfigurationSession()
    var query=""
    var category="all"
    var collection="workspace"
    var installedOnly=false
    var sourceFilter="all"
    var area="developer-tools"
    var inventory: DeveloperToolInventory?
    var inventoryLoading=false
    var favorites: Set<String>
    var focusedID: String?
    var package: DeveloperToolPackage?
    var inspection: DeveloperToolInspection?
    var plan: DeveloperToolPlan?
    var result: DeveloperToolResult?
    var failure: String?
    var loading=false
    var versionInspections=[DeveloperToolInspection]()
    var versionsLoading=false
    var executing=false
    var workspace: AIWorkspaceSnapshot?
    var workspaceLoading=false
    var detailTab="installation"
    var services: DeveloperServiceSnapshot?
    var servicesObservedAt: Date? { focusedID.flatMap { serviceObservationDates[$0] } }
    var serviceFailure: String?
    var serviceResult: DeveloperServiceResult?
    var changingServiceID: String?
    var changingServiceAction: DeveloperServiceAction?
    var serviceStage: String?
    var logText: String?
    var logService: DeveloperService?
    var logPath=""
    var logLoading=false
    var logFailure: String?
    var servicesLoading: Bool { focusedID.map { serviceReadToolIDs.contains($0) } ?? false }
    func checkingServices(_ id: String) -> Bool { serviceReadToolIDs.contains(id) }
    var staleServiceIDs=Set<String>()
    private let nativeServices: NativeDeveloperServices
    private let service: DeveloperToolService?
    private let serviceController: DeveloperServiceController?
    private var task: Task<Void,Never>?
    private var workspaceTask: Task<Void,Never>?
    private var logTask: Task<Void,Never>?
    private var inventoryTask: Task<Void,Never>?
    private var serviceReadTask: Task<Void,Never>?
    private var versionsTask: Task<Void,Never>?
    private var serviceReadToolIDs=Set<String>()
    private var inventoryRevision=0
    private var loadedServiceTools=Set<String>()
    private var serviceObservationDates=[String:Date]()

    init() {
        catalog=try? DeveloperToolCatalog.bundled()
        service=try? DeveloperToolService.native()
        let nativeServices=NativeDeveloperServices()
        self.nativeServices=nativeServices
        serviceController=catalog.map { DeveloperServiceController(catalog: $0, platform: nativeServices, makeStore: { try LocalRecordStore() }) }
        favorites=Set(UserDefaults.standard.stringArray(forKey: "developerToolFavorites") ?? [])
        if catalog == nil || service == nil { failure="The developer tool catalog could not be loaded." }
    }
    var focused: DeveloperToolDefinition? { catalog?.tools.first { $0.id == focusedID } }
    var packages: [DeveloperToolPackage] { focused?.packages.filter { $0.provider == "homebrew" } ?? [] }
    var categories: [DeveloperToolCategory] { (catalog?.categories ?? []).filter { value in (catalog?.tools ?? []).contains { $0.category == value.id && $0.isAI == (area == "ai-tools") } } }
    func installations(_ id: String) -> [DeveloperToolInstallation] { inventory?.installations.filter { $0.toolID == id } ?? [] }
    var tools: [DeveloperToolDefinition] {
        (catalog?.tools ?? []).filter {
            $0.isAI == (area == "ai-tools") && (category == "all" || $0.category == category) &&
            (collection != "workspace" || favorites.contains($0.id)) && (collection == "workspace" || !installedOnly || !installations($0.id).isEmpty || !toolServices($0.id).isEmpty) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query))
        }
    }
    func changeArea(_ value: String) {
        guard area != value else { return }
        workspaceTask?.cancel(); workspace=nil; workspaceLoading=false
        area=value; focusedID=nil; package=nil; inspection=nil; plan=nil; result=nil; failure=nil; query=""; category="all"; collection="workspace"; installedOnly=false
        serviceResult=nil; serviceFailure=nil; logTask?.cancel(); logText=nil; logService=nil; logFailure=nil; logLoading=false
        reconcileFocus()
    }
    func scanInstalled(app: AppModel) {
        guard let catalog, !app.busy, !inventoryLoading else { return }
        inventoryLoading=true; failure=nil; inspection=nil; plan=nil; result=nil; serviceResult=nil
        serviceReadTask?.cancel(); serviceReadToolIDs=[]
        inventoryRevision += 1; let revision=inventoryRevision
        loadedServiceTools.removeAll(); staleServiceIDs.formUnion(services?.services.map(\.id) ?? [])
        reconcileFocus()
        inventoryTask=Task {
            let session=self
            let work=Task.detached(priority: .userInitiated) {
                try NativeDeveloperToolInventory().scan(catalog) { value in
                    Task { @MainActor [weak session] in
                        guard let session, session.inventoryRevision == revision, session.inventoryLoading else { return }
                        session.inventory=value; session.reconcileFocus()
                    }
                }
            }
            do {
                inventory=try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                inventoryLoading=false
                reconcileFocus(); loadWorkspace()
                if sourceFilter != "all", !installations(focusedID ?? "").contains(where: { $0.source == sourceFilter }) { sourceFilter="all" }
                loadServices(force: true)
            } catch { inventoryLoading=false; if !Task.isCancelled { failure=reason(error) } }
        }
    }
    func toggleFavorite(_ id: String) {
        guard !executing, plan == nil, catalog?.tools.contains(where: { $0.id == id }) == true else { return }
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        UserDefaults.standard.set(favorites.sorted(), forKey: "developerToolFavorites")
        if collection == "workspace" { reconcileFocus(); loadServices() }
    }
    func open(_ tool: DeveloperToolDefinition) {
        versionsTask?.cancel(); versionInspections=[]; versionsLoading=false
        focusedID=tool.id; inspection=nil; plan=nil; result=nil; failure=nil
        serviceResult=nil; serviceFailure=nil; logText=nil; logService=nil; logFailure=nil; logTask?.cancel(); logLoading=false
        detailTab=tool.id == "mysql" ? "mysql.service" : "overview"; sourceFilter="all"
        package=tool.packages.first { $0.provider == "homebrew" }
        loadWorkspace(); loadServices()
    }
    func loadVersions() {
        guard let service, let toolID=focusedID, !versionsLoading else { return }
        let sources=packages
        versionsLoading=true; versionInspections=[]
        versionsTask=Task {
            defer { if focusedID == toolID { versionsLoading=false } }
            for source in sources {
                guard !Task.isCancelled, focusedID == toolID else { return }
                do {
                    let value=try await service.inspect(toolID:toolID,package:source)
                    guard !Task.isCancelled, focusedID == toolID else { return }
                    versionInspections.append(value)
                } catch { if !Task.isCancelled { failure=reason(error) } }
            }
        }
    }
    func reconcileFocus() {
        defer { loadServices() }
        guard !tools.contains(where: { $0.id == focusedID }) else { return }
        if let tool=tools.first { open(tool) }
        else { focusedID=nil; workspaceTask?.cancel(); workspace=nil }
    }
    func toolServices(_ id: String) -> [DeveloperService] { services?.services.filter { $0.toolID == id } ?? [] }
    func serviceForInstallation(_ row: DeveloperToolInstallation) -> DeveloperService? {
        let matches=servicesForInstallation(row)
        return matches.count == 1 ? matches.first : nil
    }
    func servicesForInstallation(_ row: DeveloperToolInstallation) -> [DeveloperService] {
        toolServices(row.toolID).filter { $0.installationPath == row.path && (row.version == nil || $0.version == row.version) }
    }
    func managedPackage(_ row: DeveloperToolInstallation) -> DeveloperToolPackage? {
        catalog.flatMap { NativeDeveloperTools.package(for:row,catalog:$0) }
    }
    func installationForService(_ row: DeveloperService) -> DeveloperToolInstallation? {
        installations(row.toolID).first { $0.path == row.installationPath && $0.version == row.version }
    }
    var uninstallServices: [DeveloperService] {
        guard let plan, plan.action == .uninstall else { return [] }
        let paths=Set(installations(plan.toolID).filter { managedPackage($0) == plan.inspection.package }.map(\.path))
        return toolServices(plan.toolID).filter { paths.contains($0.installationPath) }
    }
    var canExecutePlan: Bool {
        guard let plan, !inventoryLoading, !servicesLoading else { return false }
        return plan.action != .uninstall || uninstallServices.allSatisfy { $0.state == "stopped" && $0.issue == nil && !staleServiceIDs.contains($0.id) }
    }
    func reviewUninstall(_ row: DeveloperToolInstallation, app: AppModel) {
        guard let service, let source=managedPackage(row), focusedID == row.toolID,
              !app.busy, !inventoryLoading, !servicesLoading else { return }
        detailTab="installation"; sourceFilter="Homebrew"; package=source; inspection=nil; plan=nil; result=nil; failure=nil
        loading=true; app.busy=true
        task=Task {
            defer { loading=false; app.busy=false }
            do {
                let value=try await service.inspect(toolID:row.toolID,package:source)
                guard value.installedVersions.contains(row.version ?? "") else { throw ShouError("developer_tool_changed","The installed version changed.") }
                inspection=value; plan=try await service.prepare(toolID:row.toolID,action:.uninstall,expected:value)
            } catch { failure=reason(error) }
        }
    }
    func refreshServices(app: AppModel) {
        guard !app.busy else { return }
        loadServices(force: true)
    }
    private func loadServices(force: Bool = false) {
        guard let serviceController, let inventory, !inventoryLoading else { return }
        let visible=Set((catalog?.tools ?? []).filter { favorites.contains($0.id) && $0.isAI == (area == "ai-tools") }.map(\.id))
        let requested=force ? visible : visible.subtracting(loadedServiceTools)
        guard !requested.isEmpty else { return }
        if !serviceReadToolIDs.isEmpty { return }
        serviceReadToolIDs=requested; serviceFailure=nil
        staleServiceIDs.formUnion((services?.services ?? []).filter { requested.contains($0.toolID) }.map(\.id))
        serviceReadTask=Task {
            do {
                let observed=try await serviceController.scan(inventory, toolIDs: requested)
                guard !Task.isCancelled else { return }
                let retained=services?.services.filter { !requested.contains($0.toolID) } ?? []
                services = .init(services: retained + observed.services, issues: observed.issues)
                for id in requested { serviceObservationDates[id]=Date() }
                loadedServiceTools.formUnion(requested)
                staleServiceIDs.subtract(observed.services.map(\.id))
            } catch {
                guard !Task.isCancelled else { return }
                serviceFailure="Service state could not be verified. Refresh before using a switch."
            }
            serviceReadToolIDs=[]
            // Selection may change during a read. Query only newly added tools.
            if !Task.isCancelled && requested.isSubset(of: loadedServiceTools) { loadServices() }
        }
    }
    func changeService(_ expected: DeveloperService, running: Bool, app: AppModel) {
        performService(running ? .start : .stop, expected: expected, app: app)
    }
    func performService(_ action: DeveloperServiceAction, expected: DeveloperService, app: AppModel) {
        guard let serviceController, favorites.contains(expected.toolID), !app.busy, !inventoryLoading, !checkingServices(expected.toolID), !staleServiceIDs.contains(expected.id) else { return }
        changingServiceID=expected.id; changingServiceAction=action; serviceStage="checking"; serviceFailure=nil; serviceResult=nil; executing=true; app.busy=true; app.isExecuting=true; app.operationHadError=false
        task=Task {
            defer { changingServiceID=nil; changingServiceAction=nil; serviceStage=nil; executing=false; app.busy=false; app.isExecuting=false; app.stopRequested=false }
            do {
                serviceResult=try await serviceController.perform(action, expected: expected) { event in
                    Task { @MainActor [weak self] in
                        guard self?.changingServiceID == event.serviceID else { return }
                        self?.serviceStage=event.stage
                    }
                }
                app.operationHadError=serviceResult?.state != "succeeded"
                if app.operationHadError { serviceFailure=serviceResult?.state == "partial" ? "The service stopped, but restart did not finish. Refresh its source before continuing." : "The service result needs verification. Refresh its source; Shou will not retry automatically." }
            } catch { serviceFailure="Service state could not be verified. Refresh before using a switch."; app.operationHadError=true }
            if let observed=serviceResult?.observed, let existing=services {
                services = .init(services: existing.services.map { $0.id == expected.id ? observed : $0 }, issues: existing.issues)
                serviceObservationDates[expected.toolID]=Date()
            }
            if app.operationHadError { staleServiceIDs.insert(expected.id) }
            app.statusKey="Developer tool results are ready."
        }
    }
    func loadLog(_ service: DeveloperService, errorLog: Bool = false) {
        logTask?.cancel(); logLoading=true; logFailure=nil; logText=nil; logService=service
        logPath=(errorLog ? service.errorLogPath : service.logPath) ?? ""
        logTask=Task {
            let platform=nativeServices
            let work=Task.detached(priority: .utility) { try platform.readLog(service, errorLog: errorLog) }
            do {
                let text=try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, focusedID == service.toolID else { return }
                logText=text
            } catch {
                guard !Task.isCancelled, focusedID == service.toolID else { return }
                logFailure="The service log cannot be read. Check its path and access permissions."
            }
            logLoading=false
        }
    }
    func loadWorkspace() {
        workspaceTask?.cancel(); workspace=nil; workspaceLoading=false
        guard let id=focusedID, AIWorkspaceSummary.supportedTools.contains(id) else { return }
        workspaceLoading=true
        workspaceTask=Task {
            let work=Task.detached(priority: .utility) { try NativeAIWorkspace().inspect(toolID: id) }
            let observed=try? await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, focusedID == id else { return }
            workspace=observed; workspaceLoading=false
        }
    }
    func inspect(app: AppModel) {
        guard let service, let focusedID, let package, !app.busy, !inventoryLoading, !servicesLoading else { return }
        inspection=nil; plan=nil; result=nil; failure=nil; loading=true; app.busy=true
        task=Task {
            defer { loading=false; app.busy=false }
            do { inspection=try await service.inspect(toolID: focusedID, package: package) }
            catch { failure=reason(error) }
        }
    }
    func prepare(_ action: DeveloperToolAction, app: AppModel) {
        guard let service, let focusedID, let inspection, !app.busy, !inventoryLoading, !servicesLoading else { return }
        loading=true; app.busy=true; failure=nil
        task=Task {
            defer { loading=false; app.busy=false }
            do { plan=try await service.prepare(toolID: focusedID, action: action, expected: inspection) }
            catch { self.inspection=nil; failure=reason(error) }
        }
    }
    func execute(app: AppModel) {
        guard let service, let plan, !app.busy, canExecutePlan else { return }
        self.plan=nil; failure=nil; executing=true; app.busy=true; app.isExecuting=true; app.operationHadError=false
        app.statusKey="Managing developer tools…"
        task=Task {
            defer { executing=false; app.busy=false; app.isExecuting=false; app.stopRequested=false; inspection=nil }
            do {
                result=try await service.execute(plan, confirmedID: plan.id)
                app.operationHadError=result?.state != "succeeded"; inventory=nil
                if let catalog {
                    let refresh=Task.detached(priority: .utility) { try NativeDeveloperToolInventory().scan(catalog) }
                    inventory=try? await refresh.value
                    loadedServiceTools.removeAll(); staleServiceIDs.formUnion(services?.services.map(\.id) ?? [])
                    loadServices(force: true)
                }
            }
            catch { failure=reason(error); app.operationHadError=true }
            app.statusKey="Developer tool results are ready."
        }
    }
    func stop() { task?.cancel(); configuration.stop() }
    func waitForOperation() async { await task?.value; await configuration.waitForOperation() }
    private func reason(_ error: Error) -> String {
        switch (error as? ShouError)?.code {
        case "tool_not_installed": "Homebrew is not available in a supported location. Install it from its official website, then inspect again."
        case "developer_tool_changed", "confirmation_required": "The tool or its source changed. Inspect it and review the operation again."
        case "store_busy": "Another Shou operation is using the local records. Try again after it finishes."
        case "permission_denied": "The package manager needs permissions that Shou cannot request. Open the owning tool to continue."
        case "developer_tool_running": "Stop the instances using this installation before uninstalling it."
        case "developer_tool_activity_unavailable": "Running programs could not be verified. Refresh before uninstalling."
        default: "The tool could not be inspected or changed. Use its official guide or inspect again."
        }
    }
}
