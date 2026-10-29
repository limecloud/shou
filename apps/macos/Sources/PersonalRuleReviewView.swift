import SwiftUI
import ShouCore

/// One rule is one decision. Preview never enables other drafts or deletes files.
struct PersonalRuleReviewView: View {
    var model: AppModel
    let record: RuleRecord
    @Environment(\.dismiss) private var dismiss
    @State private var preview: ScanSnapshot?
    @State private var rows=[PersonalRulePreviewRow]()
    @State private var benefits: RulePreviewBenefits?
    @State private var issue: String?
    @State private var loading=false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(record.rule.name, systemImage: "doc.text.magnifyingglass").font(ShouType.title.bold())
            Text(record.id).font(ShouType.caption.monospaced()).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
            Text(record.rule.description).font(ShouType.body)
            Text(record.rule.risk.rebuildNote).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
            ForEach(record.rule.risk.limitations, id: \.self) { Text(model.t($0)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
            DisclosureGroup(model.t("Scope & Retention")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.rule.match.relativePatterns.joined(separator: "\n"))
                    if !record.rule.exclude.relativePatterns.isEmpty {
                        Text(model.t("Exclusions") + ": " + record.rule.exclude.relativePatterns.joined(separator: ", "))
                    }
                }.font(ShouType.caption.monospaced()).textSelection(.enabled)
            }
            if loading {
                ProgressView(model.status).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let preview {
                HStack {
                    VStack(alignment: .leading) {
                        Text(model.t("Additional Cleanup Estimate")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                        Text(benefits.map { model.bytes($0.additionalAllocatedBytesEstimate) } ?? model.t("Calculating…")).font(ShouType.title.weight(.semibold)).monospacedDigit()
                    }
                    Spacer()
                    Text(String(format: model.t("%lld matching, %lld protected, %lld outside conditions"), rows.filter { $0.status == "matched" }.count,
                                rows.filter { $0.status == "blocked" }.count, rows.filter { $0.status == "not_matched" }.count)).font(ShouType.body)
                }
                if preview.status != "complete" {
                    Text(model.t("Partial preview. Unreadable or time-limited locations are listed below; this is not full coverage.")).font(ShouType.caption).foregroundStyle(ShouPalette.warning)
                }
                List(rows.prefix(200)) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.path).lineLimit(1).truncationMode(.middle).help(row.path)
                            Spacer()
                            Text(model.bytes(row.allocatedBytes)).monospacedDigit()
                        }
                        Text(row.status == "matched" ? model.t("Ready to review") : row.reasons.map(model.diagnostic).joined(separator: ", "))
                            .font(ShouType.caption).foregroundStyle(row.status == "matched" ? ShouPalette.secondary : ShouPalette.warning)
                    }.padding(.vertical, 3)
                }.accessibilityIdentifier("rules.review.results")
                if !preview.issues.isEmpty {
                    DisclosureGroup(model.t("Coverage Issues")) {
                        ScrollView { Text(preview.issues.map(model.diagnostic).joined(separator: "\n")).font(ShouType.caption).textSelection(.enabled) }.frame(maxHeight: 70)
                    }
                }
            } else { Spacer() }
            if let issue { Text(model.diagnostic(issue)).font(ShouType.caption).foregroundStyle(ShouPalette.danger) }
            Text(model.t("Only this rule will be enabled and scanned. Review the current files before confirming deletion. Other drafts keep their choices."))
                .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            HStack {
                Button(model.t("Preview Again")) { load() }.disabled(model.busy || loading)
                Spacer()
                Button(model.t(loading ? "Stop" : "Keep Current Choice")) {
                    if loading { model.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button(model.t("Enable & Scan This Rule")) {
                    guard let preview else { return }
                    model.enableAndScanRule(record, preview: preview); dismiss()
                }.buttonStyle(.borderedProminent).disabled(preview == nil || benefits == nil || loading || model.busy)
                    .accessibilityIdentifier("rules.review.enable-scan")
            }
        }.padding(24).frame(width: 760, height: 520)
            .task { load() }
            .interactiveDismissDisabled(loading)
            .onDisappear { if loading { model.cancel() } }
    }

    private func load() {
        guard !model.busy, !loading, let root=model.configuration.workspaces.first(where: { $0.rootRef == record.rule.scope.rootRef }) else { return }
        do {
            let data=try Codec.encode(record.rule)
            loading=true; preview=nil; benefits=nil; rows=[]; issue=nil
            model.previewRuleDraft(data, workspaceId: root.id) { result in
                loading=false
                switch result {
                case .success(let value):
                    preview=value.0; rows=value.1
                    Task {
                        do { benefits=try await model.previewBenefits(scanId: value.0.id) }
                        catch { issue=error.localizedDescription }
                    }
                case .failure(let error): issue=error.localizedDescription
                }
            }
        } catch { issue=error.localizedDescription }
    }
}
