import SwiftUI
import ShouCore

struct HistoryInspectionRequest: Identifiable { let id: String }

struct HistoryInspectionView: View {
    var model: AppModel
    let executionId: String
    @Environment(\.dismiss) private var dismiss
    @State private var report: HistoryInspection?
    @State private var issue: String?
    @State private var checking=true
    @State private var revision=UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t("Verify Cleanup Locations")).font(ShouType.title.bold())
            Text(model.t("Checks only the exact saved paths and directory manifests. Files and receipts stay unchanged.")).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
            Text(executionId).font(ShouType.caption.monospaced()).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
            if checking {
                ActivityIndicator(title: model.t("Verifying recorded locations…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report {
                if report.unfinished {
                    Label(model.t("This record has unfinished actions. Verification does not retry them or authorize another operation."), systemImage: "exclamationmark.triangle")
                        .font(ShouType.body).foregroundStyle(ShouPalette.warning).fixedSize(horizontal: false, vertical: true)
                }
                Text(model.date(report.checkedAt)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(report.items) { item in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(item.relativePath).font(ShouType.body.monospaced().bold()).textSelection(.enabled)
                                Label(model.t(label(item.state)), systemImage: ["needs_verification", "missing", "restore_conflict"].contains(item.state) ? "exclamationmark.triangle" : "checkmark.circle")
                                    .font(ShouType.body).foregroundStyle(["needs_verification", "missing", "restore_conflict"].contains(item.state) ? ShouPalette.warning : ShouPalette.text)
                                observation(item.original, title: "Original Location")
                                observation(item.trash, title: "Recorded Trash Location")
                                if item.followUp?.state == "pending" {
                                    Text(model.t("Follow-up needs verification")).font(ShouType.caption).foregroundStyle(ShouPalette.warning)
                                }
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                Text(model.t("These observations describe this check only. Unknown outcomes stay blocked; review History before any confirmed action.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            } else if let issue {
                ContentUnavailableView { Label(model.t("Verification unavailable"), systemImage: "exclamationmark.triangle") }
                    description: { Text(model.diagnostic(issue)) }
            }
            HStack {
                Button(model.t("Check Again")) { revision=UUID() }.disabled(checking)
                Spacer()
                Button(model.t("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 760, height: 520)
            .task(id: revision) {
                checking=true; issue=nil; report=nil
                defer { checking=false }
                guard let engine=model.engine else { issue="Local store is unavailable."; return }
                do { report=try await engine.inspectHistory(executionId: executionId) }
                catch { if !Task.isCancelled { issue=error.localizedDescription } }
            }
    }

    private func observation(_ value: HistoryObjectObservation, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(model.t(title)).font(ShouType.caption.bold()); Spacer(); Text(model.t(observationLabel(value.state))).font(ShouType.caption) }
            if let path=value.path { Text(path).font(ShouType.caption.monospaced()).foregroundStyle(ShouPalette.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if let issue=value.issue { Text(model.diagnostic(issue)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
        }
    }
    private func label(_ state: String) -> String {
        switch state {
        case "verified_trash": "Recorded Trash object matches"
        case "verified_original": "Recorded object is at its original path"
        case "restore_conflict": "Restore destination is occupied"
        case "restored": "Restored object matches"
        case "purged": "Removal recorded; Trash object is absent"
        case "missing": "Recorded object could not be located"
        default: "Needs verification"
        }
    }
    private func observationLabel(_ state: String) -> String {
        switch state {
        case "matches": "Manifest matches"
        case "missing": "Not present"
        case "changed": "Manifest changed"
        case "not_recorded": "No path was recorded"
        default: "Could not verify"
        }
    }
}
