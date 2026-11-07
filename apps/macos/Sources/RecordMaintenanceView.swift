import ShouCore
import SwiftUI

struct RecordMaintenanceButton: View {
    var model: AppModel
    @State private var presented=false
    var body: some View {
        Button(model.t("Shou storage…")) { presented=true }
            .disabled(model.busy).accessibilityIdentifier("settings.clean-scan-records")
            .sheet(isPresented: $presented) { RecordMaintenanceView(model: model) }
    }
}

private struct RecordMaintenanceView: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var preview: RecordRetentionPreview?
    @State private var keepLatest=true
    @State private var loading=false
    @State private var issue: String?
    @State private var collectedBytes: Int64?
    private var policy: RecordRetentionPolicy { .init(keepLatestScans: keepLatest) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t("Shou storage")).font(ShouType.title.weight(.semibold))
            Text(model.t("Scan indexes, plans and recovery dependencies are reviewed separately from your files."))
                .font(ShouType.body).foregroundStyle(ShouPalette.secondary)
            Toggle(model.t("Keep the latest scan for later inspection"), isOn: $keepLatest).disabled(loading)
                .onChange(of: keepLatest) { _, _ in preview=nil; load() }
            if loading { ProgressView().controlSize(.small) }
            if let preview {
                HStack {
                    Text(model.t("Total") + " " + model.bytes(preview.totalBytes))
                    Spacer()
                    Text(model.t("Reviewable records") + " " + model.bytes(preview.removableBytes))
                }.font(ShouType.body).monospacedDigit()
                if preview.quotaExcessBytes > 0 {
                    Label(model.t("Protected records exceed the cleanup quota.") + " " + model.bytes(preview.quotaExcessBytes), systemImage: "info.circle")
                        .font(ShouType.caption).foregroundStyle(ShouPalette.warning)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(preview.collections) { collection in
                            HStack {
                                Text(collectionTitle(collection.collection))
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(model.bytes(collection.totalBytes))
                                    Text(model.t("Reviewable records") + " " + model.bytes(collection.removableBytes)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                                }
                            }.font(ShouType.body)
                            Divider()
                        }
                        Text(model.t("Why records are kept")).font(ShouType.body.weight(.medium))
                        ForEach(preview.retentionReasons) { reason in
                            HStack { Text(reasonTitle(reason.reason)); Spacer(); Text(model.bytes(reason.byteCount)).monospacedDigit() }.font(ShouType.caption)
                        }
                        Text(model.t("Retention reasons can overlap. Recovery and active plans remain protected."))
                            .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    }
                }
                if !preview.issues.isEmpty { Text(model.t("Some records need verification and were kept.")).foregroundStyle(ShouPalette.warning) }
            }
            if let collectedBytes { Text(model.t("Records removed") + " " + model.bytes(collectedBytes)).font(ShouType.body).foregroundStyle(ShouPalette.success) }
            if let issue { Text(issue).font(ShouType.caption).foregroundStyle(ShouPalette.danger) }
            HStack {
                Button(model.t("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.t("Check Again")) { load() }.disabled(loading)
                Button(model.t("Delete reviewed records"), role: .destructive) { collect() }
                    .buttonStyle(.borderedProminent).tint(ShouPalette.danger)
                    .disabled(loading || preview?.records.isEmpty != false)
            }
        }.padding(24).frame(width: 650, height: 560).task { load() }
    }
    private func load() {
        guard !loading, let engine=model.engine else { return }
        loading=true; issue=nil
        let policy=policy
        Task {
            defer { loading=false }
            do { preview=try await engine.recordRetentionPreview(policy: policy) }
            catch { issue=error.localizedDescription }
        }
    }
    private func collect() {
        guard !loading, let engine=model.engine, let preview else { return }
        let reviewed=preview.records, policy=policy
        loading=true; issue=nil
        Task {
            defer { loading=false }
            do {
                let result=try await engine.collectRecords(policy: policy, reviewedRecords: reviewed)
                collectedBytes=result.removableBytes
                self.preview=try await engine.recordRetentionPreview(policy: policy)
            } catch { issue=error.localizedDescription; self.preview=nil }
        }
    }
    private func collectionTitle(_ value: String) -> String {
        model.t(["storage-catalogs":"Space indexes", "storage-scans":"Space scans", "storage-plan-manifests":"Plan file lists", "storage-plans":"Space cleanup plans", "history-manifests":"Recovery file lists", "history-summaries":"History summaries", "scans":"Cleanup scans", "plans":"Cleanup plans"][value] ?? value)
    }
    private func reasonTitle(_ value: String) -> String {
        model.t(["active_plan":"Active plan dependency", "grace_period":"Recently created", "latest_scan":"Latest scan", "history_dependency":"History dependency", "recovery_dependency":"Recovery dependency", "within_policy":"Within retention policy", "verification_required":"Needs verification"][value] ?? value)
    }
}
