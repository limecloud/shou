import Foundation
import Observation
import ShouCore
import ShouPlatform

@MainActor @Observable final class DeveloperLogCleanupSession {
    var plan: DeveloperLogCleanupPlan?
    var loading=false
    var clearing=false
    var failure: String?
    var accessRequirement: SystemAccessRequirement?
    var message: String?
    private var toolID=""
    private var path=""
    private var revision=0
    private var service: DeveloperLogCleanup?
    private var task: Task<Void,Never>?

    func configure(toolID: String, path: String) {
        guard !clearing, self.toolID != toolID || self.path != path else { return }
        task?.cancel(); revision += 1
        self.toolID=toolID; self.path=path; plan=nil; loading=false; failure=nil; accessRequirement=nil; message=nil; service=nil
    }
    func review() {
        guard !path.isEmpty, !loading, !clearing else { return }
        let current=revision
        let cleaner=DeveloperLogCleanup(platform:NativeDeveloperLogCleanup(toolID:toolID,target:.init(path:path,title:"Service Log")),makeStore:{ try LocalRecordStore() })
        loading=true; failure=nil; accessRequirement=nil; message=nil
        task=Task {
            defer { if revision == current { loading=false } }
            do {
                let value=try await cleaner.prepare()
                guard !Task.isCancelled, revision == current else { return }
                service=cleaner; plan=value
            } catch { if !Task.isCancelled, revision == current { failure="The log is empty, read-only or has changed. Refresh before clearing it."; accessRequirement=(error as? ShouError)?.accessRequirement } }
        }
    }
    func execute(app: AppModel, completed: @escaping () -> Void) {
        guard let service, let plan, !app.busy, !clearing,
              plan.inspection.toolID == toolID, plan.inspection.file.path == path else { return }
        self.plan=nil; clearing=true; app.busy=true; app.isExecuting=true; app.operationHadError=false
        task=Task {
            defer { clearing=false; app.busy=false; app.isExecuting=false }
            do {
                let result=try await service.execute(plan,confirmedID:plan.id)
                if result.state == "succeeded" { message="Log cleared. New entries may be written by the service."; completed() }
                else {
                    failure=result.state == "cancelled" ? "authorization_cancelled" : "The log cleanup result needs verification. Refresh before continuing."
                    accessRequirement=result.accessRequirement; app.operationHadError=true
                }
            } catch { failure="The log changed or cannot be cleared. Refresh and review it again."; accessRequirement=(error as? ShouError)?.accessRequirement; app.operationHadError=true }
        }
    }
    func stopReading() { if !clearing { task?.cancel() } }
    func waitForOperation() async { if clearing { await task?.value } }
}
