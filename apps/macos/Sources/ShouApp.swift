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
        WindowGroup(model.displayTitle, id: "workspace") {
            ContentView(model: model)
                .environment(\.locale, model.language.locale)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .tint(ShouDesign.accent)
                .accentColor(ShouDesign.accent)
                .frame(minWidth: 960, minHeight: 600)
                .background(OperationWindowGuard(model: model))
                .task { applicationDelegate.model=model; await model.initialize() }
        }
        .defaultSize(width: ShouDesign.windowWidth, height: ShouDesign.windowHeight)
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
    var manualReview=false
}

struct ReviewedPlan {
    let id: String
    let digest: String
    let workspacePath: String
    var directRemoval=false
}

struct CleanupCompletion: Identifiable {
    let id=UUID()
    let receipts: [ExecutionReceipt]
    var failures: [String]=[]
    var skippedItems: [ItemReceipt]=[]
    /// The page that created this result. A retry returns the user directly
    /// to the relevant scan instead of making them navigate through history.
    var sourceSection: String = "smart"
    var retryPaths: Set<String> = []
    var retryWorkspaces: [Workspace] = []
    var retryApplicationPaths: Set<String> = []
    var retryOrphans=false
}

@MainActor @Observable final class AppModel {
    let updater=AppUpdater()
    let scanAccess=ScanAccessController()
    var configuration=Configuration()
    var workspaceId=""
    var section="smart"
    var knownLocations: [KnownLocation]=[]
    var projectLocations: [KnownLocation]=[]
    var systemResult: SystemScanResult?
    var commonReview=CleanupReview()
    var commonSelection=Set<String>()
    private var commonRefinements: [CleanupTargetRefinement]=[]
    var scanningCleanupPath: String?
    var cleanupScanScope=CleanupScanScope.standard
    var scanTitle="Scanning cleanup locations…"
    var showingCleanupVolumes=false
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
    var ai=AIWorkspaceSession()
    var largeFiles=LargeFilesSession()
    var applicationsSession=ApplicationsSession()
    var packageUpdates=PackageUpdatesSession()
    var developerTools=DeveloperToolsSession()
    var showApplicationOrphans=false
    var orphanRetryPaths=Set<String>()
    var privacySession=PrivacySession()
    let monitor=SystemMonitorSession(source:NativeSystemMonitor())
    @ObservationIgnored var monitorStatusItem: MonitorStatusItem?
    @ObservationIgnored var openMainWindow: (() -> Void)?
    func openSystemMonitor() {
        guard !busy else { return }
        section="monitor"
        if let window=NSApp.windows.first(where:{ $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
            monitor.setVisible(true)
        } else {
            openMainWindow?()
        }
        NSApp.activate(ignoringOtherApps:true)
    }
    var browsingPath="."
    var focusedPath: String?
    var ruleDraftPattern=""
    var builtins: [CleanupRule]=[]
    var builtinTemplates: [BuiltinTemplate]=[]
    var scanProgress: ScanProgress?
    var scanEntryCount: Int { scanProgress?.entryCount ?? 0 }
    var selection=Set<String>()
    var history: [ExecutionReceipt]=[]
    var historyNextOffset: Int?
    var historyLoading=false
    var followups: [FollowUpReceipt]=[]
    var startupInventory: StartupInventory?
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
    private(set) var executionAction="permanent"
    private var executionOperation=UUID()
    var error: String? { didSet { accessRecovery=nil } }
    var accessRecovery: SystemAccessRequirement?
    func presentFailure(_ failure: Error) {
        error=failure.localizedDescription
        accessRecovery=(failure as? ShouError)?.accessRequirement
    }
    var statusKey=""
    var prompt: ReviewPrompt?
    var completion: CleanupCompletion?
    var toolCompletion: ToolCleanupReceipt?
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
    var externalRulesChanged=false
    var reviewPersonalRules=false
    private var refreshingExternalChanges=false
    private var initializationStarted=false
    func initialize() async {
        guard !initializationStarted else { return }
        initializationStarted=true; busy=true
        defer { initializing=false; busy=false }
        let readWorker=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shou")
        do {
            engine=try await Task.detached(priority: .userInitiated) {
                ShouEngine(store: try LocalRecordStore(), filesystem: NativeFileSystem(readWorkerExecutable: readWorker), applicationActivity: NativeApplicationActivity(), artifactEvidence: NativeArtifactEvidence(), applicationCatalog: NativeApplicationCatalog(), uninstallEvidence: NativeApplicationUninstallEvidence(readWorkerExecutable: readWorker), cleanupLocations: NativeCleanupLocations())
            }.value
            await refresh()
            await scanAccess.initialize()
        }
        catch { engine=nil; self.presentFailure(error) }
    }
    func t(_ key: String) -> String { L10n.string(key, locale: language.rawValue) }
    func diagnostic(_ message: String) -> String { message.components(separatedBy: "\n").map(t).joined(separator: "\n") }
    var displayTitle: String { language == .simplifiedChinese ? "Shou 收拾一下" : "Shou" }
    var status: String {
        if isExecuting { return stopRequested ? t("Stopping at a safe boundary…") : executionTitle }
        if space.scanning { return t(space.progressTitle) }
        if scanning, let progress=scanProgress {
            if progress.stage == "preparing" { return t("Preparing common app scan…") }
            let key=progress.stage == "scanning" ? "Scanning: %lld entries" : progress.stage == "analysis" ? "Analyzing %lld entries…" : "Saving %lld entries…"
            return String(format: t(key), locale: language.locale, progress.entryCount)
        }
        return t(statusKey)
    }
    var executionTitle: String {
        if developerTools.executing || developerTools.configuration.mutating { return t("Managing developer tools…") }
        if packageUpdates.executing { return t("Updating software…") }
        if ["preparing", "checking"].contains(executionProgress?.stage ?? "") { return t("Checking selected files…") }
        return switch executionAction {
        case "trash": t("Moving items to Trash…")
        case "restore": t("Restoring selected items…")
        case "privacy": t("Cleaning browser privacy…")
        case "tool": t("Cleaning tool-managed storage…")
        default: t("Permanently removing selected items…")
        }
    }
    func beginExecution(total: Int, action: String = "permanent", stage: String = "preflight") -> UUID {
        executionOperation=UUID(); isExecuting=true; stopRequested=false; operationHadError=false
        executionAction=action
        executionProgress=ExecutionProgress(stage: stage, processedCount: 0, itemCount: total)
        return executionOperation
    }
    func updateExecutionProgress(_ update: ExecutionProgress, operation: UUID) {
        guard isExecuting, executionOperation == operation else { return }
        if let current=executionProgress, !update.canFollow(current) { return }
        executionProgress=update
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
            builtinTemplates=try BuiltinCatalog.templates().filter { $0.supportedPlatforms.contains(KnownLocations.currentPlatform) }
            configuration=try await engine.configuration()
            if !configuration.workspaces.contains(where: { $0.id == workspaceId }) { workspaceId=configuration.workspaces.first?.id ?? "" }
            let page=try await engine.historySummaries(limit: 50)
            history=page.receipts; historyNextOffset=page.nextOffset
            followups=try await engine.followUps()
            builtins=workspaceId.isEmpty ? [] : try await engine.builtinRules(workspaceId: workspaceId)
            knownLocations=try await engine.knownLocations()
        } catch { if !Task.isCancelled { self.presentFailure(error) } }
    }
    func refreshProjectLocations() async {
        guard let engine else { return }
        do {
            let locations=try await engine.projectLocations()
            try Task.checkCancellation()
            projectLocations=locations
        } catch { if !Task.isCancelled { self.presentFailure(error) } }
    }
    func refreshExternalChanges() async {
        guard let engine, !busy, !initializing, !refreshingExternalChanges else { return }
        refreshingExternalChanges=true
        defer { refreshingExternalChanges=false }
        do {
            let latest=try await engine.configuration()
            guard latest.revision != configuration.revision else { return }
            let changed=try Digest.of(latest.rules) != Digest.of(configuration.rules) || Digest.of(latest.bindings) != Digest.of(configuration.bindings)
            invalidateScanEvidence()
            await refresh()
            externalRulesChanged=externalRulesChanged || changed
        } catch { if !Task.isCancelled { self.presentFailure(error) } }
    }
    func loadMoreHistory() {
        guard let engine, let offset=historyNextOffset, !historyLoading else { return }
        historyLoading=true
        Task {
            defer { historyLoading=false }
            do {
                let page=try await engine.historySummaries(offset: offset, limit: 50)
                let existing=Set(history.map(\.id))
                history.append(contentsOf: page.receipts.filter { !existing.contains($0.id) }); historyNextOffset=page.nextOffset
            } catch { self.presentFailure(error) }
        }
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
            } catch { invalidateScanEvidence(); busy=false; await refresh(); self.presentFailure(error) }
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
            } catch { self.presentFailure(error) }
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
    func startScan(preset: Preset? = nil, focusAfterScan: String? = nil, ruleIds: [String] = [], selectEligible: Bool = false, accessChecked: Bool = false) {
        guard let engine, !workspaceId.isEmpty, !busy else { return }
        if !accessChecked {
            scanAccess.prepareScan { [weak self] in self?.startScan(preset: preset, focusAfterScan: focusAfterScan, ruleIds: ruleIds, selectEligible: selectEligible, accessChecked: true) }
            return
        }
        busy=true; scanning=true; selection=[]; scanProgress=nil; statusKey="Scanning selected workspace…"
        let id=preset?.workspaceId ?? workspaceId
        scanTitle="Scanning selected folder…"; scanningLocation=nil; scanningCleanupPath=configuration.workspaces.first { $0.id == id }?.path
        let operation=UUID(); operationID=operation
        task=Task {
            defer { busy=false; scanning=false; scanningCleanupPath=nil }
            do {
                snapshot=try await engine.scan(workspaceId: id, ruleIds: preset?.ruleIds ?? ruleIds, scope: section == "storage" ? .full : .cleanup, budget: ScanBudget(maxEntries: 500_000, maxSeconds: 180), progress: { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.scanning, self.operationID == operation else { return }
                        self.updateScanProgress(update)
                    }
                })
                workspaceId=id
                if selectEligible { selection=Set(reviewable.filter(\.eligible).map(\.id)) }
                if let path=focusAfterScan {
                    browsingPath=StorageIndex.parent(path); focusedPath=path
                }
                statusKey=snapshot?.status == "complete" ? "Scan complete. Review candidates before cleanup." : "Some paths could not be fully scanned. Only independently verified items can be reviewed for cleanup."
            } catch { if !Task.isCancelled { self.presentFailure(error) }; statusKey="Scan stopped." }
        }
    }
    func scanCurrentSection() {
        if section == "smart" || section == "projects" { scanCommonLocations() }
        else if section == "storage" { space.start(app: self, retainPath: true) }
        else if section == "large-files" { largeFiles.storage.start(app: self) }
        else if section == "startup" { scanStartup() }
        else if section == "applications" { scanApplications() }
        else if section == "privacy" { privacySession.scan(app: self) }
        else if section == "overview" { startScan() }
        else { section="smart"; scanCommonLocations() }
    }
    func scanStartup() {
        guard !busy else { return }
        busy=true; startupLoading=true; stopRequested=false
        statusKey="Reading startup definitions…"
        let options=StartupInventoryOptions(includeSystem: startupIncludeSystem)
        task=Task {
            defer { busy=false; startupLoading=false }
            do {
                startupInventory=try await startupService.scan(options: options)
                statusKey=startupInventory?.status == "complete" ? "Startup definitions checked. Review coverage before drawing conclusions." : "Some startup definitions could not be inspected."
            } catch {
                if Task.isCancelled { statusKey="Startup scan stopped." }
                else { statusKey="Startup discovery unavailable."; self.presentFailure(error) }
            }
        }
    }
    func controlStartup(_ definition: StartupDefinition, action: StartupControlAction) {
        controlStartup([definition], action: action)
    }
    func controlStartup(_ definitions: [StartupDefinition], action: StartupControlAction) {
        guard !busy else { return }
        guard !definitions.isEmpty, let inventory=startupInventory,
              definitions.allSatisfy({ inventory.items.contains($0) }) else {
            error=t("Startup items changed. Scan again before continuing.")
            return
        }
        busy=true; startupControlLoading=true; stopRequested=false; error=nil
        task=Task {
            var failures: [String]=[]
            for definition in definitions {
                if Task.isCancelled { break }
                do {
                    startupControlResult=try await startupControlService.apply(definition: definition, action: action)
                } catch {
                    failures.append(definition.label + ": " + error.localizedDescription)
                }
            }
            busy=false; startupControlLoading=false
            if !failures.isEmpty { self.error=failures.joined(separator: "\n") }
            // Read back the catalog even after a partial failure; the previous
            // snapshot can no longer describe the whole reviewed selection.
            scanStartup()
        }
    }
    func scanApplications() {
        applicationsSession.scan(app: self)
    }
    func scanCommonLocations(scope: CleanupScanScope? = nil, accessChecked: Bool = false) {
        guard let engine, !busy else { return }
        let scope=scope ?? cleanupScanScope
        if !accessChecked {
            scanAccess.prepareScan { [weak self] in self?.scanCommonLocations(scope: scope, accessChecked: true) }
            return
        }
        busy=true; scanning=true; stopRequested=false; scanProgress=nil; scanningLocation=nil; systemResult=nil; commonReview=CleanupReview(); commonSelection=[]; commonRefinements=[]
        statusKey="Preparing common app scan…"
        cleanupScanScope=scope; scanningCleanupPath=nil
        switch scope {
        case .standard: scanTitle="Scanning cleanup locations…"
        case .folders: scanTitle="Scanning selected folders…"
        case .volumes: scanTitle="Scanning selected disks…"
        }
        let operation=UUID(); operationID=operation
        task=Task {
            defer { busy=false; scanning=false; scanningLocation=nil }
            do {
                let result=try await engine.scanKnownLocations(includeProjects: true, scope: scope, progress: { [weak self] location, progress in
                    Task { @MainActor in
                        guard let self, self.scanning, self.operationID == operation else { return }
                        guard self.updateScanProgress(progress) else { return }
                        self.scanningLocation=location
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
            } catch {
                if !Task.isCancelled { self.presentFailure(error) }
                statusKey="Scan stopped."; await refresh()
            }
        }
    }
    func chooseCleanupFolders() {
        guard !busy else { return }
        let panel=NSOpenPanel(); panel.canChooseFiles=false; panel.canChooseDirectories=true; panel.allowsMultipleSelection=true
        panel.message=t("Choose folders to scan.")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do { scanCommonLocations(scope: .folders(try panel.urls.map { try NativeDirectorySelection.path(for: $0) })) }
        catch { presentFailure(error) }
    }
    @discardableResult private func updateScanProgress(_ update: ScanProgress) -> Bool {
        if let current=scanProgress {
            guard update.entryCount >= current.entryCount else { return false }
            if let previous=current.fractionCompleted {
                guard let next=update.fractionCompleted, next >= previous else { return false }
            }
        }
        scanProgress=update
        return true
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
    func continueCleanupScan(_ source: CleanupSource) {
        guard let engine, !busy, let previous=systemResult,
              source.candidate.reasons.contains("incomplete_scan"),
              commonReview.sources.contains(where: { $0.id == source.id }) else { return }
        let selected=commonSelection
        let refinements=commonRefinements
        let operation=UUID(); operationID=operation
        busy=true; scanning=true; stopRequested=false; scanProgress=nil; scanningLocation=nil; scanningCleanupPath=source.path
        statusKey="Scanning this directory…"
        scanTitle="Scanning this directory…"
        task=Task {
            defer { busy=false; scanning=false; scanningCleanupPath=nil }
            do {
                let updated=try await engine.scanCleanupTarget(scanId: source.snapshotId, candidateId: source.candidate.id, progress: { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.scanning, self.operationID == operation else { return }
                        self.updateScanProgress(progress)
                    }
                })
                try Task.checkCancellation()
                let snapshots=previous.snapshots + [updated]
                let replacements=refinements + [CleanupTargetRefinement(originalSnapshotId: source.snapshotId, candidateId: source.candidate.id, snapshotId: updated.id)]
                let review=try await Task.detached(priority: .userInitiated) {
                    try CleanupReview(snapshots: snapshots, locations: previous.locations, refinements: replacements)
                }.value
                try Task.checkCancellation()
                commonReview=review
                commonRefinements=replacements
                systemResult=SystemScanResult(locations: previous.locations, snapshots: snapshots, issues: previous.issues, skippedLocationIds: previous.skippedLocationIds)
                // New evidence always requires a fresh selection; unrelated choices keep their original IDs.
                commonSelection=selected.intersection(Set(review.sources.filter(\.selectable).map(\.id)))
                statusKey=review.sources.contains { $0.snapshotId == updated.id && $0.candidate.reasons.contains("incomplete_scan") }
                    ? "This directory still exceeds the scan limit." : "Directory scanned. Review it before selecting."
            } catch {
                if !Task.isCancelled { self.presentFailure(error) }
                statusKey=Task.isCancelled ? "Scan stopped." : "Directory scan failed. Previous results were kept."
            }
        }
    }
    func executeCommonCleanup(permanent: Bool = true, sourceIds: Set<String>? = nil) {
        guard !busy, let engine else { return }
        let sources=commonSelected.filter { sourceIds?.contains($0.id) ?? true }
        guard !sources.isEmpty else { return }
        let action=permanent ? "permanent" : "trash", sourceSection=section
        let roots=systemResult?.snapshots.map(\.workspace) ?? []
        busy=true; scanProgress=nil
        statusKey=permanent ? "Permanently removing…" : "Moving to Trash…"
        let operation=beginExecution(total: sources.count, action: action, stage: permanent ? "purging" : "moving")
        task=Task {
            defer { busy=false; isExecuting=false; stopRequested=false }
            var receipts=[ExecutionReceipt](), failures=[String](), handled=Set<String>()
            for (position, source) in sources.enumerated() {
                if Task.isCancelled { break }
                handled.insert(source.path)
                do {
                    let progress: @Sendable (ExecutionProgress) -> Void = { [weak self] update in
                        Task { @MainActor in
                            self?.updateExecutionProgress(update.inBatch(processedBefore: position, itemCount: sources.count), operation: operation)
                        }
                    }
                    let receipt: ExecutionReceipt
                    if source.requiresManualReview {
                        let plan=try await engine.createReviewedCleanupRemovalPlan(scanId: source.snapshotId, candidateIds: [source.candidate.id], action: action)
                        try Task.checkCancellation()
                        receipt=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "desktop-manual-review", progress: progress)
                    } else {
                        let plan=try await engine.createPlan(scanId: source.snapshotId, candidateIds: [source.candidate.id], action: action)
                        try Task.checkCancellation()
                        receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "desktop", progress: progress)
                    }
                    receipts.append(receipt)
                    if receipt.state == "cancelled" || receipt.items.contains(where: { $0.state == "unknown" }) { break }
                } catch {
                    failures.append(source.path + "\n" + error.localizedDescription)
                    if Task.isCancelled || ["store_corrupt", "journal_failed", "authorization_channel_lost"].contains((error as? ShouError)?.code ?? "") { break }
                }
            }
            let succeeded=Set(receipts.flatMap(\.items).filter { ["purged", "trashed"].contains($0.state) }.map(\.originalPath))
            let remaining=Set(sources.map(\.path)).subtracting(succeeded)
            operationHadError = !failures.isEmpty || receipts.contains { $0.state != "completed" }
            let notStarted=sources.filter { !handled.contains($0.path) }.map {
                ItemReceipt.skipped(path: $0.path, relativePath: $0.candidate.relativePath, reason: t("Cleanup stopped before this location was processed."))
            }
            completion=CleanupCompletion(receipts: receipts, failures: failures, skippedItems: notStarted, sourceSection: sourceSection, retryPaths: remaining,
                retryWorkspaces: roots.filter { root in remaining.contains { $0.hasPrefix(root.path + "/") } })
            snapshot=nil; selection=[]; systemResult=nil; commonReview=CleanupReview(); commonSelection=[]
            statusKey=remaining.isEmpty ? (permanent ? "Selected items permanently removed." : "Moved to Trash. Available disk space is measured separately.") : "Some items could not be removed. Review the result."
            await refresh()
        }
    }
    func cancel() { if busy { stopRequested=true }; task?.cancel(); space.stop(); ai.stop(); largeFiles.stop(); applicationsSession.stop(); packageUpdates.stop(); developerTools.stop(); privacySession.cancel() }
    func stopAndWaitForExecution() async -> Bool {
        guard isExecuting else { return !operationHadError && error == nil }
        let running=task
        cancel()
        await running?.value
        await space.waitForOperation()
        await largeFiles.waitForOperation()
        await applicationsSession.waitForOperation()
        await packageUpdates.waitForOperation()
        await developerTools.waitForOperation()
        await privacySession.waitForOperation()
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
            } catch { self.presentFailure(error) }
        }
    }
    func enableAndScanRule(_ record: RuleRecord, preview: ScanSnapshot) {
        guard let engine, !busy else { return }
        busy=true
        Task {
            do {
                let latest=try await engine.configuration()
                guard preview.previewOnly, preview.configurationDigest == (try Digest.of(latest)),
                      latest.rules.contains(where: { $0.id == record.id && $0.digest == record.digest }),
                      preview.workspace.rootRef == record.rule.scope.rootRef else {
                    throw ShouError("plan_stale", "Preview the draft again with the current configuration.")
                }
                _ = try await engine.setRule(ruleId: record.rule.id, workspaceId: preview.workspace.id, enabled: true, version: record.rule.version)
                invalidateScanEvidence(); await refresh()
                workspaceId=preview.workspace.id; section="overview"; externalRulesChanged=false; busy=false
                startScan(ruleIds: [record.rule.id], selectEligible: true)
            } catch { busy=false; self.presentFailure(error) }
        }
    }
    func previewBenefits(scanId: String) async throws -> RulePreviewBenefits {
        guard let engine else { throw ShouError("io_error", "Local store is unavailable.") }
        return try await engine.rulePreviewBenefits(scanId: scanId)
    }
    func previewRuleDraft(_ data: Data, workspaceId: String, completion: @escaping (Result<(ScanSnapshot, [PersonalRulePreviewRow]), Error>) -> Void) {
        guard let engine else { completion(.failure(ShouError("io_error", "Local store is unavailable."))); return }
        guard !busy else { completion(.failure(ShouError("store_busy", "Another operation is in progress."))); return }
        let rule: CleanupRule
        do { rule=try CleanupRule.parse(data) }
        catch { completion(.failure(error)); return }
        let operation=UUID(); operationID=operation
        busy=true; scanning=true; scanProgress=nil; statusKey="Previewing personal rule…"
        scanTitle="Previewing personal rule…"; scanningLocation=nil; scanningCleanupPath=configuration.workspaces.first { $0.id == workspaceId }?.path
        task=Task {
            defer { busy=false; scanning=false; scanProgress=nil }
            do {
                let result=try await engine.scan(workspaceId: workspaceId, previewRule: rule, scope: .cleanup, progress: { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.scanning, self.operationID == operation else { return }
                        self.updateScanProgress(progress)
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
        do { try Codec.encode(record.rule).write(to: url, options: [.withoutOverwriting]) } catch { self.presentFailure(error) }
    }
    func removeWorkspace(_ root: Workspace) {
        guard let engine, !busy else { return }
        busy=true
        Task {
            defer { busy=false }
            do { try await engine.removeWorkspace(root.id); invalidateScanEvidence(); await refresh() }
            catch { self.presentFailure(error) }
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
            catch { self.presentFailure(error) }
        }
    }
    func exclude(_ candidate: Candidate) {
        guard engine != nil, !busy else { return }
        let id=workspaceId
        Task {
            do {
                try await saveExclusion(workspaceId: id, pattern: candidate.relativePath + "/**", remove: false)
                if workspaceId == id { startScan() }
            } catch { self.presentFailure(error) }
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
    func executeCleanup(permanent: Bool = true) {
        guard let engine, let snapshot, !busy, !selected.isEmpty, selected.allSatisfy(\.eligible), !snapshot.previewOnly else { return }
        let candidateIds=selected.map(\.id), action=permanent ? "permanent" : "trash"
        startReviewedExecution(total: candidateIds.count, action: action) {
            let plan=try await engine.createPlan(scanId: snapshot.id, candidateIds: candidateIds, action: action)
            return ReviewPrompt(id: plan.id, digest: plan.digest, action: action,
                paths: plan.items.map { plan.workspace.path + "/" + $0.candidate.relativePath }, itemIds: [], byteEstimate: plan.allocatedBytesEstimate)
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
            } catch { self.presentFailure(error) }
        }
    }
    func retryAfterCleanup(_ result: CleanupCompletion) {
        guard !busy else { return }
        completion=nil
        section=result.sourceSection
        if result.retryOrphans {
            orphanRetryPaths=result.retryPaths; showApplicationOrphans=true; return
        }
        if !result.retryApplicationPaths.isEmpty {
            applicationsSession.retry(paths: result.retryApplicationPaths, app: self); return
        }
        if result.sourceSection == "smart", !result.retryWorkspaces.isEmpty {
            refreshCommonWorkspaces(result.retryWorkspaces, selectedPaths: result.retryPaths)
            return
        }
        statusKey="Scan again to refresh changed items."
        scanCurrentSection()
    }
    func refreshCommonWorkspaces(_ roots: [Workspace], selectedPaths: Set<String>) {
        guard let engine, !busy else { return }
        busy=true; scanning=true; scanProgress=nil
        stopRequested=false; scanningLocation=nil; scanningCleanupPath=nil; scanTitle="Refreshing affected cleanup locations…"
        let operation=UUID(); operationID=operation
        let previous=systemResult
        task=Task {
            defer { busy=false; scanning=false; scanningCleanupPath=nil }
            do { try await updateScopedCleanup(engine: engine, roots: roots, selectedPaths: selectedPaths, previous: previous) }
            catch { if !Task.isCancelled { self.presentFailure(error) } }
        }
    }
    private func updateScopedCleanup(engine: ShouEngine, roots: [Workspace], selectedPaths: Set<String>, previous: SystemScanResult?) async throws {
        guard !roots.isEmpty else { return }
        var snapshots=previous?.snapshots.filter { old in !roots.contains { $0.id == old.workspace.id } } ?? []
        let operation=operationID
        let updated=try await engine.scanKnownLocations(scope: .folders(Array(Set(roots.map(\.path))).sorted()), progress: { [weak self] location, update in
                Task { @MainActor in
                    guard let self, self.scanning, self.operationID == operation else { return }
                    guard self.updateScanProgress(update) else { return }
                    self.scanningLocation=location
                }
            })
        snapshots += updated.snapshots
        let previousLocations=previous?.locations ?? knownLocations
        let affectedLocations=Set(previousLocations.filter { location in roots.contains { $0.path == location.path } }.map(\.id))
        let locations=previousLocations.filter { location in !roots.contains { $0.path == location.path } } + updated.locations
        let issues=(previous?.issues ?? []).filter { !affectedLocations.contains($0.locationId) } + updated.issues
        let refreshed=SystemScanResult(locations: locations, snapshots: snapshots, issues: issues, skippedLocationIds: previous?.skippedLocationIds ?? [])
        let retained=Set(snapshots.map(\.id))
        let refinements=commonRefinements.filter { retained.contains($0.originalSnapshotId) && retained.contains($0.snapshotId) }
        commonReview=try CleanupReview(snapshots: snapshots, locations: refreshed.locations, refinements: refinements)
        commonRefinements=refinements
        systemResult=refreshed
        commonSelection=Set(commonReview.sources.filter { $0.selectable && selectedPaths.contains($0.path) }.map(\.id))
        statusKey="Affected items refreshed. Review your selection to continue."
    }
    func closeCleanupApplications(_ plan: ApplicationClosePlan) {
        guard let engine, !busy, let result=systemResult else { return }
        let identifiers=Set(plan.applications.compactMap(\.bundleIdentifier))
        let affected=commonReview.categories.flatMap(\.groups).filter { !identifiers.isDisjoint(with: $0.applicationBundleIdentifiers) }.flatMap(\.sources)
        let selectedPaths=Set(commonSelected.map(\.path))
        let rootIDs=Set(affected.map { $0.workspace.id })
        let roots=result.snapshots.map(\.workspace).filter { rootIDs.contains($0.id) }
        busy=true
        task=Task {
            defer { busy=false; scanning=false; scanningLocation=nil; scanningCleanupPath=nil; stopRequested=false }
            do {
                let results=try await engine.closeApplications(planId: plan.id, confirmedDigest: plan.digest, controller: NativeApplicationClosing())
                scanning=true; stopRequested=false; scanTitle="Refreshing affected cleanup locations…"; scanProgress=nil; scanningCleanupPath=nil; scanningLocation=nil
                operationID=UUID()
                try await updateScopedCleanup(engine: engine, roots: roots, selectedPaths: selectedPaths, previous: result)
                let unresolved=results.filter { $0.state != "closed" }
                if !unresolved.isEmpty { self.error=unresolved.map { $0.name + ": " + ($0.error ?? t("Still running. Save your work and quit the application.")) }.joined(separator: "\n") }
            } catch { if !Task.isCancelled { self.presentFailure(error) } }
        }
    }
    func closeSelectedCleanupApplications(_ applications: [ApplicationDefinition]) {
        guard let engine, !busy, !applications.isEmpty else { return }
        busy=true
        task=Task {
            do {
                let plan=try await engine.applicationClosePlan(applications: applications)
                try Task.checkCancellation()
                busy=false; closeCleanupApplications(plan)
            } catch { busy=false; presentFailure(error) }
        }
    }
    func clearHistory(_ ids: [String], includeRecoverable: Bool) {
        guard let engine, !busy, !ids.isEmpty else { return }
        busy=true
        task=Task {
            defer { busy=false }
            do { _ = try await engine.clearHistory(executionIds: ids, includeRecoverable: includeRecoverable); await refresh() }
            catch { self.presentFailure(error); await refresh() }
        }
    }
    func executeToolCleanup(_ plan: ToolCleanupPlan, service: ToolCleanupService) {
        guard !busy else { return }
        busy=true
        let operation=beginExecution(total: 1, action: "tool")
        statusKey="Cleaning tool-managed storage…"
        task=Task {
            defer { busy=false; isExecuting=false; stopRequested=false }
            do {
                toolCompletion=try await service.execute(planId: plan.id, confirmedDigest: plan.digest)
                operationHadError=toolCompletion?.state != "completed"
                updateExecutionProgress(.init(stage: "finalizing", processedCount: 1, itemCount: 1), operation: operation)
            } catch { operationHadError=true; self.presentFailure(error) }
        }
    }
    func executeApplicationOrphans(_ plan: ApplicationOrphanPlan) {
        guard !busy, let engine else { return }
        busy=true
        let operation=beginExecution(total: plan.components.count, action: plan.action)
        task=Task {
            defer { busy=false; isExecuting=false; stopRequested=false }
            do {
                let receipt=try await engine.executeApplicationOrphans(planId: plan.id, confirmedDigest: plan.digest, presence: NativeApplicationAbsence(), entryPoint: "macos", progress: { [weak self] update in
                    Task { @MainActor in self?.updateExecutionProgress(update, operation: operation) }
                })
                let remaining=Set(receipt.items.filter { !["trashed","purged"].contains($0.state) }.map(\.originalPath))
                completion=CleanupCompletion(receipts: [receipt], sourceSection: "applications", retryPaths: remaining, retryOrphans: true)
                operationHadError=receipt.state != "completed"
                await refresh()
            } catch { operationHadError=true; self.presentFailure(error) }
        }
    }
    func confirm(_ review: ReviewPrompt) {
        startReviewedExecution(total: review.itemIds.isEmpty ? review.paths.count : review.itemIds.count, action: review.action) { review }
    }
    private func startReviewedExecution(total: Int, action: String, prepare: @escaping () async throws -> ReviewPrompt) {
        guard engine != nil, !busy else { return }
        let sourceSection=section
        prompt=nil; busy=true; scanProgress=nil; statusKey="Checking selected files…"
        let execution=beginExecution(total: total, action: action, stage: "preparing")
        let operation=UUID(); operationID=operation
        task=Task {
            defer { busy=false; isExecuting=false; stopRequested=false }
            do {
                let review=try await prepare()
                try Task.checkCancellation()
                try await executeReviewedCleanup(review, sourceSection: sourceSection, execution: execution, operation: operation)
            } catch {
                if Task.isCancelled { statusKey="Operation stopped. Review History for remaining items." }
                else {
                    operationHadError=true
                    let failure=error as? ShouError
                    let details=([error.localizedDescription, failure?.details["path"], failure?.details["reasons"]].compactMap { $0 }).joined(separator: "\n")
                    if ["permanent", "trash"].contains(action) {
                        completion=CleanupCompletion(receipts: [], failures: [details], sourceSection: sourceSection)
                        statusKey="Some items could not be removed. Review the result."
                    } else { self.error=details }
                }
                await refresh()
            }
        }
    }
    private func executeReviewedCleanup(_ review: ReviewPrompt, sourceSection: String, execution: UUID, operation: UUID) async throws {
        guard let engine else { throw ShouError("io_error", "Local store is unavailable.") }
        if ["trash", "permanent"].contains(review.action) {
            let plans=review.plans.isEmpty ? [ReviewedPlan(id: review.id, digest: review.digest, workspacePath: "")] : review.plans
            var receipts: [ExecutionReceipt]=[], failures: [String]=[]
            var processed=0
            for plan in plans {
                if Task.isCancelled { failures.append(plan.workspacePath + "\n" + t("Cleanup stopped before this location was processed.")); continue }
                let processedBefore=processed, total=review.paths.count
                do {
                    let progress: @Sendable (ExecutionProgress) -> Void = { [weak self] update in
                        Task { @MainActor in
                            guard let self, self.isExecuting, self.operationID == operation else { return }
                            self.updateExecutionProgress(update.inBatch(processedBefore: processedBefore, itemCount: total), operation: execution)
                        }
                    }
                    let receipt: ExecutionReceipt
                    if plan.directRemoval {
                        receipt=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "desktop-manual-review", progress: progress)
                    } else {
                        receipt=try await engine.execute(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "desktop", progress: progress)
                    }
                    receipts.append(receipt)
                    processed += receipt.items.filter { !["pending", "moving", "purging"].contains($0.state) }.count
                }
                catch {
                    if (error as? ShouError)?.code != "cancelled" { operationHadError=true }
                    failures.append(plan.workspacePath + "\n" + error.localizedDescription)
                }
            }
            if receipts.contains(where: { $0.items.contains { ["failed", "unknown", "moving"].contains($0.state) } }) { operationHadError=true }
            let succeeded=Set(receipts.flatMap(\.items).filter { ["purged", "trashed"].contains($0.state) }.map(\.originalPath))
            let retryPaths=Set(review.paths).subtracting(succeeded)
            let retryWorkspaces=systemResult?.snapshots.map(\.workspace).filter { root in retryPaths.contains { $0.hasPrefix(root.path + "/") } } ?? []
            completion=CleanupCompletion(receipts: receipts, failures: failures, sourceSection: sourceSection, retryPaths: retryPaths, retryWorkspaces: retryWorkspaces)
            commonSelection=[]
            // A failed permanent item may already have removed descendants.
            // Every attempted execution invalidates the old scan evidence.
            snapshot=nil; selection=[]; systemResult=nil; commonReview=CleanupReview()
            statusKey=failures.isEmpty && receipts.allSatisfy { $0.state == "completed" }
                ? (review.action == "permanent" ? "Selected items permanently removed." : "Moved to Trash. Available disk space is measured separately.")
                : "Some items were not moved. Inspect history."
        } else {
            let results=try await engine.followUp(executionId: review.id, itemIds: review.itemIds, action: review.action, confirmedDigest: review.digest, progress: { [weak self] update in
                Task { @MainActor in
                    guard let self, self.isExecuting, self.operationID == operation else { return }
                    self.updateExecutionProgress(update, operation: execution)
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
        Task { do { _ = try await engine.savePreset(name: name, workspaceId: workspaceId, ruleIds: ids); await refresh() } catch { self.presentFailure(error) } }
    }
    func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal) }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var inspector=false
    @State private var ruleEditor=false
    @Environment(\.colorScheme) private var scheme
    private var pageSubtitle: String {
        switch model.section {
        case "applications": "Review applications and their related files in one place."
        case "startup": "Choose what starts with your Mac."
        case "storage": "See what takes up space, then inspect the details."
        case "large-files": "Find the files that make the biggest difference."
        case "rules": ""
        case "privacy": "Review browser records by source and time range."
        case "history": "See what changed and what needs your attention."
        case "settings": "Make Shou work the way you do."
        default: ""
        }
    }
    private var pageTitle: String {
        switch model.section {
        case "smart": "Smart Cleanup"
        case "storage": "Space Analysis"
        case "large-files": "Large Files"
        case "rules": "Cleanup Rules"
        case "startup": "Startup Items"
        case "applications": "Applications"
        case "updates": "Software Updates"
        case "tools": "Toolbox"
        case "developer-tools": "Developer Tools"
        case "ai-tools": "AI Workbench"
        case "projects": "Project Cleanup"
        case "privacy": "Privacy"
        case "monitor": "System Monitor"
        case "history": "History"
        case "settings": "Settings"
        default: "Cleanup"
        }
    }
    private var showsPageHeading: Bool {
        switch model.section {
        case "smart", "projects", "storage", "large-files", "applications", "updates", "tools", "startup", "privacy", "monitor", "developer-tools", "ai-tools": false
        case "history": !model.history.isEmpty
        default: true
        }
    }
    private var pageArtwork: WorkspaceArtworkKind? {
        switch model.section {
        case "applications": .applications
        case "startup": .startup
        case "storage": .space
        case "large-files": .largeFiles
        case "rules": .rules
        case "privacy": .privacy
        case "history": .history
        case "settings": .settings
        default: nil
        }
    }
    @ViewBuilder private var presentedContent: some View {
        if ["developer-tools","ai-tools"].contains(model.section) || model.developerTools.executing || model.developerTools.configuration.mutating { DeveloperToolsView(model: model, session: model.developerTools).id(model.section) }
        else if model.packageUpdates.executing { PackageUpgradeProgressView(model: model, session: model.packageUpdates) }
        else if model.isExecuting { ExecutionProgressView(model: model) }
        else if let result=model.toolCompletion { ToolCleanupResultView(model: model, result: result) }
        else if let result=model.completion { CleanupResultView(model: model, result: result).id(result.id) }
        else { sectionContent }
    }
    @ViewBuilder private var sectionContent: some View {
        switch model.section {
        case "smart": SmartScanView(model: model)
        case "rules": RulesView(model: model, editor: $ruleEditor)
        case "startup": StartupInventoryView(model: model)
        case "applications": ApplicationsView(model: model, session: model.applicationsSession)
        case "updates": SoftwareUpdatesView(model: model, updates: model.packageUpdates)
        case "tools": ToolboxView(model: model)
        case "developer-tools", "ai-tools": DeveloperToolsView(model: model, session: model.developerTools).id(model.section)
        case "projects": ProjectCleanupView(model: model)
        case "privacy": PrivacyView(app: model, session: model.privacySession)
        case "monitor": SystemMonitorView(model:model,session:model.monitor)
                .onAppear {
                    if model.monitorStatusItem == nil { model.monitorStatusItem=MonitorStatusItem(model:model) }
                }
        case "history": HistoryView(model: model)
        case "settings": SettingsView(model: model, updater: model.updater)
        case "storage": StorageBrowser(model: model, inspector: inspector)
        case "large-files": LargeFilesView(model: model, session: model.largeFiles)
        default: CleanupView(model: model, inspector: inspector)
        }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WorkspaceNavigation(model: model)
                if !model.isExecuting && model.completion == nil && model.toolCompletion == nil && showsPageHeading {
                    WorkspaceHeading(title: model.t(pageTitle), subtitle: model.t(pageSubtitle), artwork: pageArtwork)
                }
                if model.externalRulesChanged && !model.busy && model.completion == nil {
                    HStack {
                        Label(model.t("Personal rules changed outside Shou. Review each rule before cleanup."), systemImage: "sparkles")
                            .font(ShouType.body).lineLimit(2)
                        Spacer()
                        Button(model.t("Review Rules")) { model.reviewPersonalRules=true; model.section="rules"; model.externalRulesChanged=false }
                            .accessibilityIdentifier("rules.external.review")
                        Button { model.externalRulesChanged=false } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).accessibilityLabel(model.t("Dismiss"))
                    }.padding(.horizontal, 14).padding(.vertical, 8).background(ShouPalette.accent.opacity(0.08))
                    Divider()
                }
                presentedContent
                    .sheet(item: $model.ai.launch) { target in AILaunchView(model: model, session: model.ai, target: target) }
                Text(model.status).font(ShouType.caption).frame(height: 0).clipped()
                    .accessibilityIdentifier("operation.status")
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background { WorkspaceBackdrop().ignoresSafeArea() }
            .overlay {
                if model.initializing {
                    ActivityIndicator(title: model.t("Opening local data…")).padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle(model.displayTitle)
            .toolbar {
                ToolbarItemGroup {
                    if model.section == "rules" {
                        Button { model.addWorkspace() } label: { Label(model.t("Include Folder…"), systemImage: "folder.badge.plus") }
                            .labelStyle(.iconOnly).help(model.t("Include Folder…")).disabled(model.busy)
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
        .background { WorkspaceBackdrop().ignoresSafeArea() }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .tint(scheme == .dark ? ShouDesign.accentDark : ShouDesign.accent)
        .accentColor(scheme == .dark ? ShouDesign.accentDark : ShouDesign.accent)
        .sheet(item: $model.prompt) { review in ConfirmationView(model: model, review: review) }
        .sheet(item: $model.historyInspection) { request in HistoryInspectionView(model: model, executionId: request.id) }
        .sheet(isPresented: $ruleEditor) { RuleWizard(model: model, initialPattern: model.ruleDraftPattern) }
        .sheet(isPresented: $model.showingExclusions) { ExclusionsView(model: model) }
        .sheet(isPresented: $model.showingCleanupVolumes) { CleanupVolumePicker(model: model) }
        .sheet(isPresented: Binding(get: { model.scanAccess.showingSetup }, set: { model.scanAccess.showingSetup=$0 }), onDismiss: { model.scanAccess.dismissed() }) { SetupView(model: model) }
        .alert(model.t("Unable to complete the operation"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error=nil } })) {
            if model.accessRecovery == .administrator {
                Button(model.t("Authorize…")) { model.error=nil; model.scanAccess.authorizeAdministrator() }
                    .disabled(model.busy || model.scanAccess.authorizingAdministrator)
            } else if model.accessRecovery == .fullDiskAccess {
                Button(model.t("Review Disk Access…")) { model.error=nil; model.scanAccess.showingSetup=true }
            }
            Button(model.t("OK")) { model.error=nil }
        } message: { Text(model.diagnostic(model.error ?? "")) }
        .onChange(of: model.error) { _, value in if value == nil { model.accessRecovery=nil } }
        .onChange(of: model.scanAccess.administratorError) { _, value in if let value { model.error=model.t(value) } }
        .environment(\.shouReduceMotion, model.reduceMotion)
        .onAppear {
            let action=openWindow
            model.openMainWindow={ action(id:"workspace") }
        }
        .transaction { transaction in
            if systemReduceMotion || model.reduceMotion {
                transaction.animation=nil
                transaction.disablesAnimations=true
            }
        }
        .onChange(of: model.scanning) { _, _ in
            AccessibilityNotification.Announcement(model.status).post()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.scanAccess.refresh(); await model.refreshExternalChanges() }
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
                    Label(model.t("Evidence"), systemImage: "info.circle").font(ShouType.body.weight(.semibold))
                    Text(candidate.relativePath).font(ShouType.body.monospaced()).textSelection(.enabled)
                    LabeledContent(model.t("Risk"), value: model.t(candidate.risk))
                    LabeledContent(model.t("Logical size"), value: model.bytes(candidate.logicalBytes))
                    LabeledContent(model.t("Newest modification"), value: model.date(candidate.newestModifiedAt))
                    Divider()
                    ForEach(candidate.ruleIds, id: \.self) { Text($0).font(ShouType.caption.monospaced()) }
                    ForEach(candidate.reasons, id: \.self) { Label(model.t($0), systemImage: "exclamationmark.circle").font(ShouType.caption) }
                    ForEach(candidate.rebuildNotes, id: \.self) { Text(model.t($0)).font(ShouType.body) }
                    ForEach(candidate.limitations, id: \.self) { Text("• " + model.t($0)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
                    Text(model.t("Directory names, sizes, and lockfiles do not prove data can be rebuilt.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                } else { Text(model.t("Select a directory to inspect matching evidence and rebuild requirements.")).foregroundStyle(ShouPalette.secondary) }
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
    @State private var reviewingRule: RuleRecord?
    @State private var ruleSource="all"
    @State private var agentSetup=false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label(model.t("Cleanup rules made for your Mac"), systemImage: "sparkles").font(ShouType.body.weight(.medium))
                    .help(model.t("Investigate a folder with built-in AI, or use your external AI tool to create personal rules."))
                Spacer(minLength: 8)
                Button(model.t("Create Rules with AI…")) { model.ai.goal = .rules; model.ai.requestLaunch(app: model) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("rules.ai.investigate")
                Button(model.t("External AI Tools…")) { agentSetup=true }.accessibilityIdentifier("rules.agent.setup")
            }
            .padding(.horizontal, 12).frame(height: 44)
            .background(ShouPalette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
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
            }.padding(.horizontal, 16).padding(.bottom, 10)
            Picker(model.t("Rule Source"), selection: $ruleSource) {
                Text(model.t("All Rules")).tag("all")
                Text(model.t("Built-in Rules")).tag("builtin")
                Text(model.t("Personal Rules")).tag("personal")
            }.pickerStyle(.segmented).frame(maxWidth: 440).padding(.horizontal, 16).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if ruleSource != "personal" {
                        BuiltinRulesCatalogView(model: model)
                    }
                    if ruleSource != "builtin" {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.t("Personal Rules")).font(ShouType.body.weight(.semibold))
                            if model.configuration.rules.isEmpty {
                                Text(model.t("Ask your agent to create a rule for your build outputs and caches. Imported drafts appear here."))
                                    .font(ShouType.body).foregroundStyle(ShouPalette.secondary).padding(.vertical, 12)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(model.configuration.rules) { record in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Label(record.rule.name, systemImage: "doc.text").font(ShouType.body.weight(.semibold)); Spacer()
                                            let root=model.configuration.workspaces.first { $0.rootRef == record.rule.scope.rootRef }
                                            let enabled=model.configuration.bindings.contains { $0.workspaceId == root?.id && $0.ruleId == record.rule.id && $0.version == record.rule.version && $0.enabled }
                                            Toggle(model.t("Enabled"), isOn: Binding(get: { enabled }, set: { model.setEnabled(record, enabled: $0) })).toggleStyle(.switch).disabled(root == nil || model.busy)
                                        }
                                        Text(record.rule.description).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                                        Text(record.rule.id + ", " + record.rule.version + ", " + record.rule.scope.rootRef).font(ShouType.caption.monospaced()).foregroundStyle(ShouPalette.secondary)
                                        Text(record.rule.risk.rebuildNote).font(ShouType.caption)
                                        HStack {
                                            Button(model.t("Edit Rule…")) { editingRule=record }.disabled(model.busy)
                                                .buttonStyle(.bordered)
                                                .accessibilityIdentifier("rules.edit." + record.id)
                                            Button(model.t("Review & Clean…")) { reviewingRule=record }.disabled(model.busy || !model.configuration.workspaces.contains { $0.rootRef == record.rule.scope.rootRef })
                                                .buttonStyle(.bordered)
                                                .accessibilityIdentifier("rules.preview." + record.rule.id)
                                            Button(model.t("Export Rule…")) { model.exportRule(record) }
                                                .buttonStyle(.bordered)
                                                .accessibilityIdentifier("rules.export." + record.rule.id)
                                        }
                                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    if record.id != model.configuration.rules.last?.id { Divider() }
                                }
                            }.background(ShouPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                PageInfoButton(title: model.t("Rules"), message: model.t("Built-in rules cover everyday cleanup. Review personal rules created with built-in AI or external tools.") + "\n\n" + model.t("Investigate a folder with built-in AI, or use your external AI tool to create personal rules."))
                Button(model.t("Exclusions…")) { model.showingExclusions=true }.disabled(model.busy)
                Menu(model.t("Advanced")) {
                    Button(model.t("Import…")) { model.importRule() }
                    Button(model.t("New Rule…")) { model.ruleDraftPattern=""; editor=true }.disabled(model.workspace == nil)
                }.disabled(model.busy)
            }
        }
        .sheet(item: $editingRule) { RuleRevisionEditor(model: model, original: $0) }
        .sheet(item: $reviewingRule) { PersonalRuleReviewView(model: model, record: $0) }
        .sheet(isPresented: $agentSetup, onDismiss: { Task { await model.refresh() } }) { AgentRuleSetupView(model: model) }
        .onAppear {
            if model.reviewPersonalRules { ruleSource="personal"; model.reviewPersonalRules=false }
            Task { await model.refresh() }
        }
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
            Label(title, systemImage: ["purge", "permanent"].contains(review.action) ? "exclamationmark.triangle" : "trash").font(ShouType.title.bold())
            Text(["purge", "permanent"].contains(review.action) ? model.t("This is irreversible. Only the selected items from this cleanup batch will be removed.") : model.t("Check every path. Files and configuration will be verified again immediately before processing.")).foregroundStyle(ShouPalette.secondary)
            if review.manualReview {
                Label(model.t("Manual selection includes items outside automatic cleanup. Review their contents and stop related tasks. The complete listed directories will be removed."), systemImage: "exclamationmark.triangle")
                    .font(ShouType.body).foregroundStyle(ShouPalette.warning)
            }
            List(review.paths, id: \.self) { Text($0).font(ShouType.body.monospaced()).textSelection(.enabled) }.frame(minHeight: 160, maxHeight: 300)
            if !review.impacts.isEmpty {
                DisclosureGroup(model.t("Cleanup Impact")) {
                    ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(review.impacts, id: \.self) { Text(model.t($0)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary) } } }.frame(maxHeight: 140)
                }
            }
            Text(model.bytes(review.byteEstimate) + ", " + String(review.paths.count) + model.t(" items")).monospacedDigit()
            DisclosureGroup(model.t("Verification Details")) {
                ForEach(review.plans.isEmpty ? [ReviewedPlan(id: review.id, digest: review.digest, workspacePath: "")] : review.plans, id: \.id) { plan in
                    Text(plan.id + "\n" + plan.digest).font(ShouType.caption.monospaced()).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
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
