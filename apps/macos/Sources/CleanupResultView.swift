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

    private struct ItemOutcome: Identifiable {
        let id: String
        let item: ItemReceipt
        let state: ResultState
    }
    private var outcomes: [ItemOutcome] {
        result.receipts.flatMap { receipt in
            receipt.items.map { ItemOutcome(id: receipt.id + "/" + $0.id, item: $0, state: ResultState($0.state, executionState: receipt.state)) }
        }
    }
    private var items: [ItemReceipt] { outcomes.map(\.item) }
    private var moved: Int { outcomes.filter { $0.state == .moved }.count }
    private var purged: Int { outcomes.filter { $0.state == .purged }.count }
    private var skipped: Int { outcomes.filter { $0.state == .skipped }.count }
    private var failed: Int { outcomes.filter { $0.state == .failed }.count }
    private var unverified: Int { outcomes.filter { $0.state == .unverified }.count }
    private var permanent: Bool { result.receipts.contains { ["permanent_cleanup", "storage_permanent_removal", "application_permanent_uninstall", "application_batch_permanent_uninstall"].contains($0.operation ?? "") } }
    private var complete: Bool { result.failures.isEmpty && !items.isEmpty && result.receipts.allSatisfy { $0.state == "completed" } && moved + purged == items.count }
    private var hasIssues: Bool { !complete }
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
            Image(systemName: complete ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 78, weight: .light))
                .foregroundStyle(complete ? Color.green : Color.orange)
                .scaleEffect(reduceMotion || appeared ? 1 : 0.84)
                .opacity(reduceMotion || appeared ? 1 : 0)
                .accessibilityHidden(true)
            Text(title).font(.title.bold()).padding(.top, 18).accessibilityAddTraits(.isHeader)
            if let date=result.receipts.first?.createdAt {
                Text(model.date(date)).font(.caption).foregroundStyle(.secondary).padding(.top, 5)
            }

            if !result.receipts.isEmpty {
                Text(model.bytes(totalBytes))
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .monospacedDigit().padding(.top, 28)
            }
            Text(model.t(complete ? (permanent ? "Permanently removed; this cannot be undone." : "Moved to Trash; this is not freed space.") : "Some items could not be removed. Review the result."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)

            if hasIssues {
                if !items.isEmpty { issueSummary.padding(.top, 22) }
                if showDetails || items.isEmpty {
                    details.padding(.top, 12)
                } else {
                    Button(model.t("Details")) { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { showDetails=true } }
                        .buttonStyle(.link).padding(.top, 8)
                }
            }

            Spacer(minLength: hasIssues && showDetails ? 14 : 28)
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
        .padding(30)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { model.completion=nil; model.section=result.sourceSection }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { appeared=true }
            AccessibilityNotification.Announcement(title).post()
        }
    }

    private var issueSummary: some View {
        HStack(spacing: 10) {
            resultMetric(model.t(permanent ? "Permanently removed" : "Moved"), value: permanent ? purged : moved, color: .green)
            resultMetric(model.t("Skipped"), value: skipped, color: .secondary)
            resultMetric(model.t("Failed items"), value: failed, color: failed > 0 ? .red : .secondary)
            resultMetric(model.t("Needs verification"), value: unverified, color: unverified > 0 ? .orange : .secondary)
        }.frame(maxWidth: 560)
    }

    private var details: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                    Label(model.diagnostic(failure), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                ForEach(outcomes.filter { $0.state != .moved && $0.state != .purged }) { outcome in
                    resultRow(outcome.item, state: outcome.state)
                    if outcome.id != outcomes.last?.id { Divider().padding(.leading, 34) }
                }
            }
        }
        .frame(maxHeight: 240)
        .background(.quaternary.opacity(0.26), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1) }
    }

    private func resultMetric(_ label: String, value: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value.formatted(.number.locale(model.language.locale)))
                .font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                    Text(URL(fileURLWithPath: item.originalPath).lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 6)
                    if ["trashed", "purged"].contains(item.state) { Text(model.bytes(item.allocatedBytesEstimate)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                Text(model.t(state.label)).font(.caption).foregroundStyle(state.color)
                Text(item.originalPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let error=item.error, !error.isEmpty { Text(model.diagnostic(error)).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
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
            switch self { case .moved: .green; case .purged, .failed: .red; case .skipped: .secondary; case .unverified: .orange }
        }
    }
}
