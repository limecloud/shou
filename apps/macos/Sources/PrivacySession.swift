import Foundation
import Observation
import ShouCore
import ShouPlatform

@MainActor @Observable final class PrivacySession {
    var scan: PrivacyScan?
    var range=PrivacyTimeRange.lastHour
    var selected=Set<String>()
    var plan: PrivacyPlan?
    var receipt: PrivacyReceipt?
    var history: [PrivacyReceipt]=[]
    var working=false
    var progress: ExecutionProgress?
    var allowCookieReview=false
    private var task: Task<Void, Never>?
    private var service: PrivacyService?
    private weak var application: AppModel?
    private var historyTask: Task<Void, Never>?
    private var operation=UUID()
    var selectedSources: [PrivacySource] { (scan?.sources ?? []).filter { selected.contains($0.id) } }
    var selectedCount: Int64 { selectedSources.reduce(0) { $0 + ($1.recordCount ?? 0) } }
    func cancel() { application?.stopRequested=true; task?.cancel(); historyTask?.cancel() }
    func waitForOperation() async { let pending=task, reading=historyTask; await pending?.value; await reading?.value }
    func loadHistory(app: AppModel) {
        guard let engine=app.engine, historyTask == nil else { return }
        historyTask=Task {
            defer { historyTask=nil }
            do {
                let service=await engine.privacyService(activity: NativeApplicationActivity(), sources: NativePrivacySources())
                history=try await service.history()
            } catch { if !(error is CancellationError) && (error as? ShouError)?.code != "cancelled" { show(error, app) } }
        }
    }
    func changeRange() { guard !working else { return }; scan=nil; selected=[]; plan=nil; receipt=nil; allowCookieReview=false }
    func scan(app: AppModel) {
        guard !app.busy, let engine=app.engine else { return }
        begin(app)
        let token=operation
        app.statusKey="Scanning…"
        task=Task {
            defer { finish(app) }
            do {
                let service=await engine.privacyService(activity: NativeApplicationActivity(), sources: NativePrivacySources())
                self.service=service
                let result=try await service.scan(range: range, progress: { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.working, self.operation == token, !app.isExecuting else { return }
                        self.progress=update
                    }
                })
                try Task.checkCancellation()
                scan=result; selected=[]; receipt=nil; allowCookieReview=false
                app.statusKey="Ready to review"
            } catch { show(error, app) }
        }
    }
    func review(app: AppModel) {
        guard !app.busy, let service, let scan, !selected.isEmpty else { return }
        begin(app)
        app.statusKey="Preparing cleanup preview…"
        task=Task {
            defer { finish(app) }
            do {
                plan=try await service.preparePlan(scanId: scan.id, sourceIDs: selected.sorted(), acknowledgeSignOut: allowCookieReview)
                app.statusKey="Ready to review"
            }
            catch { show(error, app) }
        }
    }
    func execute(app: AppModel, plan: PrivacyPlan, signOut: Bool) {
        guard !app.busy, let service else { return }
        self.plan=nil; begin(app)
        let execution=app.beginExecution(total: plan.sources.count, sources: true)
        task=Task {
            defer { app.isExecuting=false; finish(app) }
            do {
                receipt=try await service.execute(planId: plan.id, digest: plan.digest, consent: PrivacyConsent(irreversibleDeletion: true, signOut: signOut), progress: { update in
                    Task { @MainActor in app.updateExecutionProgress(update, operation: execution) }
                })
                app.operationHadError=receipt?.state != "completed"
                app.statusKey=receipt?.state == "completed" ? "Privacy cleaning completed" : "Some sources were not cleaned"
                history=try await service.history()
                selected=[]; scan=nil
            } catch { show(error, app) }
        }
    }
    private func begin(_ app: AppModel) { application=app; operation=UUID(); working=true; progress=nil; app.busy=true; app.error=nil; app.stopRequested=false; app.executionProgress=nil; app.operationHadError=false }
    private func finish(_ app: AppModel) { working=false; app.busy=false; app.stopRequested=false; app.executionProgress=nil; task=nil }
    private func show(_ error: Error, _ app: AppModel) {
        if error is CancellationError || (error as? ShouError)?.code == "cancelled" { app.statusKey="Privacy operation stopped."; return }
        app.operationHadError=true
        app.statusKey="Privacy operation failed."
        app.error=app.diagnostic((error as? ShouError)?.message ?? "Privacy operation failed.")
    }
}
