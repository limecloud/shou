import Foundation
import Observation
import ShouCore
import ShouPlatform

@MainActor @Observable final class DeveloperConfigurationSession {
    var toolID=""
    var targets=[DeveloperConfigurationTarget]()
    var targetID=""
    var document: DeveloperConfigurationDocument?
    var text=""
    var loading=false
    var discovering=false
    var saving=false
    var reviewing=false
    var failure: String?
    var message: String?
    var logTargets=[DeveloperLogTarget]()
    var logID=""
    var logText: String?
    var logLoading=false
    var logFailure: String?
    let logCleanup=DeveloperLogCleanupSession()
    var mutating: Bool { saving || logCleanup.clearing }
    private var services=[DeveloperService]()
    private var sourceLogs=[DeveloperLogTarget]()
    private var discoveryTask: Task<Void,Never>?
    private var discoveryRevision=0
    private var task: Task<Void,Never>?
    private var logTask: Task<Void,Never>?
    private var revision=0

    func update(toolID: String, installations: [DeveloperToolInstallation], services: [DeveloperService]) {
        if self.toolID != toolID {
            task?.cancel(); logTask?.cancel(); revision += 1
            self.toolID=toolID; targetID=""; targets=[]; document=nil; text=""; reviewing=false
            loading=false; logLoading=false; logText=nil; logID=""; logTargets=[]; sourceLogs=[]; failure=nil; message=nil; logFailure=nil
            logCleanup.configure(toolID:toolID,path:"")
        }
        self.services=services
        discoveryTask?.cancel(); discoveryRevision += 1
        let request=discoveryRevision
        discovering=true
        discoveryTask=Task {
            let work=Task.detached(priority:.utility) {
                let resolver=NativeDeveloperConfiguration()
                return (resolver.targets(toolID:toolID,installations:installations,services:services),
                        resolver.logs(toolID:toolID,document:nil,services:services,installations:installations))
            }
            let (values,logs)=await work.value
            guard !Task.isCancelled, request == discoveryRevision, self.toolID == toolID else { return }
            targets=values + targets.filter { old in
                !values.contains { $0.path == old.path } && (old.source == "Selected File" || old.path == targetID && document != nil)
            }
            sourceLogs=logs; discovering=false
            if !targets.contains(where:{ $0.path == targetID }), !saving { targetID=""; document=nil; text="" }
            if targetID.isEmpty, let first=targets.first { select(first.path) }
            updateLogs()
        }
    }
    func select(_ path: String) {
        guard !saving else { return }
        if !targets.contains(where: { $0.path == path }) { targets.append(.init(path:path,source:"Selected File")) }
        revision += 1; let current=revision
        targetID=path; task?.cancel(); document=nil; text=""; failure=nil; message=nil; reviewing=false; loading=true
        task=Task {
            let work=Task.detached(priority:.utility) { try NativeDeveloperConfigurationFiles().read(path) }
            do {
                let value=try await work.value
                guard !Task.isCancelled, revision == current else { return }
                document=value; text=value.text; updateLogs()
            } catch { if !Task.isCancelled, revision == current { failure="The configuration file could not be read. Select its exact path or check access permissions." } }
            if revision == current { loading=false }
        }
    }
    var canSave: Bool {
        guard let document else { return false }
        return document.writable && text != document.text && !loading && !saving && !hasRunningLocalInstance
    }
    var hasRunningLocalInstance: Bool {
        services.contains { $0.source == "Local instance" && $0.configurationPath == targetID && $0.state != "stopped" }
    }
    func save(app: AppModel, completed: @escaping () -> Void) {
        guard let document, canSave, reviewing, !app.busy else { return }
        let edited=text
        reviewing=false; saving=true; app.busy=true; app.isExecuting=true; app.operationHadError=false
        task=Task {
            defer { saving=false; app.busy=false; app.isExecuting=false }
            do {
                let work=Task.detached { try NativeDeveloperConfigurationFiles().save(edited,expected:document) }
                self.document=try await work.value
                message="Configuration saved."; updateLogs()
                app.busy=false; app.isExecuting=false; completed()
            } catch { failure="The configuration changed or could not be saved. Reload the file before trying again."; app.operationHadError=true }
        }
    }
    func readLog() {
        guard !logID.isEmpty else { return }
        logTask?.cancel(); logLoading=true; logFailure=nil; logText=nil; logCleanup.plan=nil
        let path=logID, current=revision
        logTask=Task {
            let work=Task.detached(priority:.utility) { try NativeDeveloperConfigurationFiles().log(path:path) }
            do {
                let value=try await work.value
                guard !Task.isCancelled, revision == current, logID == path else { return }
                logText=value
            } catch { if !Task.isCancelled, revision == current, logID == path { logFailure="The service log cannot be read. Check its path and access permissions." } }
            if revision == current, logID == path { logLoading=false }
        }
    }
    func stop() { discoveryTask?.cancel(); if !saving { task?.cancel() }; logTask?.cancel(); logCleanup.stopReading() }
    func waitForOperation() async { if saving { await task?.value }; await logCleanup.waitForOperation() }
    private func updateLogs() {
        var seen=Set<String>()
        logTargets=(NativeDeveloperConfiguration().logs(toolID:toolID,document:document,services:[]) + sourceLogs).filter { seen.insert($0.path).inserted }
        if !logTargets.contains(where: { $0.path == logID }) { logID=logTargets.first?.path ?? ""; logText=nil; logCleanup.configure(toolID:toolID,path:logID) }
    }
}
