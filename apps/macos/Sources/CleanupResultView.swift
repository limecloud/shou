import SwiftUI
import ShouCore
import Accessibility

/// A completion page keeps the successful path calm. Detailed rows are an
/// exception path behind one disclosure, while incomplete results keep a
/// direct route to History and a fresh scan.
struct CleanupResultView: View {
    @Bindable var model: AppModel
    let result: CleanupCompletion
    @ReduceMotion private var reduceMotion
    @State private var appeared=false
    @State private var showDetails=false
    @State private var expandedPaths=Set<String>()

    private struct ItemOutcome: Identifiable {
        let id: String
        let item: ItemReceipt
        let state: ResultState
    }
    private var outcomes: [ItemOutcome] {
        result.receipts.flatMap { receipt in
            receipt.items.map { ItemOutcome(id: receipt.id + "/" + $0.id, item: $0, state: ResultState($0.state, executionState: receipt.state)) }
        } + result.skippedItems.map { ItemOutcome(id: $0.id, item: $0, state: .skipped) }
    }
    private var items: [ItemReceipt] { outcomes.map(\.item) }
    private var moved: Int { outcomes.filter { $0.state == .moved }.count }
    private var purged: Int { outcomes.filter { $0.state == .purged }.count }
    private var skipped: Int { outcomes.filter { $0.state == .skipped }.count }
    private var failed: Int { outcomes.filter { $0.state == .failed }.count }
    private var unverified: Int { outcomes.filter { $0.state == .unverified }.count }
    private var permanent: Bool { result.receipts.contains { ["permanent_cleanup", "storage_permanent_removal", "application_permanent_uninstall", "application_batch_permanent_uninstall"].contains($0.operation ?? "") } }
    private var complete: Bool { result.failures.isEmpty && !items.isEmpty && result.receipts.allSatisfy { $0.state == "completed" } && moved + purged == items.count }
    private var cancelled: Bool { result.failures.isEmpty && failed == 0 && unverified == 0 && result.receipts.contains { $0.state == "cancelled" } }
    private var hasIssues: Bool { !complete }
    private var detailsVisible: Bool { showDetails || items.isEmpty || !result.skippedItems.isEmpty }
    private var title: String {
        if result.receipts.isEmpty { return model.t("Cleanup could not start") }
        return model.t(complete ? "Cleanup complete" : result.receipts.contains { $0.state == "executing" } ? "Unfinished cleanup" : result.receipts.contains { $0.state == "cancelled" } ? "Cleanup stopped" : "Cleanup finished with issues")
    }
    private var totalBytes: Int64 {
        result.receipts.reduce(0) { $0 + (permanent ? $1.permanentlyRemovedBytesEstimate : $1.trashedBytesEstimate) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            Image(systemName: complete ? "checkmark.circle" : cancelled ? "pause.circle" : "exclamationmark.triangle")
                .font(.system(size: ShouDesign.completionIconSize, weight: .light))
                .foregroundStyle(complete ? ShouPalette.success : cancelled ? ShouPalette.secondary : ShouPalette.warning)
                .scaleEffect(reduceMotion || appeared ? 1 : 0.84)
                .opacity(reduceMotion || appeared ? 1 : 0)
                .accessibilityHidden(true)
            Text(title).font(ShouType.title.bold()).padding(.top, 18).accessibilityAddTraits(.isHeader)
            if let date=result.receipts.first?.createdAt {
                Text(model.date(date)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).padding(.top, 5)
            }

            if !result.receipts.isEmpty {
                Text(model.bytes(totalBytes))
                    .font(.system(size: ShouDesign.completionFigureSize, weight: .semibold, design: .rounded))
                    .monospacedDigit().padding(.top, 28)
            }
            Text(model.t(cancelled ? "Removal stopped. Items not moved are kept in their original locations." : complete ? (permanent ? "Permanently removed; this cannot be undone." : "Moved to Trash; this is not freed space.") : "Some items could not be removed. Review the result."))
                .font(ShouType.body).foregroundStyle(ShouPalette.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)

            if hasIssues {
                if !items.isEmpty { issueSummary.padding(.top, 22) }
                if detailsVisible {
                    details.padding(.top, 12)
                } else {
                    Button(model.t("Details")) { withAnimation(reduceMotion ? nil : .easeOut(duration: Double(ShouDesign.transitionDuration))) { showDetails=true } }
                        .buttonStyle(.link).padding(.top, 8)
                }
            }

            Spacer(minLength: hasIssues && detailsVisible ? 14 : 28)
            HStack(spacing: 10) {
                if hasIssues {
                    Button(model.t("Scan Again")) { model.retryAfterCleanup(result) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("r", modifiers: [.command])
                        .accessibilityIdentifier("cleanup.result.scan-again")
                }
                if hasIssues && !result.receipts.isEmpty {
                    Button(model.t("View History")) { model.completion=nil; model.section="history" }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("cleanup.result.history")
                }
                Spacer(minLength: 8)
                Button(model.t("Back")) { model.completion=nil; model.section=result.sourceSection }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("cleanup.result.close")
            }
        }
        .padding(ShouDesign.completionPadding)
        .frame(maxWidth: ShouDesign.completionMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { model.completion=nil; model.section=result.sourceSection }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: Double(ShouDesign.transitionDuration))) { appeared=true }
            AccessibilityNotification.Announcement(title).post()
        }
    }

    private var issueSummary: some View {
        HStack(spacing: 10) {
            resultMetric(model.t(permanent ? "Permanently removed" : "Moved"), value: permanent ? purged : moved, color: ShouPalette.success)
            resultMetric(model.t("Skipped"), value: skipped, color: .secondary)
            resultMetric(model.t("Failed items"), value: failed, color: failed > 0 ? ShouPalette.danger : ShouPalette.secondary)
            resultMetric(model.t("Needs verification"), value: unverified, color: unverified > 0 ? ShouPalette.warning : ShouPalette.secondary)
        }.frame(maxWidth: ShouDesign.completionMetricsWidth)
    }

    private var details: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                    Label(model.diagnostic(failure), systemImage: "exclamationmark.triangle")
                        .font(ShouType.caption).foregroundStyle(ShouPalette.warning).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                ForEach(outcomes.filter { $0.state != .moved && $0.state != .purged }) { outcome in
                    resultRow(outcome.item, state: outcome.state)
                    if outcome.id != outcomes.last?.id { Divider().padding(.leading, 34) }
                }
            }
        }
        .frame(maxHeight: ShouDesign.completionDetailsHeight)
        .background(.quaternary.opacity(0.26), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ShouPalette.border, lineWidth: ShouDesign.hairlineWidth) }
    }

    private func resultMetric(_ label: String, value: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value.formatted(.number.locale(model.language.locale)))
                .font(ShouType.body.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 52).padding(.vertical, 6)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private func resultRow(_ item: ItemReceipt, state: ResultState) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: state.symbol).foregroundStyle(state.color).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(URL(fileURLWithPath: item.originalPath).lastPathComponent).font(ShouType.body.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 6)
                    if ["trashed", "purged"].contains(item.state) { Text(model.bytes(item.allocatedBytesEstimate)).font(ShouType.caption.monospacedDigit()).foregroundStyle(ShouPalette.secondary) }
                }
                Text(model.t(state.label)).font(ShouType.caption).foregroundStyle(state.color)
                if let error=item.error, !error.isEmpty { Text(model.diagnostic(error)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).lineLimit(2).help(model.diagnostic(error)) }
                if let requirement=item.accessRequirement { AccessRecoveryControls(model:model,requirement:requirement) }
                DisclosureGroup(isExpanded: Binding(get: { expandedPaths.contains(item.id) }, set: { expanded in
                    if expanded { expandedPaths.insert(item.id) } else { expandedPaths.remove(item.id) }
                })) {
                    Text(item.originalPath).font(.system(size: ShouDesign.captionFontSize, design: .monospaced))
                        .foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text(model.t("Path")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                }
            }
        }.padding(10)
    }

    private enum ResultState: Equatable {
        case moved, purged, skipped, failed, unverified
        init(_ state: String, executionState: String) {
            switch state {
            case "trashed": self = .moved
            case "purged": self = .purged
            case "skipped": self = .skipped
            case "pending" where executionState != "executing": self = .skipped
            case "failed": self = .failed
            default: self = .unverified
            }
        }
        var label: String {
            switch self { case .moved: "Moved to Trash"; case .purged: "Permanently removed"; case .skipped: "Skipped"; case .failed: "Failed"; case .unverified: "Needs verification" }
        }
        var symbol: String {
            switch self { case .moved, .purged: "checkmark.circle.fill"; case .skipped: "minus.circle"; case .failed: "xmark.circle.fill"; case .unverified: "questionmark.circle.fill" }
        }
        var color: Color {
            switch self { case .moved: ShouPalette.success; case .purged, .failed: ShouPalette.danger; case .skipped: ShouPalette.secondary; case .unverified: ShouPalette.warning }
        }
    }
}
