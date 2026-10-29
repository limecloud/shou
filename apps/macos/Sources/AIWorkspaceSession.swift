import AppKit
import Observation
import ShouAI
import ShouCore
import ShouPlatform

@MainActor @Observable final class AIWorkspaceSession {
    var enabled=UserDefaults.standard.bool(forKey: "ShouAIEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "ShouAIEnabled")
            gate.setEnabled(enabled)
            if !enabled { stop() }
        }
    }
    private let gate=AIRequestGate(enabled: UserDefaults.standard.bool(forKey: "ShouAIEnabled"))
    var launch: AILaunchTarget?
    var stopping=false
    var goal=AIInvestigationGoal.investigate
    var showingInspector=false
    var connections: [AIConnection]=[]
    var deletedConnections: [AIConnection]=[]
    var connectionId=UserDefaults.standard.string(forKey: "ShouAIConnection") ?? "" {
        didSet { UserDefaults.standard.set(connectionId, forKey: "ShouAIConnection") }
    }
    var investigation: AIInvestigation?
    var scope="."
    var scanId=""
    var folder=""
    var request=""
    var answers: [String: String]=[:]
    var issue: String?
    var running=false
    var canManageConnections: Bool { !running && investigation?.status != .waiting }
    var importing=false
    var review: RuleRecord?
    var savedInvestigations: [AIInvestigation]=[]
    var showingHistory=false
    var loadingHistory=false
    private var restoredRoot: String?
    private var task: Task<Void, Never>?
    private var activeService: AIInvestigationService?
    private var directoryPanel: NSOpenPanel?
    func networkPermit() -> AIRequestPermit { gate.permit() }
    func requestLaunch(app: AppModel, path: String? = nil) {
        guard !app.busy, directoryPanel == nil else { return }
        loadConnections()
        if let path {
            do { launch=AILaunchTarget(path: try NativeDirectorySelection.path(for: URL(fileURLWithPath: path))) }
            catch { app.presentFailure(error) }
            return
        }
        chooseLaunchFolder(app: app) { [weak self] path in self?.launch=AILaunchTarget(path: path) }
    }
    func chooseLaunchFolder(app: AppModel, initial: String? = nil, selected: @escaping (String) -> Void) {
        guard directoryPanel == nil else { return }
        let panel=NSOpenPanel(); panel.canChooseFiles=false; panel.canChooseDirectories=true; panel.allowsMultipleSelection=false
        if let initial { panel.directoryURL=URL(fileURLWithPath: initial) }
        panel.message=app.t("Choose the exact folder to investigate. Measurement is local; AI starts only when you choose Start Investigation.")
        directoryPanel=panel
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak app] response in
            guard let self else { return }
            self.directoryPanel=nil
            guard response == .OK, let url=panel.url else { return }
            do { selected(try NativeDirectorySelection.path(for: url)) }
            catch { app?.error=error.localizedDescription }
        }
        if let window=NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else { panel.begin(completionHandler: completion) }
    }
    func canReuse(_ target: String, app: AppModel) -> Bool {
        guard let scan=app.space.scan, !app.space.hasChanges else { return false }
        let prefix=scan.rootPath == "/" ? "/" : scan.rootPath + "/"
        return target == scan.rootPath || target.hasPrefix(prefix)
    }
    func launchTarget(_ target: String, app: AppModel) {
        launch=nil
        Task {
            if running { stop(); await task?.value }
            if canReuse(target, app: app), let scan=app.space.scan {
                let prefix=scan.rootPath == "/" ? "/" : scan.rootPath + "/"
                let scope=target == scan.rootPath ? "." : String(target.dropFirst(prefix.count))
                do {
                    _ = try await app.engine?.storageDirectory(scanId: scan.id, path: scope)
                    app.section="storage"; prepare(app: app, scope: scope); showingInspector=true
                } catch { issue=error.localizedDescription }
            } else {
                app.scanAccess.prepareScan { [weak self, weak app] in
                    guard let self, let app else { return }
                    app.section="storage"; app.space.location=target
                    app.space.start(app: app, accessChecked: true)
                    Task {
                        await app.space.waitForOperation()
                        guard app.space.scan?.rootPath == target, !app.space.scanning else { return }
                        self.prepare(app: app, scope: "."); self.showingInspector=true
                    }
                }
            }
        }
    }

    func loadConnections() {
        do {
            let store=try AIConnectionStore(store: LocalRecordStore())
            connections=try store.connections(); deletedConnections=try store.connections(deleted: true)
            if !connections.contains(where: { $0.id == connectionId && $0.usesMainModel }) { connectionId=connections.first(where: \.usesMainModel)?.id ?? "" }
        } catch { issue=error.localizedDescription }
    }
    func setDecisionEnabled(_ enabled: Bool, connection: AIConnection) {
        guard canManageConnections else { return }
        do {
            var value=connection
            if enabled, value.decision == nil { value.decision=DecisionConnection() }
            value.routingStrategy=enabled ? .decisionFirst : .mainOnly
            try AIConnectionStore(store: LocalRecordStore()).save(value); loadConnections()
        } catch { issue=error.localizedDescription }
    }
    func setConnectionDeleted(_ deleted: Bool, connection: AIConnection) {
        guard canManageConnections else { return }
        do { try AIConnectionStore(store: LocalRecordStore()).setDeleted(deleted, id: connection.id); loadConnections() }
        catch { issue=error.localizedDescription }
    }
    func open(app: AppModel) {
        showingInspector=true; loadConnections()
        if investigation == nil && !running { prepare(app: app) }
    }
    func prepare(app: AppModel, scope targetScope: String? = nil) {
        guard !running, let scan=app.space.scan else { return }
        investigation=nil; answers=[:]; request=""; issue=nil; restoredRoot=nil
        scanId=scan.id; scope=targetScope ?? app.space.path
        folder=scope == "." ? scan.rootPath : (scan.rootPath as NSString).appendingPathComponent(scope)
    }
    func stale(app: AppModel) -> Bool {
        if let restoredRoot {
            return investigation.map { Date().timeIntervalSince($0.createdAt) >= 86400 } == true ||
                (app.space.scan?.rootPath == restoredRoot && (app.space.scan?.id != scanId || app.space.hasChanges))
        }
        return app.space.scan?.id != scanId || app.space.hasChanges || investigation.map { Date().timeIntervalSince($0.createdAt) >= 86400 } == true
    }
    func loadHistory(app: AppModel) {
        guard !running, !loadingHistory else { return }
        loadingHistory=true; showingHistory=true; issue=nil
        Task {
            defer { loadingHistory=false }
            do { savedInvestigations=try await service(app: app).list().filter { $0.status != .running } }
            catch { issue=error.localizedDescription }
        }
    }
    func restore(_ state: AIInvestigation, app: AppModel) {
        guard !running, !loadingHistory, investigation?.status != .waiting, let engine=app.engine else { return }
        loadingHistory=true; issue=nil
        Task {
            defer { loadingHistory=false }
            do {
                let scan=try await engine.storageScan(state.scanId)
                let service=try service(app: app)
                investigation=try await service.read(state.id); answers=[:]; issue=nil
                scanId=state.scanId; scope=state.scope; restoredRoot=scan.rootPath
                folder=scope == "." ? scan.rootPath : (scan.rootPath as NSString).appendingPathComponent(scope)
                showingHistory=false
            } catch { issue=error.localizedDescription }
        }
    }
    func stop() {
        if running { stopping=true; task?.cancel() }
        else if var state=investigation, state.status == .waiting {
            state.status = .cancelled; state.issue="Investigation cancelled."; investigation=state
            Task { try? await activeService?.cancel(state.id) }
        }
    }

    private func service(app: AppModel) throws -> AIInvestigationService {
        guard let engine=app.engine else { throw ShouError("unavailable", "The cleanup engine is unavailable.") }
        let service=try AIInvestigationService(engine: engine, store: LocalRecordStore(), credentials: SystemAICredentials(), permit: networkPermit())
        activeService=service; return service
    }
    func start(app: AppModel) {
        guard enabled, !running, !stale(app: app), let connection=connections.first(where: { $0.id == connectionId }) else { return }
        do {
            let service=try service(app: app), scanId=scanId, scope=scope, request=request, locale=app.language.rawValue, goal=goal
            running=true; issue=nil; investigation=nil
            task=Task {
                defer { running=false; stopping=false; task=nil }
                do {
                    investigation=try await service.start(scanId: scanId, scope: scope, connection: connection, request: request, locale: locale, goal: goal) { [weak self] state in
                        await MainActor.run { self?.investigation=state }
                    }
                } catch { issue=error.localizedDescription }
            }
        } catch { issue=error.localizedDescription }
    }
    func resume(app: AppModel) {
        guard enabled, !running, !stale(app: app), let investigation, investigation.status == .waiting else { return }
        do {
            let service=try service(app: app), answers=answers
            running=true; issue=nil
            task=Task {
                defer { running=false; stopping=false; task=nil }
                do {
                    self.investigation=try await service.resume(investigation.id, answers: answers) { [weak self] state in
                        await MainActor.run { self?.investigation=state }
                    }
                    self.answers=[:]
                } catch { issue=error.localizedDescription }
            }
        } catch { issue=error.localizedDescription }
    }
    func preview(_ advice: AIAdvice, app: AppModel) {
        guard !running, !importing, !stale(app: app), let investigation else { return }
        importing=true
        Task {
            defer { importing=false }
            do {
                let service=try service(app: app)
                let record=try await service.importAdvice(investigationId: investigation.id, adviceId: advice.id)
                await app.refresh()
                guard !stale(app: app) else { return }
                review=record
            } catch { issue=error.localizedDescription }
        }
    }
}

struct AILaunchTarget: Identifiable {
    let path: String
    var id: String { path }
}
