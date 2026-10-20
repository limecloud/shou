import SwiftUI
import ShouCore
import ShouPlatform
import AppKit
import Observation
import UniformTypeIdentifiers
import Accessibility

@main struct ShouApp: App {
    @NSApplicationDelegateAdaptor(ShouApplicationDelegate.self) private var applicationDelegate
    @State private var model=AppModel()
    @AppStorage("ShouAppearance") private var appearance="system"
    init() { NSApplication.shared.applicationIconImage=AppIdentity.icon }
    var body: some Scene {
        WindowGroup(model.displayTitle) {
            ContentView(model: model)
                .environment(\.locale, model.language.locale)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .tint(Color(red: 0.78, green: 0.34, blue: 0.03))
                .accentColor(Color(red: 0.78, green: 0.34, blue: 0.03))
                .frame(minWidth: 900, minHeight: 620)
                .background(OperationWindowGuard(model: model))
                .task { applicationDelegate.model=model; await model.initialize() }
        }
        .defaultSize(width: 1160, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(model: model, updater: model.updater)
            }
            CommandGroup(replacing: .appSettings) {
                Button(model.t("Settings…")) { model.section="settings" }.keyboardShortcut(",")
            }
            CommandGroup(after: .newItem) { Button(model.t("Include Folder…")) { model.addWorkspace() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.busy) }
            CommandMenu(model.t("Cleanup")) { Button(model.t("Scan")) { model.scanCurrentSection() }.keyboardShortcut("r").disabled(model.busy) }
        }
    }
}

struct ReviewPrompt: Identifiable {
    let id: String
    let digest: String
    let action: String
    let paths: [String]
    let itemIds: [String]
    let byteEstimate: Int64
    var plans: [ReviewedPlan]=[]
    var impacts: [String]=[]
}

struct ReviewedPlan {
    let id: String
    let digest: String
    let workspacePath: String
}

struct CleanupCompletion: Identifiable {
    let id=UUID()
    let receipts: [ExecutionReceipt]
    var failures: [String]=[]
}

@MainActor @Observable final class AppModel {
    let updater=AppUpdater()
    var configuration=Configuration()
    var workspaceId=""
    var section="smart"
    var knownLocations: [KnownLocation]=[]
    var projectLocations: [KnownLocation]=[]
    var systemResult: SystemScanResult?
    var commonReview=CleanupReview()
    var commonSelection=Set<String>()
    var scanningLocation: KnownLocation?
    var snapshot: ScanSnapshot? {
        didSet {
            storage=StorageIndex(entries: []); browsingPath="."; focusedPath=nil
            guard let value=snapshot else { return }
            Task {
                let index=await Task.detached(priority: .userInitiated) { StorageIndex(entries: value.entries) }.value
                guard snapshot?.id == value.id else { return }
                storage=index
            }
        }
    }
    var storage=StorageIndex(entries: [])
    var space=StorageSession()
    var browsingPath="."
    var focusedPath: String?
    var ruleDraftPattern=""
    var builtins: [CleanupRule]=[]
    var scanProgress: ScanProgress?
    var selection=Set<String>()
    var history: [ExecutionReceipt]=[]
    var followups: [FollowUpReceipt]=[]
    var startupInventory: StartupInventory?
    var applicationCatalog: ApplicationCatalog?
    var applicationReview: ApplicationUninstallReview?
    var applicationsLoading=false
    var applicationsIncludeSystem=false
    var startupIncludeSystem=false
    var startupLoading=false
    var startupControlLoading=false
    var startupControlResult: StartupControlResult?
    private let startupService=StartupInventoryService(source: NativeStartupInventory())
    private let startupControlService=StartupControlService(controller: NativeStartupControl())
    var busy=false { didSet { updater.operationInProgress=busy } }
    var scanning=false
    var isExecuting=false
    var stopRequested=false
    var executionProgress: ExecutionProgress?
    var error: String?
    var statusKey=""
    var prompt: ReviewPrompt?
    var completion: CleanupCompletion?
    var historyInspection: HistoryInspectionRequest?
    var showingExclusions=false
    var language=AppLanguage(savedValue: UserDefaults.standard.string(forKey: "ShouLanguage")) {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "ShouLanguage") }
    }
    var reduceMotion=UserDefaults.standard.bool(forKey: "ShouReduceMotion") {
        didSet { UserDefaults.standard.set(reduceMotion, forKey: "ShouReduceMotion") }
    }
    private var task: Task<Void, Never>?
    var operationHadError=false
    private var operationID=UUID()
    private(set) var engine: ShouEngine?
    var initializing=true
    private var initializationStarted=false
    func initialize() async {
        guard !initializationStarted else { return }
        initializationStarted=true; busy=true
        defer { initializing=false; busy=false }
        let readWorker=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shou")
        do {
            engine=try await Task.detached(priority: .userInitiated) {
                ShouEngine(store: try LocalRecordStore(), filesystem: NativeFileSystem(readWorkerExecutable: readWorker), applicationActivity: NativeApplicationActivity(), artifactEvidence: NativeArtifactEvidence(), applicationCatalog: NativeApplicationCatalog(), uninstallEvidence: NativeApplicationUninstallEvidence())
            }.value
            await refresh()
        }
        catch { engine=nil; self.error=error.localizedDescription }
    }
    func t(_ key: String) -> String { L10n.string(key, locale: language.rawValue) }
    func diagnostic(_ message: String) -> String { message.components(separatedBy: "\n").map(t).joined(separator: "\n") }
    var displayTitle: String { language == .simplifiedChinese ? "Shou · 收拾一下" : "Shou" }
    var status: String {
        if space.scanning { return t(space.progressTitle) }
        if scanning, let progress=scanProgress {
            if progress.stage == "preparing" { return t("Preparing common app scan…") }
            let key=progress.stage == "scanning" ? "Scanning: %lld entries" : progress.stage == "analysis" ? "Analyzing %lld entries…" : "Saving %lld entries…"
            return String(format: t(key), locale: language.locale, progress.entryCount)
        }
        return t(statusKey)
    }
    var executionTitle: String {
        switch executionProgress?.stage {
        case "moving": t("Moving items to Trash…")
        case "restoring": t("Restoring selected items…")
        case "purging": t("Permanently removing selected items…")
        default: t("Checking selected items…")
        }
    }
    func date(_ value: Date) -> String { value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)) }
    var workspace: Workspace? { configuration.workspaces.first { $0.id == workspaceId } }
    var projectWorkspaces: [Workspace] { configuration.workspaces.filter { root in !knownLocations.contains { $0.path == root.path } } }
    var commonSelected: [CleanupSource] { commonReview.sources.filter { commonSelection.contains($0.id) && $0.selectable } }
    var commonRecommended: [CleanupSource] { commonReview.recommendedSources }
    var commonSelectedBytes: Int64 { commonSelected.reduce(0) { $0 + $1.candidate.allocatedBytesEstimate } }
    var selected: [Candidate] { snapshot?.candidates.filter { selection.contains($0.id) } ?? [] }
    var categories: [CleanupCategory] { CleanupOverview.categories(snapshot?.candidates ?? []) }
    var reviewable: [Candidate] { CleanupOverview.candidates(snapshot?.candidates ?? []) }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.allocatedBytesEstimate } }
    var eligibleBytes: Int64 { reviewable.filter(\.eligible).reduce(0) { $0 + $1.allocatedBytesEstimate } }
    var displayed: [Candidate] { (snapshot?.candidates ?? []).filter { section != "eligible" || $0.eligible } }
    func refresh() async {
        guard let engine else { return }
        do {
            configuration=try await engine.configuration()
            if !configuration.workspaces.contains(where: { $0.id == workspaceId }) { workspaceId=configuration.workspaces.first?.id ?? "" }
            history=try await engine.history(); followups=try await engine.followUps()
            builtins=workspaceId.isEmpty ? [] : try await engine.builtinRules(workspaceId: workspaceId)
            knownLocations=try await engine.knownLocations()
            projectLocations=try await engine.projectLocations()
        } catch { if !Task.isCancelled { self.error=error.localizedDescription } }
    }
    func addWorkspace(startScan: Bool = true) {
        guard !busy else { return }
        let panel=NSOpenPanel(); panel.canChooseFiles=false; panel.canChooseDirectories=true; panel.allowsMultipleSelection=true
        panel.message=t("Choose extra folders to remember for future cleanup scans.")
        guard panel.runModal() == .OK, !panel.urls.isEmpty, let engine else { return }
        let paths=panel.urls.map(\.path)
        busy=true
        Task {
            do {
                for path in paths {
                    if let root=configuration.workspaces.first(where: { $0.path == path }) { workspaceId=root.id; continue }
                    let root=try await engine.addWorkspace(path: path, rootRef: "location-" + String(UUID().uuidString.prefix(8)).lowercased())
                    workspaceId=root.id
                }
                invalidateScanEvidence(); await refresh(); busy=false
                if startScan { section="smart"; scanCommonLocations() }
            } catch { invalidateScanEvidence(); busy=false; await refresh(); self.error=error.localizedDescription }
        }
    }
    func selectWorkspace(_ root: Workspace) {
        guard !busy else { return }
        workspaceId=root.id; snapshot=nil; selection=[]; section="overview"
        Task { await refresh(); startScan() }
    }
    func addSuggestedLocation(_ path: String) {
        guard let engine, !busy else { return }
        if let root=configuration.workspaces.first(where: { $0.path == path }) { selectWorkspace(root); return }
        Task {
            do {
                let root=try await engine.addWorkspace(path: path, rootRef: "location-" + String(UUID().uuidString.prefix(8)).lowercased())
                workspaceId=root.id; snapshot=nil; selection=[]; await refresh(); startScan()
            } catch { self.error=error.localizedDescription }
        }
    }
    func toggleCandidate(_ candidate: Candidate, selected: Bool) {
        guard candidate.eligible, !busy else { return }
        focusedPath=candidate.relativePath
        if selected {
            let incompatible=snapshot?.candidates.filter { other in
                other.relativePath.hasPrefix(candidate.relativePath + "/") || candidate.relativePath.hasPrefix(other.relativePath + "/")
            }.map(\.id) ?? []
            selection.subtract(incompatible); selection.insert(candidate.id)
        } else { selection.remove(candidate.id) }
    }
    func selectOverviewCandidates(_ candidates: [Candidate], selected: Bool) {
        guard !busy else { return }
        let candidates=CleanupOverview.candidates(candidates).filter(\.eligible)
        let ids=Set(candidates.map(\.id))
        guard selected else { selection.subtract(ids); return }
        let paths=Set(candidates.map(\.relativePath))
        var ancestors=Set<String>()
        for path in paths {
            var parent=StorageIndex.parent(path)
            while parent != "." { ancestors.insert(parent); parent=StorageIndex.parent(parent) }
        }
        // Overview targets are disjoint. Resolve existing ancestor/descendant
        // selections once, then publish the whole group as one observation.
        let incompatible=(snapshot?.candidates ?? []).filter { candidate in
            guard selection.contains(candidate.id) else { return false }
            if ancestors.contains(candidate.relativePath) { return true }
            var parent=StorageIndex.parent(candidate.relativePath)
            while parent != "." {
                if paths.contains(parent) { return true }
                parent=StorageIndex.parent(parent)
            }
            return false
        }.map(\.id)
        var updated=selection
        updated.subtract(incompatible); updated.formUnion(ids)
        selection=updated
    }
    func startScan(preset: Preset? = nil, focusAfterScan: String? = nil) {
        guard let engine, !workspaceId.isEmpty, !busy else { return }
        busy=true; scanning=true; selection=[]; scanProgress=nil; statusKey="Scanning selected workspace…"
        let id=preset?.workspaceId ?? workspaceId
        let operation=UUID(); operationID=operation
        task=Task {
            defer { busy=false; scanning=false }
            do {
                snapshot=try await engine.scan(workspaceId: id, ruleIds: preset?.ruleIds ?? [], scope: section == "storage" ? .full : .cleanup, budget: ScanBudget(maxEntries: 500_000, maxSeconds: 180), progress: { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.scanning, self.operationID == operation else { return }
                        self.scanProgress=update
                    }
                })
                workspaceId=id
                if let path=focusAfterScan {
                    browsingPath=StorageIndex.parent(path); focusedPath=path
                }
                statusKey=snapshot?.status == "complete" ? "Scan complete. Review candidates before cleanup." : "Some paths could not be fully scanned. Only independently verified items can be reviewed for cleanup."
            } catch { if !Task.isCancelled { self.error=error.localizedDescription }; statusKey="Scan stopped." }
        }
    }
    func scanCurrentSection() {
        if section == "smart" { scanCommonLocations() }
        else if section == "storage" { space.start(app: self, retainPath: true) }
        else if section == "startup" { scanStartup() }
        else if section == "applications" { scanApplications() }
        else if section == "overview" { startScan() }
        else { section="smart"; scanCommonLocations() }
    }
    func scanStartup() {
        guard !busy else { return }
        busy=true; startupLoading=true; startupInventory=nil
        statusKey="Reading startup definitions…"
        let options=StartupInventoryOptions(includeSystem: startupIncludeSystem)
        task=Task {
            defer { busy=false; startupLoading=false }
            do {
                startupInventory=try await startupService.scan(options: options)
                statusKey=startupInventory?.status == "complete" ? "Startup definitions checked. Review coverage before drawing conclusions." : "Some startup definitions could not be inspected."
            } catch {
                if Task.isCancelled { statusKey="Startup scan stopped." }
                else { statusKey="Startup discovery unavailable."; self.error=error.localizedDescription }
            }
        }
    }
    func controlStartup(_ definition: StartupDefinition, action: StartupControlAction) {
        guard !busy else { return }
        busy=true; startupControlLoading=true; error=nil
        task=Task {
            do {
                let result=try await startupControlService.apply(definition: definition, action: action)
                startupControlResult=result; statusKey=action == .enable ? "Startup definition enabled." : "Startup definition disabled."
                busy=false; startupControlLoading=false
                scanStartup()
            } catch {
                busy=false; startupControlLoading=false
                if !Task.isCancelled { self.error=error.localizedDescription }
                statusKey="Startup control failed."
            }
        }
    }
    func scanApplications() {
        guard let engine, !busy else { return }
        busy=true; applicationsLoading=true; applicationReview=nil
        statusKey="Reading installed applications…"
        let options=ApplicationCatalogOptions(includeSystem: applicationsIncludeSystem)
        task=Task {
            defer { busy=false; applicationsLoading=false }
            do {
                applicationCatalog=try await engine.applications(options: options)
                statusKey="Applications checked. Review components before uninstalling."
            } catch {
                if !Task.isCancelled { self.error=error.localizedDescription }
                statusKey="Application scan stopped."
            }
        }
    }
    func inspectApplication(_ application: ApplicationDefinition) {
        guard let engine, !busy else { return }
        busy=true; applicationsLoading=true; statusKey="Reviewing application components…"
        task=Task {
            defer { busy=false; applicationsLoading=false }
            do { applicationReview=try await engine.reviewApplication(path: application.path); statusKey="Ready to review" }
            catch { if !Task.isCancelled { self.error=error.localizedDescription }; statusKey="Application review stopped." }
        }
    }
    func previewUninstall(_ review: ApplicationUninstallReview, componentIds: [String], includeUserData: Bool) {
        guard let engine, !busy else { return }
        busy=true; statusKey="Preparing cleanup preview…"
        task=Task {
            defer { busy=false }
            do {
                let plan=try await engine.createUninstallPlan(reviewId: review.id, componentIds: componentIds, includeUserData: includeUserData)
                prompt=ReviewPrompt(id: plan.id, digest: plan.digest, action: "uninstall", paths: plan.components.map(\.path), itemIds: [], byteEstimate: plan.allocatedBytesEstimate,
                    impacts: [plan.includesUserData ? "Selected personal app data will also move to Trash." : "Personal app data is retained.", "Shared groups, package receipts and external helpers are not removed."])
                statusKey="Ready to review"
            } catch {
                statusKey="Review application components again."
                if !Task.isCancelled { self.error=error.localizedDescription }
            }
        }
    }
    func scanCommonLocations(cleanAfterScan: Bool = false, permanentAfterScan: Bool = true) {
        guard let engine, !busy else { return }
        busy=true; scanning=true; scanProgress=nil; scanningLocation=nil; systemResult=nil; commonReview=CleanupReview(); commonSelection=[]
        statusKey="Preparing common app scan…"
        let operation=UUID(); operationID=operation
        task=Task {
            defer { busy=false; scanning=false; scanningLocation=nil }
            do {
                let result=try await engine.scanKnownLocations(includeProjects: true, progress: { [weak self] location, progress in
                    Task { @MainActor in
                        guard let self, self.scanning, self.operationID == operation else { return }
                        self.scanningLocation=location; self.scanProgress=progress
                    }
                })
                commonReview=try await Task.detached(priority: .userInitiated) { try CleanupReview(snapshots: result.snapshots, locations: result.locations) }.value
                systemResult=result
                // Fixed rules are the product's fast path. The selection is
                // visible and editable, but the first result is immediately
                // actionable instead of presenting an empty checklist.
                commonSelection=Set(commonRecommended.map(\.id))
                statusKey=systemResult?.status == "complete" ? "Common app scan complete" : "Some locations could not be fully scanned."
                await refresh()
                if cleanAfterScan && !commonRecommended.isEmpty {
                    // Let the scan state settle before opening the native
                    // confirmation sheet. The plan is still created by Core;
                    // it is simply not a user-facing intermediate screen.
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        while self.busy { await Task.yield() }
                        self.previewCommonCleanup(permanent: permanentAfterScan)
                    }
                }
            } catch {
                if !Task.isCancelled { self.error=error.localizedDescription }
                statusKey="Scan stopped."; await refresh()
            }
        }
    }
    func quickCleanCommon(permanent: Bool = true) {
        if systemResult == nil {
            scanCommonLocations(cleanAfterScan: true, permanentAfterScan: permanent)
        } else {
            commonSelection=Set(commonRecommended.map(\.id))
            previewCommonCleanup(permanent: permanent)
        }
    }
    func activateSystemSnapshot(_ value: ScanSnapshot) {
        guard !busy else { return }
        workspaceId=value.workspace.id; snapshot=value; selection=[]; section="overview"
        Task { await refresh() }
    }
    func selectCommon(_ sources: [CleanupSource], selected: Bool) {
        guard !busy else { return }
        let ids=Set(sources.filter(\.selectable).map(\.id))
        if selected { commonSelection.formUnion(ids) } else { commonSelection.subtract(ids) }
    }
    func previewCommonCleanup(permanent: Bool = true) {
        guard let engine, !busy, !commonSelected.isEmpty else { return }
        let sources=commonSelected
        let action=permanent ? "permanent" : "trash"
        busy=true; statusKey="Preparing cleanup preview…"
        task=Task {
            defer { busy=false }
            do {
                var plans: [CleanupPlan]=[]
                for snapshotId in Set(sources.map(\.snapshotId)).sorted() {
                    plans.append(try await engine.createPlan(scanId: snapshotId, candidateIds: sources.filter { $0.snapshotId == snapshotId }.map(\.candidate.id), action: action))
                }
                prompt=ReviewPrompt(id: UUID().uuidString, digest: "", action: action,
                    paths: plans.flatMap { plan in plan.items.map { plan.workspace.path + "/" + $0.candidate.relativePath } }, itemIds: [],
                    byteEstimate: plans.reduce(0) { $0 + $1.allocatedBytesEstimate },
                    plans: plans.map { ReviewedPlan(id: $0.id, digest: $0.digest, workspacePath: $0.workspace.path) },
                    impacts: Array(Set(plans.flatMap { $0.items.flatMap { $0.candidate.rebuildNotes + $0.candidate.limitations } })).sorted())
                statusKey="Ready to review"
            } catch { self.error=error.localizedDescription }
        }
    }
    func cancel() { if isExecuting { stopRequested=true }; task?.cancel(); space.stop() }
    func stopAndWaitForExecution() async -> Bool {
        guard isExecuting else { return !operationHadError && error == nil }
        let running=task
        cancel()
        await running?.value
        await space.waitForOperation()
        return !operationHadError && error == nil
    }
    func importRule() {
        guard !busy else { return }
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.json]; panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK, let url=panel.url else { return }
        Task {
            do {
                let handle=try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                try await saveRule(handle.read(upToCount: 262_145) ?? Data())
            } catch { self.error=error.localizedDescription }
        }
    }
    func previewRule(_ record: RuleRecord) {
        guard let engine, !busy, let root=configuration.workspaces.first(where: { $0.rootRef == record.rule.scope.rootRef }) else { return }
        workspaceId=root.id
        busy=true; scanning=true; selection=[]; scanProgress=nil
        task=Task {
            defer { busy=false; scanning=false }
            do { snapshot=try await engine.scan(workspaceId: workspaceId, previewRule: record.rule); section="overview"; statusKey="Draft preview only. Enable the rule and rescan before cleanup." }
            catch { self.error=error.localizedDescription }
        }
    }
    func previewRuleDraft(_ data: Data, workspaceId: String, completion: @escaping (Result<(ScanSnapshot, [PersonalRulePreviewRow]), Error>) -> Void) {
        guard let engine else { completion(.failure(ShouError("io_error", "Local store is unavailable."))); return }
        guard !busy else { completion(.failure(ShouError("store_busy", "Another operation is in progress."))); return }
        let rule: CleanupRule
        do { rule=try CleanupRule.parse(data) }
        catch { completion(.failure(error)); return }
        let operation=UUID(); operationID=operation
        busy=true; scanning=true; scanProgress=nil; statusKey="Previewing personal rule…"
        task=Task {
            defer { busy=false; scanning=false; scanProgress=nil }
            do {
                let result=try await engine.scan(workspaceId: workspaceId, previewRule: rule, scope: .cleanup, progress: { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.scanning, self.operationID == operation else { return }
                        self.scanProgress=progress
                    }
                })
                let analysis=Task.detached(priority: .userInitiated) { try PersonalRulePreview.rows(snapshot: result, rule: rule) }
                let rows=try await withTaskCancellationHandler { try await analysis.value } onCancel: { analysis.cancel() }
                try Task.checkCancellation()
                statusKey="Draft preview only. Enable the rule and rescan before cleanup."
                completion(.success((result, rows)))
            } catch {
                statusKey=Task.isCancelled ? "Rule preview stopped." : "Rule preview could not finish."
                completion(.failure(error))
            }
        }
    }
    func exportRule(_ record: RuleRecord) {
        let panel=NSSavePanel(); panel.allowedContentTypes=[.json]; panel.nameFieldStringValue=record.rule.id + ".rule.json"
        guard panel.runModal() == .OK, let url=panel.url else { return }
        do { try Codec.encode(record.rule).write(to: url, options: [.withoutOverwriting]) } catch { self.error=error.localizedDescription }
    }
    func removeWorkspace(_ root: Workspace) {
        guard let engine, !busy else { return }
        busy=true
        Task {
            defer { busy=false }
            do { try await engine.removeWorkspace(root.id); invalidateScanEvidence(); await refresh() }
            catch { self.error=error.localizedDescription }
        }
    }
    func setEnabled(_ record: RuleRecord, enabled: Bool) {
        guard let root=configuration.workspaces.first(where: { $0.rootRef == record.rule.scope.rootRef }) else { return }
        setEnabled(record.rule, enabled: enabled, locationId: root.id)
    }
    func setEnabled(_ rule: CleanupRule, enabled: Bool, locationId: String? = nil) {
        guard let engine, !busy else { return }
        let id=locationId ?? workspaceId
        busy=true
        Task {
            defer { busy=false }
            do { _ = try await engine.setRule(ruleId: rule.id, workspaceId: id, enabled: enabled, version: rule.version); invalidateScanEvidence(); await refresh() }
            catch { self.error=error.localizedDescription }
        }
    }
    func exclude(_ candidate: Candidate) {
        guard engine != nil, !busy else { return }
        let id=workspaceId
        Task {
            do {
                try await saveExclusion(workspaceId: id, pattern: candidate.relativePath + "/**", remove: false)
                if workspaceId == id { startScan() }
            } catch { self.error=error.localizedDescription }
        }
    }
    func saveExclusion(workspaceId: String?, pattern: String, remove: Bool, project: String? = nil) async throws {
        guard let engine else { throw ShouError("io_error", "Local store is unavailable.") }
        guard !busy else { throw ShouError("store_busy", "Another operation is in progress.") }
        busy=true
        defer { busy=false }
        if let workspaceId {
            _ = try await engine.setExclusion(workspaceId: workspaceId, pattern: pattern, remove: remove, project: project)
        } else {
            _ = try await engine.setGlobalExclusion(pattern: pattern, remove: remove)
        }
        invalidateScanEvidence(); await refresh()
    }
    func revealPath(_ path: String) {
        guard let workspace else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspace.path).appendingPathComponent(path)])
    }
    func copyPath(_ path: String) {
        guard let workspace else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(URL(fileURLWithPath: workspace.path).appendingPathComponent(path).path, forType: .string)
    }
    func showInSpaceAnalysis(_ path: String) {
        guard !busy, let workspace else { return }
        section="storage"
        space.location=workspace.path
        space.loadLocations()
        if !space.locations.contains(where: { $0.path == workspace.path }) {
            space.locations.append(StorageLocation(path: workspace.path, name: URL(fileURLWithPath: workspace.path).lastPathComponent, symbol: "folder"))
        }
        if space.scan?.rootPath == workspace.path {
            space.navigate(StorageIndex.parent(path)); space.focus=path
        } else { space.start(app: self) }
    }
    func previewCleanup(permanent: Bool = true) {
        guard let engine, let snapshot, !busy, !selected.isEmpty else { return }
        busy=true; statusKey="Preparing cleanup preview…"
        task=Task {
            defer { busy=false }
            do {
                let action=permanent ? "permanent" : "trash"
                let plan=try await engine.createPlan(scanId: snapshot.id, candidateIds: selected.filter(\.eligible).map(\.id), action: action)
                prompt=ReviewPrompt(id: plan.id, digest: plan.digest, action: action, paths: plan.items.map { plan.workspace.path + "/" + $0.candidate.relativePath }, itemIds: [], byteEstimate: plan.allocatedBytesEstimate,
                    impacts: Array(Set(plan.items.flatMap { $0.candidate.rebuildNotes + $0.candidate.limitations })).sorted())
                statusKey="Ready to review"
            } catch { self.error=error.localizedDescription }
        }
    }
    func review(_ receipt: ExecutionReceipt, items: [ItemReceipt], action: String) {
        guard let engine, !busy, !items.isEmpty else { return }
        busy=true; statusKey="Preparing action preview…"
        task=Task {
            defer { busy=false }
            do {
                let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: items.map(\.id), action: action)
                prompt=ReviewPrompt(id: receipt.id, digest: digest, action: action, paths: items.map(\.originalPath), itemIds: items.map(\.id), byteEstimate: items.reduce(0) { $0 + $1.allocatedBytesEstimate })
                statusKey="Ready to review"
            } catch { self.error=error.localizedDescription }
        }
    }
    func confirm(_ review: ReviewPrompt) {
        guard let engine, !busy else { return }
        prompt=nil; busy=true; scanProgress=nil; isExecuting=true; stopRequested=false; executionProgress=nil; operationHadError=false
        let operation=UUID(); operationID=operation
        task=Task {
            defer { busy=false; isExecuting=false; stopRequested=false }
            do {
                if ["trash", "permanent"].contains(review.action) {
                    let plans=review.plans.isEmpty ? [ReviewedPlan(id: review.id, digest: review.digest, workspacePath: "")] : review.plans
                    var receipts: [ExecutionReceipt]=[], failures: [String]=[]
                    for plan in plans {
                        if Task.isCancelled { failures.append(plan.workspacePath + "\n" + t("Cleanup stopped before this location was processed.")); continue }
                        do { receipts.append(try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "desktop", progress: { [weak self] update in
                            Task { @MainActor in
                                guard let self, self.isExecuting, self.operationID == operation else { return }
                                self.executionProgress=update
                            }
                        })) }
                        catch {
                            if (error as? ShouError)?.code != "cancelled" { operationHadError=true }
                            failures.append(plan.workspacePath + "\n" + error.localizedDescription)
                        }
                    }
                    if receipts.contains(where: { $0.items.contains { ["failed", "unknown", "moving"].contains($0.state) } }) { operationHadError=true }
                    completion=CleanupCompletion(receipts: receipts, failures: failures)
                    commonSelection=[]
                    if receipts.contains(where: { $0.items.contains { $0.state == "trashed" || $0.state == "unknown" } }) { systemResult=nil; commonReview=CleanupReview() }
                    statusKey=failures.isEmpty && receipts.allSatisfy { $0.state == "completed" }
                        ? (review.action == "permanent" ? "Selected items permanently removed." : "Moved to Trash. Available disk space is measured separately.")
                        : "Some items were not moved. Inspect history."
                } else if review.action == "uninstall" {
                    let receipt=try await engine.executeUninstall(planId: review.id, confirmedDigest: review.digest, entryPoint: "desktop", progress: { [weak self] update in
                        Task { @MainActor in
                            guard let self, self.isExecuting, self.operationID == operation else { return }
                            self.executionProgress=update
                        }
                    })
                    if receipt.items.contains(where: { ["failed", "unknown", "moving"].contains($0.state) }) { operationHadError=true }
                    completion=CleanupCompletion(receipts: [receipt])
                    applicationReview=nil; applicationCatalog=nil
                    statusKey=receipt.state == "completed" ? "Application components moved to Trash. Restore them from History." : "Some items were not moved. Inspect history."
                } else {
                    let results=try await engine.followUp(executionId: review.id, itemIds: review.itemIds, action: review.action, confirmedDigest: review.digest, progress: { [weak self] update in
                        Task { @MainActor in
                            guard let self, self.isExecuting, self.operationID == operation else { return }
                            self.executionProgress=update
                        }
                    })
                    if results.contains(where: { $0.state != "completed" }) {
                        operationHadError=true
                        statusKey="Some selected items could not be processed. Inspect history."
                        error=results.compactMap(\.error).joined(separator: "\n")
                    } else if Task.isCancelled && results.count < review.itemIds.count {
                        statusKey="Operation stopped. Review History for remaining items."
                    } else {
                        statusKey=review.action == "restore" ? "Selected items restored." : "Selected items permanently removed."
                    }
                }
                snapshot=nil; selection=[]; section="history"; await refresh()
            } catch { self.error=error.localizedDescription; await refresh() }
        }
    }
    func saveRule(_ data: Data, requireNewVersion: Bool = false) async throws {
        guard let engine else { throw ShouError("io_error", "Local store is unavailable.") }
        guard !busy else { throw ShouError("store_busy", "Another operation is in progress.") }
        busy=true
        defer { busy=false }
        _ = try await engine.importRule(data, requireNewVersion: requireNewVersion)
        invalidateScanEvidence()
        await refresh(); section="rules"
    }
    private func invalidateScanEvidence() {
        snapshot=nil; selection=[]; systemResult=nil; commonReview=CleanupReview(); commonSelection=[]; prompt=nil
        statusKey="Configuration changed; scan again."
    }
    func savePreset(_ name: String) {
        guard let engine else { return }
        let ids=configuration.bindings.filter { $0.workspaceId == workspaceId && $0.enabled && !$0.ruleId.hasPrefix(BuiltinCatalog.prefix) }.map(\.ruleId) + builtins.filter { rule in !configuration.bindings.contains { $0.workspaceId == workspaceId && $0.ruleId == rule.id && !$0.enabled } }.map(\.id)
        Task { do { _ = try await engine.savePreset(name: name, workspaceId: workspaceId, ruleIds: ids); await refresh() } catch { self.error=error.localizedDescription } }
    }
    func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal) }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var inspector=false
    @State private var ruleEditor=false
    private var navigationSelection: Binding<String> {
        Binding(get: { model.section }, set: { section in
            guard ["smart", "overview", "storage", "rules", "startup", "applications", "history", "settings"].contains(section) else { return }
            model.section=section
        })
    }
    var body: some View {
        NavigationSplitView {
            List(selection: navigationSelection) {
                Section(model.displayTitle) {
                    Label(model.t("Smart Cleanup"), systemImage: "sparkle.magnifyingglass").tag("smart")
                    Label(model.t("Space Analysis"), systemImage: "square.grid.2x2").tag("storage")
                    Label(model.t("Rules"), systemImage: "line.3.horizontal.decrease.circle").tag("rules")
                    Label(model.t("Startup Items"), systemImage: "power.circle").tag("startup")
                    Label(model.t("Applications"), systemImage: "square.stack.3d.up").tag("applications")
                    Label(model.t("History"), systemImage: "clock.arrow.circlepath").tag("history")
                }
            }.listStyle(.sidebar)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Button { model.section="settings" } label: {
                        Label(model.t("Settings"), systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                            .background(model.section == "settings" ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityAddTraits(model.section == "settings" ? [.isSelected] : []).padding(10)
                }
                .navigationSplitViewColumnWidth(min: 190, ideal: 215)
        } detail: {
            VStack(spacing: 0) {
                if model.section == "smart" { SmartScanView(model: model) }
                else if model.section == "rules" { RulesView(model: model, editor: $ruleEditor) }
                else if model.section == "startup" { StartupInventoryView(model: model) }
                else if model.section == "applications" { ApplicationsView(model: model) }
                else if model.section == "history" { HistoryView(model: model) }
                else if model.section == "settings" { SettingsView(model: model, updater: model.updater) }
                else if model.section == "storage" { StorageBrowser(model: model, inspector: inspector) }
                else { CleanupView(model: model, inspector: inspector) }
                if model.isExecuting {
                    ExecutionProgressView(title: model.executionTitle,
                        currentPath: model.executionProgress?.path, processedCount: model.executionProgress?.processedCount ?? 0,
                        totalCount: model.executionProgress?.itemCount ?? 0,
                        countText: model.executionProgress.map { String(format: model.t("%lld of %lld items processed"), $0.processedCount, $0.itemCount) } ?? "",
                        stopRequested: model.stopRequested, stopLabel: model.t("Stop"), stoppingLabel: model.t("Stopping at a safe boundary…"), onStop: model.cancel)
                }
                Divider()
                HStack {
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .accessibilityIdentifier("operation.status")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.0").font(.caption.monospaced()).foregroundStyle(.tertiary)
                }.padding(10)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay {
                if model.initializing {
                    ActivityIndicator(title: model.t("Opening local data…")).padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    if model.section == "rules" {
                        Button { model.addWorkspace() } label: { Label(model.t("Include Folder…"), systemImage: "folder.badge.plus") }.disabled(model.busy)
                    }
                    if model.section == "overview" { Button { if model.scanning { model.cancel() } else { model.scanCurrentSection() } } label: {
                        Label(model.t(model.scanning ? "Stop" : "Scan"), systemImage: model.scanning ? "stop.fill" : "arrow.clockwise")
                    }.disabled((model.busy && !model.scanning) || model.workspaceId.isEmpty) }
                    Menu { LanguagePicker(model: model).pickerStyle(.inline) } label: { Label(model.t("Language"), systemImage: "globe") }
                        .help(model.t("Language")).accessibilityLabel(model.t("Language"))
                    if model.section == "overview" || model.section == "storage" || model.section == "eligible" {
                        Button { inspector.toggle() } label: { Label(model.t("Inspector"), systemImage: "sidebar.right") }
                    }
                }
            }
        }
        .sheet(item: $model.prompt) { review in ConfirmationView(model: model, review: review) }
        .sheet(item: $model.completion) { result in CleanupResultView(model: model, result: result) }
        .sheet(item: $model.historyInspection) { request in HistoryInspectionView(model: model, executionId: request.id) }
        .sheet(isPresented: $ruleEditor) { RuleWizard(model: model, initialPattern: model.ruleDraftPattern) }
        .sheet(isPresented: $model.showingExclusions) { ExclusionsView(model: model) }
        .alert(model.t("Unable to complete the operation"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error=nil } })) {
            Button(model.t("OK")) { model.error=nil }
        } message: { Text(model.diagnostic(model.error ?? "")) }
        .environment(\.shouReduceMotion, model.reduceMotion)
        .transaction { transaction in
            if systemReduceMotion || model.reduceMotion {
                transaction.animation=nil
                transaction.disablesAnimations=true
            }
        }
        .onChange(of: model.scanning) { _, _ in
            AccessibilityNotification.Announcement(model.status).post()
        }
        .onChange(of: model.isExecuting) { _, executing in
            if !executing && model.completion == nil && model.error == nil {
                AccessibilityNotification.Announcement(model.status).post()
            }
        }
    }
}

struct CandidateInspector: View {
    var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let candidate=model.snapshot?.candidates.first(where: { $0.relativePath == model.focusedPath }) ?? model.selected.first {
                    Label(model.t("Evidence"), systemImage: "info.circle").font(.headline)
                    Text(candidate.relativePath).font(.callout.monospaced()).textSelection(.enabled)
                    LabeledContent(model.t("Risk"), value: model.t(candidate.risk))
                    LabeledContent(model.t("Logical size"), value: model.bytes(candidate.logicalBytes))
                    LabeledContent(model.t("Newest modification"), value: model.date(candidate.newestModifiedAt))
                    Divider()
                    ForEach(candidate.ruleIds, id: \.self) { Text($0).font(.caption.monospaced()) }
                    ForEach(candidate.reasons, id: \.self) { Label(model.t($0), systemImage: "exclamationmark.circle").font(.caption) }
                    ForEach(candidate.rebuildNotes, id: \.self) { Text(model.t($0)).font(.callout) }
                    ForEach(candidate.limitations, id: \.self) { Text("• " + model.t($0)).font(.caption).foregroundStyle(.secondary) }
                    Text(model.t("Directory names, sizes, and lockfiles do not prove data can be rebuilt.")).font(.caption).foregroundStyle(.secondary)
                } else { Text(model.t("Select a directory to inspect matching evidence and rebuild requirements.")).foregroundStyle(.secondary) }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RulesView: View {
    @Bindable var model: AppModel
    @Binding var editor: Bool
    @State private var presetName=""
    @State private var presetAlert=false
    @State private var editingRule: RuleRecord?
    @State private var ruleSource="all"
    @State private var agentSetup=false
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.t("Rules")).font(.largeTitle)
                    Text(model.t("Built-in rules for everyday cleanup. Your agent tailors the rest to your Mac.")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.t("Exclusions…")) { model.showingExclusions=true }.disabled(model.busy)
                Menu(model.t("Advanced")) {
                    Button(model.t("Import…")) { model.importRule() }
                    Button(model.t("New Rule…")) { model.ruleDraftPattern=""; editor=true }.disabled(model.workspace == nil)
                }.disabled(model.busy).fixedSize()
            }.padding(24)
            HStack(spacing: 14) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t("Cleanup rules made for your Mac")).font(.headline)
                    Text(model.t("Tell your coding agent what to clean. It asks the right questions and writes the rules for you."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Button(model.t("Customize with AI…")) { agentSetup=true }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("rules.agent.setup")
            }
            .padding(18).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24).padding(.bottom, 12)
            HStack {
                if !model.configuration.workspaces.isEmpty {
                    Picker(model.t("Workspace"), selection: $model.workspaceId) {
                        ForEach(model.configuration.workspaces) { root in
                            Text(model.knownLocations.first { $0.path == root.path }.map { model.t($0.title) } ?? URL(fileURLWithPath: root.path).lastPathComponent).tag(root.id)
                        }
                    }.frame(maxWidth: 320).disabled(model.busy)
                }
                Spacer()
                Menu(model.t("Saved Rule Selections")) {
                    Button(model.t("Save Enabled Rules…")) { presetAlert=true }.disabled(model.workspace == nil)
                    if !model.configuration.presets.isEmpty { Divider() }
                    ForEach(model.configuration.presets) { preset in
                        Button(preset.name) { model.section="overview"; model.startScan(preset: preset) }
                    }
                }.fixedSize().disabled(model.busy)
            }.padding(.horizontal, 24).padding(.bottom, 10)
            Picker(model.t("Rule Source"), selection: $ruleSource) {
                Text(model.t("All Rules")).tag("all")
                Text(model.t("Built-in Rules")).tag("builtin")
                Text(model.t("Personal Rules")).tag("personal")
            }.pickerStyle(.segmented).frame(maxWidth: 440).padding(.horizontal, 24).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if ruleSource != "personal" {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.t("Built-in Rules")).font(.headline)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(model.builtins) { rule in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Toggle(model.t(rule.name), isOn: Binding(get: { !model.configuration.bindings.contains { $0.workspaceId == model.workspaceId && $0.ruleId == rule.id && !$0.enabled } }, set: { model.setEnabled(rule, enabled: $0) })).toggleStyle(.switch).disabled(model.busy)
                                        Text(model.t(rule.risk.rebuildNote)).font(.callout).foregroundStyle(.secondary)
                                        Text(model.t(rule.risk.limitations.first ?? "")).font(.caption).foregroundStyle(.secondary)
                                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    if rule.id != model.builtins.last?.id { Divider() }
                                }
                            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    if ruleSource != "builtin" {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.t("Personal Rules")).font(.headline)
                            if model.configuration.rules.isEmpty {
                                Text(model.t("Ask your agent to create a rule for your build outputs and caches. Imported drafts appear here."))
                                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(model.configuration.rules) { record in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Label(record.rule.name, systemImage: "doc.text").font(.headline); Spacer()
                                            let root=model.configuration.workspaces.first { $0.rootRef == record.rule.scope.rootRef }
                                            let enabled=model.configuration.bindings.contains { $0.workspaceId == root?.id && $0.ruleId == record.rule.id && $0.version == record.rule.version && $0.enabled }
                                            Toggle(model.t("Enabled"), isOn: Binding(get: { enabled }, set: { model.setEnabled(record, enabled: $0) })).toggleStyle(.switch).disabled(root == nil || model.busy)
                                        }
                                        Text(record.rule.description).font(.callout).foregroundStyle(.secondary)
                                        Text(record.rule.id + " · " + record.rule.version + " · " + record.rule.scope.rootRef).font(.caption.monospaced()).foregroundStyle(.tertiary)
                                        Text(record.rule.risk.rebuildNote).font(.caption)
                                        HStack {
                                            Button(model.t("Edit Rule…")) { editingRule=record }.disabled(model.busy)
                                                .buttonStyle(.bordered)
                                                .accessibilityIdentifier("rules.edit." + record.id)
                                            Button(model.t("Preview Draft")) { model.previewRule(record) }.disabled(model.busy || !model.configuration.workspaces.contains { $0.rootRef == record.rule.scope.rootRef })
                                                .buttonStyle(.bordered)
                                                .accessibilityIdentifier("rules.preview." + record.rule.id)
                                            Button(model.t("Export Rule…")) { model.exportRule(record) }
                                                .buttonStyle(.bordered)
                                                .accessibilityIdentifier("rules.export." + record.rule.id)
                                        }
                                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    if record.id != model.configuration.rules.last?.id { Divider() }
                                }
                            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .sheet(item: $editingRule) { RuleRevisionEditor(model: model, original: $0) }
        .sheet(isPresented: $agentSetup, onDismiss: { Task { await model.refresh() } }) { AgentRuleSetupView(model: model) }
        .onAppear { Task { await model.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !model.busy { Task { await model.refresh() } }
        }
        .onChange(of: model.workspaceId) { _, _ in model.snapshot=nil; model.selection=[]; Task { await model.refresh() } }
        .alert(model.t("Save Preset"), isPresented: $presetAlert) {
            TextField(model.t("Name"), text: $presetName)
            Button(model.t("Save")) { model.savePreset(presetName); presetName="" }.disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(model.t("Cancel"), role: .cancel) {}
        }
    }
}

struct ConfirmationView: View {
    var model: AppModel
    let review: ReviewPrompt
    @Environment(\.dismiss) private var dismiss
    private var title: String {
        ["purge", "permanent"].contains(review.action) ? model.t("Permanently remove these items?") : review.action == "restore" ? model.t("Restore these items?") : model.t("Move these items to Trash?")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: ["purge", "permanent"].contains(review.action) ? "exclamationmark.triangle" : "trash").font(.title2.bold())
            Text(["purge", "permanent"].contains(review.action) ? model.t("This is irreversible. Only the selected items from this cleanup batch will be removed.") : model.t("Check every path. Files and configuration will be verified again immediately before processing.")).foregroundStyle(.secondary)
            List(review.paths, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }.frame(minHeight: 160, maxHeight: 300)
            if !review.impacts.isEmpty {
                DisclosureGroup(model.t("Cleanup Impact")) {
                    ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(review.impacts, id: \.self) { Text(model.t($0)).font(.caption).foregroundStyle(.secondary) } } }.frame(maxHeight: 140)
                }
            }
            Text(model.bytes(review.byteEstimate) + " · " + String(review.paths.count) + model.t(" items")).monospacedDigit()
            DisclosureGroup(model.t("Verification Details")) {
                ForEach(review.plans.isEmpty ? [ReviewedPlan(id: review.id, digest: review.digest, workspacePath: "")] : review.plans, id: \.id) { plan in
                    Text(plan.id + "\n" + plan.digest).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            HStack { Spacer(); Button(model.t("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction); Button(model.t("Confirm"), role: ["restore", "trash"].contains(review.action) ? nil : .destructive) { model.confirm(review) }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 650)
    }
}

struct LanguagePicker: View {
    @Bindable var model: AppModel
    var body: some View {
        Picker(model.t("Language"), selection: $model.language) {
            ForEach(AppLanguage.allCases, id: \.self) { language in Text(language.title).tag(language) }
        }
    }
}
