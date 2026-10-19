import SwiftUI
import ShouCore
import ShouPlatform
import AppKit
import Observation
import UniformTypeIdentifiers

@main struct ShouApp: App {
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
                .task { await model.refresh() }
        }
        .defaultSize(width: 1160, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(model: model, updater: model.updater)
            }
            CommandGroup(replacing: .appSettings) {
                Button(model.t("Settings…")) { model.section="settings" }.keyboardShortcut(",")
            }
            CommandGroup(after: .newItem) { Button(model.t("Add Workspace…")) { model.addWorkspace() }.keyboardShortcut("o", modifiers: [.command, .shift]) }
            CommandMenu(model.t("Workspace")) { Button(model.t("Scan")) { model.scanCurrentSection() }.keyboardShortcut("r").disabled(model.busy) }
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
    var browsingPath="."
    var focusedPath: String?
    var ruleDraftPattern="**/target"
    var builtins: [CleanupRule]=[]
    var scanProgress: ScanProgress?
    var selection=Set<String>()
    var history: [ExecutionReceipt]=[]
    var followups: [FollowUpReceipt]=[]
    var busy=false { didSet { updater.operationInProgress=busy } }
    var scanning=false
    var isExecuting=false
    var stopRequested=false
    var executionProgress: ExecutionProgress?
    var error: String?
    var statusKey=""
    var prompt: ReviewPrompt?
    var completion: CleanupCompletion?
    var language=AppLanguage(savedValue: UserDefaults.standard.string(forKey: "ShouLanguage")) {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "ShouLanguage") }
    }
    private var task: Task<Void, Never>?
    private var operationID=UUID()
    let engine: ShouEngine?
    init() {
        do {
            let readWorker=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shou")
            engine=ShouEngine(store: try LocalRecordStore(), filesystem: NativeFileSystem(readWorkerExecutable: readWorker), applicationActivity: NativeApplicationActivity(), artifactEvidence: NativeArtifactEvidence())
        }
        catch { engine=nil; self.error=error.localizedDescription }
    }
    func t(_ key: String) -> String { L10n.string(key, locale: language.rawValue) }
    func diagnostic(_ message: String) -> String { message.components(separatedBy: "\n").map(t).joined(separator: "\n") }
    var displayTitle: String { language == .simplifiedChinese ? "Shou · 收拾一下" : "Shou" }
    var status: String {
        if scanning, let progress=scanProgress {
            if progress.stage == "preparing" { return t("Preparing common app scan…") }
            let key=progress.stage == "scanning" ? "Scanning: %lld entries" : progress.stage == "analysis" ? "Analyzing %lld entries…" : "Saving %lld entries…"
            return String(format: t(key), locale: language.locale, progress.entryCount)
        }
        return t(statusKey)
    }
    func date(_ value: Date) -> String { value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(language.locale)) }
    var workspace: Workspace? { configuration.workspaces.first { $0.id == workspaceId } }
    var projectWorkspaces: [Workspace] { configuration.workspaces.filter { root in !knownLocations.contains { $0.path == root.path } } }
    var commonSelected: [CleanupSource] { commonReview.sources.filter { commonSelection.contains($0.id) && $0.selectable } }
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
        } catch { if !Task.isCancelled { self.error=error.localizedDescription } }
    }
    func addWorkspace() {
        guard !busy else { return }
        let panel=NSOpenPanel(); panel.canChooseFiles=false; panel.canChooseDirectories=true; panel.allowsMultipleSelection=false
        panel.message=t("Choose a development workspace. Scanning does not delete files.")
        guard panel.runModal() == .OK, let url=panel.url, let engine else { return }
        Task {
            do {
                let rootRef=configuration.workspaces.isEmpty ? "developer-workspaces" : "workspace-" + String(UUID().uuidString.prefix(8)).lowercased()
                let root=try await engine.addWorkspace(path: url.path, rootRef: rootRef)
                workspaceId=root.id; snapshot=nil; selection=[]; section="overview"; await refresh(); startScan()
            } catch { self.error=error.localizedDescription }
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
    func startScan(preset: Preset? = nil) {
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
                statusKey=snapshot?.status == "complete" ? "Scan complete. Review candidates before cleanup." : "Some paths could not be fully scanned. Only independently verified items can be reviewed for cleanup."
            } catch { if !Task.isCancelled { self.error=error.localizedDescription }; statusKey="Scan stopped." }
        }
    }
    func scanCurrentSection() {
        if section == "smart" { scanCommonLocations() } else { startScan() }
    }
    func scanCommonLocations() {
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
                statusKey=systemResult?.status == "complete" ? "Common app scan complete" : "Some locations could not be fully scanned."
                await refresh()
            } catch {
                if !Task.isCancelled { self.error=error.localizedDescription }
                statusKey="Scan stopped."; await refresh()
            }
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
    func previewCommonCleanup() {
        guard let engine, !busy, !commonSelected.isEmpty else { return }
        let sources=commonSelected
        busy=true; statusKey="Preparing cleanup preview…"
        task=Task {
            defer { busy=false }
            do {
                var plans: [CleanupPlan]=[]
                for snapshotId in Set(sources.map(\.snapshotId)).sorted() {
                    plans.append(try await engine.createPlan(scanId: snapshotId, candidateIds: sources.filter { $0.snapshotId == snapshotId }.map(\.candidate.id)))
                }
                prompt=ReviewPrompt(id: UUID().uuidString, digest: "", action: "trash",
                    paths: plans.flatMap { plan in plan.items.map { plan.workspace.path + "/" + $0.candidate.relativePath } }, itemIds: [],
                    byteEstimate: plans.reduce(0) { $0 + $1.allocatedBytesEstimate },
                    plans: plans.map { ReviewedPlan(id: $0.id, digest: $0.digest, workspacePath: $0.workspace.path) },
                    impacts: Array(Set(plans.flatMap { $0.items.flatMap { $0.candidate.rebuildNotes + $0.candidate.limitations } })).sorted())
                statusKey="Ready to review"
            } catch { self.error=error.localizedDescription }
        }
    }
    func cancel() { if isExecuting { stopRequested=true }; task?.cancel() }
    func importRule() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.json]; panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK, let url=panel.url, let engine else { return }
        Task {
            do {
                let handle=try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                _ = try await engine.importRule(handle.read(upToCount: 262_145) ?? Data()); await refresh(); section="rules"
            } catch { self.error=error.localizedDescription }
        }
    }
    func previewRule(_ record: RuleRecord) {
        guard let engine, !workspaceId.isEmpty, !busy else { return }
        busy=true; scanning=true; selection=[]; scanProgress=nil
        task=Task {
            defer { busy=false; scanning=false }
            do { snapshot=try await engine.scan(workspaceId: workspaceId, previewRule: record.rule); section="overview"; statusKey="Draft preview only. Enable the rule and rescan before cleanup." }
            catch { self.error=error.localizedDescription }
        }
    }
    func exportRule(_ record: RuleRecord) {
        let panel=NSSavePanel(); panel.allowedContentTypes=[.json]; panel.nameFieldStringValue=record.rule.id + ".rule.json"
        guard panel.runModal() == .OK, let url=panel.url else { return }
        do { try Codec.encode(record.rule).write(to: url, options: [.withoutOverwriting]) } catch { self.error=error.localizedDescription }
    }
    func removeWorkspace(_ root: Workspace) {
        guard let engine, !busy else { return }
        Task { do { try await engine.removeWorkspace(root.id); snapshot=nil; selection=[]; await refresh() } catch { self.error=error.localizedDescription } }
    }
    func setEnabled(_ record: RuleRecord, enabled: Bool) { setEnabled(record.rule, enabled: enabled) }
    func setEnabled(_ rule: CleanupRule, enabled: Bool) {
        guard let engine else { return }
        Task { do { _ = try await engine.setRule(ruleId: rule.id, workspaceId: workspaceId, enabled: enabled, version: rule.version); snapshot=nil; selection=[]; await refresh() } catch { self.error=error.localizedDescription } }
    }
    func exclude(_ candidate: Candidate) {
        guard let engine else { return }
        Task { do { _ = try await engine.setExclusion(workspaceId: workspaceId, pattern: candidate.relativePath + "/**", remove: false); await refresh(); startScan() } catch { self.error=error.localizedDescription } }
    }
    func previewCleanup() {
        guard let engine, let snapshot, !busy, !selected.isEmpty else { return }
        busy=true; statusKey="Preparing cleanup preview…"
        task=Task {
            defer { busy=false }
            do {
                let plan=try await engine.createPlan(scanId: snapshot.id, candidateIds: selected.filter(\.eligible).map(\.id))
                prompt=ReviewPrompt(id: plan.id, digest: plan.digest, action: "trash", paths: plan.items.map { plan.workspace.path + "/" + $0.candidate.relativePath }, itemIds: [], byteEstimate: plan.allocatedBytesEstimate,
                    impacts: Array(Set(plan.items.flatMap { $0.candidate.rebuildNotes + $0.candidate.limitations })).sorted())
                statusKey="Ready to review"
            } catch { self.error=error.localizedDescription }
        }
    }
    func review(_ receipt: ExecutionReceipt, items: [ItemReceipt], action: String) {
        guard let engine else { return }
        Task {
            do {
                let digest=try await engine.followUpDigest(executionId: receipt.id, itemIds: items.map(\.id), action: action)
                prompt=ReviewPrompt(id: receipt.id, digest: digest, action: action, paths: items.map(\.originalPath), itemIds: items.map(\.id), byteEstimate: items.reduce(0) { $0 + $1.allocatedBytesEstimate })
            } catch { self.error=error.localizedDescription }
        }
    }
    func confirm(_ review: ReviewPrompt) {
        guard let engine, !busy else { return }
        prompt=nil; busy=true; scanProgress=nil; isExecuting=true; stopRequested=false; executionProgress=nil
        let operation=UUID(); operationID=operation
        task=Task {
            defer { busy=false; isExecuting=false; stopRequested=false }
            do {
                if review.action == "trash" {
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
                        catch { failures.append(plan.workspacePath + "\n" + error.localizedDescription) }
                    }
                    completion=CleanupCompletion(receipts: receipts, failures: failures)
                    commonSelection=[]
                    if receipts.contains(where: { $0.items.contains { $0.state == "trashed" || $0.state == "unknown" } }) { systemResult=nil; commonReview=CleanupReview() }
                    statusKey=failures.isEmpty && receipts.allSatisfy { $0.state == "completed" } ? "Moved to Trash. Available disk space is measured separately." : "Some items were not moved. Inspect history."
                } else {
                    let results=try await engine.followUp(executionId: review.id, itemIds: review.itemIds, action: review.action, confirmedDigest: review.digest)
                    if results.contains(where: { $0.state != "completed" }) { error=results.compactMap(\.error).joined(separator: "\n") }
                }
                snapshot=nil; selection=[]; section="history"; await refresh()
            } catch { self.error=error.localizedDescription; await refresh() }
        }
    }
    func saveRule(_ data: Data) async throws {
        guard let engine else { throw ShouError("io_error", "Local store is unavailable.") }
        _ = try await engine.importRule(data); await refresh(); section="rules"
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
    @State private var inspector=false
    @State private var ruleEditor=false
    private var navigationSelection: Binding<String> {
        Binding(get: { model.section }, set: { section in
            guard ["smart", "overview", "storage", "rules", "history", "settings"].contains(section) else { return }
            model.section=section
        })
    }
    var body: some View {
        NavigationSplitView {
            List(selection: navigationSelection) {
                Section(model.displayTitle) {
                    Label(model.t("Common App Cleanup"), systemImage: "sparkle.magnifyingglass").tag("smart")
                    Label(model.t("Project Cleanup"), systemImage: "hammer").tag("overview")
                    Label(model.t("Space Analysis"), systemImage: "square.grid.2x2").tag("storage")
                    Label(model.t("Rules"), systemImage: "line.3.horizontal.decrease.circle").tag("rules")
                    Label(model.t("History"), systemImage: "clock.arrow.circlepath").tag("history")
                }
                Section(model.t("Workspaces")) {
                    ForEach(model.projectWorkspaces) { root in
                            Button { model.selectWorkspace(root) } label: {
                            Label(URL(fileURLWithPath: root.path).lastPathComponent, systemImage: model.workspaceId == root.id ? "folder.fill" : "folder")
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(root.path).disabled(model.busy).contextMenu {
                            Button(model.t("Unregister Workspace")) { model.removeWorkspace(root) }.disabled(model.busy)
                        }
                    }
                    Button { model.addWorkspace() } label: { Label(model.t("Add Workspace…"), systemImage: "folder.badge.plus") }.buttonStyle(.plain).disabled(model.busy)
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
                else if model.section == "history" { HistoryView(model: model) }
                else if model.section == "settings" { SettingsView(model: model, updater: model.updater) }
                else if model.section == "storage" { StorageBrowser(model: model, ruleEditor: $ruleEditor, inspector: inspector) }
                else { CleanupView(model: model, inspector: inspector) }
                if model.isExecuting {
                    ExecutionProgressView(title: model.t(model.executionProgress?.stage == "preflight" ? "Checking selected items…" : model.executionProgress == nil ? "Processing selected items…" : "Moving items to Trash…"),
                        currentPath: model.executionProgress?.path, processedCount: model.executionProgress?.processedCount ?? 0,
                        totalCount: model.executionProgress?.itemCount ?? 0,
                        countText: model.executionProgress.map { String(format: model.t("%lld of %lld items processed"), $0.processedCount, $0.itemCount) } ?? "",
                        stopRequested: model.stopRequested, stopLabel: model.t("Stop"), stoppingLabel: model.t("Stopping after the current item…"), onStop: model.cancel)
                }
                Divider()
                HStack {
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0").font(.caption.monospaced()).foregroundStyle(.tertiary)
                }.padding(10)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                ToolbarItemGroup {
                    if model.section != "settings" {
                        Button { model.addWorkspace() } label: { Label(model.t("Add Workspace"), systemImage: "folder.badge.plus") }.disabled(model.busy)
                    }
                    if model.section == "overview" || model.section == "storage" { Button { if model.scanning { model.cancel() } else { model.scanCurrentSection() } } label: {
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
        .sheet(isPresented: $ruleEditor) { RuleWizard(model: model, initialPattern: model.ruleDraftPattern) }
        .alert(model.t("Unable to complete the operation"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error=nil } })) {
            Button(model.t("OK")) { model.error=nil }
        } message: { Text(model.diagnostic(model.error ?? "")) }
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
    var body: some View {
        VStack(alignment: .leading) {
            HStack { VStack(alignment: .leading) { Text(model.t("Rules")).font(.largeTitle); Text(model.t("Built-in rules work immediately. Personal rules are imported as disabled drafts.")).foregroundStyle(.secondary) }; Spacer(); Button(model.t("Import…")) { model.importRule() }; Button(model.t("New Rule…")) { model.ruleDraftPattern="**/target"; editor=true }.disabled(model.workspace == nil) }.padding(24)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.t("Personal Rules")).font(.headline)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(model.configuration.rules) { record in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Label(record.rule.name, systemImage: "doc.text").font(.headline); Spacer()
                                        let enabled=model.configuration.bindings.contains { $0.workspaceId == model.workspaceId && $0.ruleId == record.rule.id && $0.version == record.rule.version && $0.enabled }
                                        Toggle(model.t("Enabled"), isOn: Binding(get: { enabled }, set: { model.setEnabled(record, enabled: $0) })).toggleStyle(.switch).disabled(model.workspace == nil || model.busy)
                                    }
                                    Text(record.rule.description).font(.callout).foregroundStyle(.secondary)
                                    Text(record.rule.id + " · " + record.rule.version + " · " + record.rule.scope.rootRef).font(.caption.monospaced()).foregroundStyle(.tertiary)
                                    Text(record.rule.risk.rebuildNote).font(.caption)
                                    HStack {
                                        Button(model.t("Preview Draft")) { model.previewRule(record) }.disabled(model.busy || model.workspace == nil)
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
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .onChange(of: model.workspaceId) { _, _ in model.snapshot=nil; model.selection=[]; Task { await model.refresh() } }
        .alert(model.t("Save Preset"), isPresented: $presetAlert) {
            TextField(model.t("Name"), text: $presetName)
            Button(model.t("Save")) { model.savePreset(presetName); presetName="" }.disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(model.t("Cancel"), role: .cancel) {}
        }
    }
}

struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var selection=Set<String>()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(model.history) { receipt in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(model.date(receipt.createdAt)); Text(model.t(receipt.state)); Text(model.t(receipt.entryPoint == "desktop" ? "Desktop" : "CLI")); Spacer(); Text(receipt.id).font(.caption.monospaced()) }
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(receipt.items) { item in
                                let completed=model.followups.first { $0.itemId == item.id && $0.state == "completed" }
                                let state=receipt.state == "cancelled" && item.state == "pending" ? "Skipped" : item.state
                                HStack {
                                    Toggle(isOn: Binding(get: { selection.contains(item.id) }, set: { if $0 { selection.insert(item.id) } else { selection.remove(item.id) } })) { VStack(alignment: .leading) { Text(item.relativePath).font(.body.monospaced()); Text(model.diagnostic(item.error ?? completed?.action ?? state)).font(.caption).foregroundStyle(.secondary) } }.toggleStyle(.checkbox).disabled(item.state != "trashed" || completed != nil)
                                    Spacer(); Text(model.bytes(item.allocatedBytesEstimate)).monospacedDigit()
                                }.padding(12)
                                Divider()
                            }
                            HStack {
                                Text(model.t("Moved to Trash; this is not freed space.")).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(model.t("View Results")) { model.completion=CleanupCompletion(receipts: [receipt]) }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("history.results." + receipt.id)
                                let items=receipt.items.filter { item in
                                    selection.contains(item.id) && item.state == "trashed" && !model.followups.contains { $0.itemId == item.id && $0.state == "completed" }
                                }
                                Button(model.t("Restore…")) { model.review(receipt, items: items, action: "restore") }.disabled(items.isEmpty || model.busy)
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("history.restore." + receipt.id)
                                Button(model.t("Permanently Remove…"), role: .destructive) { model.review(receipt, items: items, action: "purge") }.disabled(items.isEmpty || model.busy)
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("history.remove." + receipt.id)
                            }.padding(12)
                        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.overlay { if model.history.isEmpty { ContentUnavailableView(model.t("No cleanup history"), systemImage: "clock") } }
    }
}

struct ConfirmationView: View {
    var model: AppModel
    let review: ReviewPrompt
    @Environment(\.dismiss) private var dismiss
    private var title: String {
        review.action == "purge" ? model.t("Permanently remove these items?") : review.action == "restore" ? model.t("Restore these items?") : model.t("Move these items to Trash?")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: review.action == "purge" ? "exclamationmark.triangle" : "trash").font(.title2.bold())
            Text(review.action == "purge" ? model.t("This is irreversible. Only the selected items from this cleanup batch will be removed.") : model.t("Check every path. Files and configuration will be verified again immediately before processing.")).foregroundStyle(.secondary)
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
            HStack { Spacer(); Button(model.t("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction); Button(model.t("Confirm"), role: review.action == "restore" ? nil : .destructive) { model.confirm(review) }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 650)
    }
}

struct RuleWizard: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name=""
    @State private var pattern="**/target"
    @State private var marker="Cargo.toml"
    @State private var rebuild=""
    @State private var limitations=""
    @State private var age=14
    @State private var megabytes=100
    @State private var highRisk=false
    @State private var issue: String?
    init(model: AppModel, initialPattern: String = "**/target") {
        self.model=model; _pattern=State(initialValue: initialPattern)
        _marker=State(initialValue: initialPattern == "**/target" ? "Cargo.toml" : "")
    }
    var body: some View {
        VStack(alignment: .leading) {
            Text(model.t("Create a Personal Rule")).font(.title2.bold())
            Form {
                LabeledContent(model.t("Workspace"), value: model.workspace?.rootRef ?? "")
                TextField(model.t("Rule name"), text: $name)
                TextField(model.t("Relative pattern"), text: $pattern)
                TextField(model.t("Parent project marker"), text: $marker)
                Stepper(String(format: model.t("Newest modification at least %lld days ago"), age), value: $age, in: 0...3650)
                Stepper(String(format: model.t("At least %lld MB allocated"), megabytes), value: $megabytes, in: 0...100_000, step: 100)
                TextField(model.t("How can these files be rebuilt?"), text: $rebuild, axis: .vertical)
                TextField(model.t("Limitations and data to preserve"), text: $limitations, axis: .vertical)
                Toggle(model.t("High risk (required for installed dependencies)"), isOn: $highRisk)
            }.formStyle(.grouped)
            if let issue { Text(issue).foregroundStyle(.red).font(.caption) }
            Text(model.t("Saved as a disabled draft. Review and enable it in Rules, then scan again.")).font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button(model.t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction); Button(model.t("Save Draft")) { save() }.buttonStyle(.borderedProminent).disabled(name.isEmpty || rebuild.isEmpty || limitations.isEmpty) }
        }.padding(24).frame(width: 650, height: 600)
    }
    private func save() {
        guard let workspace=model.workspace else { return }
        var match: [String: JSONValue] = ["kind": .string("directory"), "relative_patterns": .array([.string(pattern)])]
        if !marker.isEmpty { match["project_markers"] = .object(["location": .string("parent"), "all_of": .array([.string(marker)])]) }
        let rule: JSONValue = .object([
            "schema_version": .string("1.0"), "id": .string("personal." + UUID().uuidString.lowercased()), "version": .string("0.1.0"), "name": .string(name), "description": .string(rebuild), "platforms": .array([.string("macos")]),
            "scope": .object(["root_ref": .string(workspace.rootRef), "max_depth": .integer(8), "follow_symlinks": .bool(false), "cross_filesystems": .bool(false)]),
            "match": .object(match),
            "conditions": .object(["min_allocated_bytes": .integer(Int64(megabytes) * 1_000_000), "newest_descendant_modified_days_at_least": .integer(Int64(age))]),
            "exclude": .object(["relative_patterns": .array([])]), "risk": .object(["declared_level": .string(highRisk ? "high" : "review"), "rebuild_note": .string(rebuild), "limitations": .array([.string(limitations)])]), "action": .object(["type": .string("trash")])
        ])
        Task { do { try await model.saveRule(Codec.encode(rule)); dismiss() } catch { issue=error.localizedDescription } }
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
