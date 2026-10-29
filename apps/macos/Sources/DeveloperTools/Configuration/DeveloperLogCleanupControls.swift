import SwiftUI

struct DeveloperLogCleanupControls: View {
    @Bindable var model: AppModel
    @Bindable var session: DeveloperLogCleanupSession
    let toolID: String
    let path: String
    let canReview: Bool
    let completed: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            if let plan=session.plan {
                Text(plan.inspection.file.path).font(ShouType.caption).textSelection(.enabled)
                Text(model.t("Permanently clear this log's contents? The file will be kept."))
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount:plan.inspection.file.allocatedBytes,countStyle:.file)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    Spacer()
                    Button(model.t("Cancel")) { session.plan=nil }
                    Button(model.t("Permanently Clear")) { session.execute(app:model,completed:completed) }
                        .buttonStyle(.borderedProminent).tint(ShouPalette.danger).disabled(model.busy)
                        .accessibilityIdentifier("developer.logs.confirm-clear")
                }
            } else {
                HStack {
                    if session.loading || session.clearing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(model.t("Clear Log…")) { session.review() }.tint(ShouPalette.danger)
                        .disabled(model.busy || !canReview || path.isEmpty || session.loading)
                        .accessibilityIdentifier("developer.logs.review-clear")
                }
            }
            if let failure=session.failure { Text(model.t(failure)).foregroundStyle(ShouPalette.secondary) }
            if let requirement=session.accessRequirement {
                AccessRecoveryControls(model:model,requirement:requirement) { session.review() }
            }
            if let message=session.message { Text(model.t(message)).foregroundStyle(ShouPalette.secondary) }
        }
        .onAppear { session.configure(toolID:toolID,path:path) }
        .onChange(of:path) { session.configure(toolID:toolID,path:path) }
        .onChange(of:toolID) { session.configure(toolID:toolID,path:path) }
    }
}
