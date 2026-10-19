import SwiftUI
import ShouCore

struct CleanupResultView: View {
    @Bindable var model: AppModel
    let result: CleanupCompletion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared=false

    private var items: [ItemReceipt] { result.receipts.flatMap(\.items) }
    private var moved: Int { items.filter { $0.state == "trashed" }.count }
    private var skipped: Int { items.filter { $0.state == "pending" || $0.state == "skipped" }.count }
    private var failed: Int { items.filter { $0.state == "failed" }.count }
    private var unverified: Int { items.count - moved - skipped - failed }
    private var complete: Bool { result.failures.isEmpty && !items.isEmpty && result.receipts.allSatisfy { $0.state == "completed" } && moved == items.count }
    private var title: String {
        model.t(complete ? "Cleanup complete" : result.receipts.contains { $0.state == "cancelled" } ? "Cleanup stopped" : "Cleanup finished with issues")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: complete ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(complete ? Color.green : Color.orange)
                    .scaleEffect(reduceMotion || appeared ? 1 : 0.85)
                    .opacity(reduceMotion || appeared ? 1 : 0)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    if let date=result.receipts.first?.createdAt { Text(model.date(date)).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                metric(model.t("Moved to Trash (estimate)"), value: model.bytes(result.receipts.reduce(0) { $0 + $1.trashedBytesEstimate }))
                    .frame(maxWidth: .infinity, alignment: .leading)
                metric(model.t("Moved"), value: moved.formatted(.number.locale(model.language.locale)))
                metric(model.t("Skipped"), value: skipped.formatted(.number.locale(model.language.locale)))
                metric(model.t("Failed items"), value: failed.formatted(.number.locale(model.language.locale)))
            }

            Text(model.t("Moved to Trash; this is not freed space."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if unverified > 0 {
                Label(String(format: model.t("%lld items need verification."), locale: model.language.locale, unverified), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            if !result.failures.isEmpty {
                HStack(spacing: 7) {
                    Label(model.t("Locations with issues"), systemImage: "exclamationmark.triangle")
                    Text(result.failures.count.formatted(.number.locale(model.language.locale))).monospacedDigit()
                }
                .font(.callout).foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                        Label(model.diagnostic(failure), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    if !result.failures.isEmpty && !items.isEmpty { Divider() }
                    ForEach(items) { item in
                        resultRow(item)
                        if item.id != items.last?.id { Divider().padding(.leading, 44) }
                    }
                }
            }
            .frame(minHeight: 180, idealHeight: 300, maxHeight: 390)
            .background(.background, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary, lineWidth: 1) }
            .overlay {
                if items.isEmpty && result.failures.isEmpty {
                    ContentUnavailableView(model.t("No items were processed"), systemImage: "tray")
                }
            }

            HStack {
                Button(model.t("View History")) { model.section="history"; dismiss() }
                Spacer()
                Button(model.t("Close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 680)
        .onExitCommand { dismiss() }
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { appeared=true } }
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(value).font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(minWidth: 88, maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private func resultRow(_ item: ItemReceipt) -> some View {
        let state=ResultState(item.state)
        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: state.symbol).font(.system(size: 16))
                .foregroundStyle(state.color).frame(width: 20).padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(URL(fileURLWithPath: item.originalPath).lastPathComponent)
                        .font(.callout.weight(.medium)).lineLimit(2)
                    Spacer(minLength: 0)
                    Text(item.state == "trashed" ? model.bytes(item.allocatedBytesEstimate) : "—")
                        .font(.callout.weight(.medium)).monospacedDigit().fixedSize()
                }
                Text(model.t(state.label)).font(.caption).foregroundStyle(state.color)
                Text(item.originalPath).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let error=item.error, !error.isEmpty {
                    Text(model.t(error)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } else if state == .skipped {
                    Text(model.t("Not processed after cleanup stopped."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if state == .unverified {
                    Text(model.t("Check History before taking another action."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.padding(12)
    }

    private enum ResultState: Equatable {
        case moved, skipped, failed, unverified

        init(_ state: String) {
            switch state {
            case "trashed": self = .moved
            case "pending", "skipped": self = .skipped
            case "failed": self = .failed
            default: self = .unverified
            }
        }
        var label: String {
            switch self {
            case .moved: "Moved to Trash"
            case .skipped: "Skipped"
            case .failed: "Failed"
            case .unverified: "Needs verification"
            }
        }
        var symbol: String {
            switch self {
            case .moved: "checkmark.circle.fill"
            case .skipped: "minus.circle"
            case .failed: "xmark.circle.fill"
            case .unverified: "questionmark.circle.fill"
            }
        }
        var color: Color {
            switch self {
            case .moved: .green
            case .skipped: .secondary
            case .failed: .red
            case .unverified: .orange
            }
        }
    }
}
