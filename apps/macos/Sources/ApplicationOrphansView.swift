import ShouCore
import ShouPlatform
import SwiftUI

struct ApplicationOrphansView: View {
    var model: AppModel
    var onReviewCoverage: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var review: ApplicationOrphanReview?
    @State private var selected=Set<String>()
    @State private var includePersonalData=false
    @State private var loading=false
    @State private var issue: String?
    @State private var incompleteInventory=false
    @State private var operation: Task<Void,Never>?
    private var eligible: [UninstallComponent] { review?.components.filter { $0.eligible && (!$0.requiresUserDataConsent || includePersonalData) } ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(model.t("Application Leftovers"), systemImage: "app.badge.checkmark").font(.title2.bold())
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button(model.t("Scan Again")) { load() }.disabled(loading || model.busy)
            }
            Text(model.t("Review data associated with apps no longer found in application folders or system registration. Unregistered custom installations may still use this data.")).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(model.t("Select All")) { selected=Set(eligible.map(\.id)) }.disabled(loading)
                Button(model.t("Deselect All")) { selected=[] }
                Spacer()
                Toggle(model.t("Include personal application data"), isOn: $includePersonalData).toggleStyle(.checkbox)
            }.font(.callout).disabled(loading)
            List(review?.components ?? []) { component in
                HStack {
                    Toggle("", isOn: Binding(get: { selected.contains(component.id) }, set: { if $0 { selected.insert(component.id) } else { selected.remove(component.id) } }))
                        .labelsHidden().disabled(!eligible.contains { $0.id == component.id })
                    VStack(alignment: .leading, spacing: 4) {
                        Text(component.origin?.bundleIdentifier ?? URL(fileURLWithPath: component.path).lastPathComponent).font(.callout.weight(.medium))
                        Text(component.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(component.path)
                        if !component.reasons.isEmpty { Text(component.reasons.map(model.t).joined(separator: " · ")).font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    Text(model.t(component.kind.rawValue)).font(.caption).foregroundStyle(.secondary)
                    Text(model.bytes(component.allocatedBytesEstimate)).monospacedDigit().frame(width: 86, alignment: .trailing)
                }.padding(.vertical, 5)
            }.disabled(loading).overlay { if review?.components.isEmpty == true { ContentUnavailableView(model.t("No verified application leftovers found."), systemImage: "checkmark.circle") } }
            if let issue {
                HStack {
                    Text(model.t(issue)).font(.caption).foregroundStyle(.red)
                    if incompleteInventory {
                        Button(model.t("View Coverage…")) { onReviewCoverage(); dismiss() }
                    }
                }
            }
            Text(model.t("Selected files are permanently removed. Personal data cannot be restored.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(model.bytes(eligible.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.allocatedBytesEstimate })).font(.headline)
                Spacer()
                Button(model.t("Back")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(role: .destructive) { prepare() } label: {
                    Label(model.t("Delete Permanently"), systemImage: "trash")
                        .font(.headline).frame(minWidth: ShouDesign.primaryActionMinWidth, minHeight: ShouDesign.primaryActionContentMinHeight)
                }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                    .help(model.t("Permanent deletion cannot be undone."))
                    .accessibilityHint(model.t("Permanent deletion cannot be undone."))
                    .disabled(loading || selected.isEmpty || model.busy)
            }
        }.padding(22).frame(width: 800, height: 600)
            .onAppear { load() }.onDisappear { operation?.cancel() }
            .onChange(of: includePersonalData) { _, enabled in if !enabled { selected.formIntersection(Set(eligible.map(\.id))) } }

    }
    private func load() {
        guard !loading, let engine=model.engine else { return }
        loading=true; issue=nil; incompleteInventory=false
        operation=Task {
            defer { loading=false }
            do {
                let current=try await engine.reviewApplicationOrphans(presence: NativeApplicationAbsence())
                guard !Task.isCancelled else { return }
                review=current; selected=Set(current.components.filter { $0.eligible && !$0.requiresUserDataConsent && (model.orphanRetryPaths.isEmpty || model.orphanRetryPaths.contains($0.path)) }.map(\.id))
            } catch {
                if !Task.isCancelled {
                    issue=error.localizedDescription
                    incompleteInventory=(error as? ShouError)?.details["reason"] == "application_inventory_incomplete"
                }
            }
        }
    }
    private func prepare() {
        guard let engine=model.engine, let review, !loading, !model.busy, !selected.isEmpty else { return }
        let componentIds=Array(selected), consent=includePersonalData
        loading=true
        operation=Task {
            defer { loading=false }
            do {
                let plan=try await engine.createApplicationOrphanPlan(reviewId: review.id, componentIds: componentIds, includeUserData: consent)
                try Task.checkCancellation()
                model.executeApplicationOrphans(plan)
                dismiss()
            }
            catch { issue=error.localizedDescription }
        }
    }
}
