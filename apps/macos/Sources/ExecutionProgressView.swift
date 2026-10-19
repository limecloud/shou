import SwiftUI

struct ExecutionProgressView: View {
    let title: String
    let currentPath: String?
    let processedCount: Int
    let totalCount: Int
    let countText: String
    let stopRequested: Bool
    let stopLabel: String
    let stoppingLabel: String
    let onStop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var completed: Int { min(max(0, processedCount), max(0, totalCount)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(stopRequested ? stoppingLabel : title)
                        .font(.callout.weight(.medium))
                        .accessibilityAddTraits(.isHeader)
                    if !countText.isEmpty {
                        Text(countText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button(stopRequested ? stoppingLabel : stopLabel, action: onStop)
                    .controlSize(.small)
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(stopRequested)
            }

            Group {
                if totalCount > 0 {
                    ProgressView(value: Double(completed), total: Double(totalCount))
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .accessibilityLabel(title)
            .accessibilityValue(countText)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: completed)

            Text(currentPath ?? "")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(height: 16, alignment: .leading)
                .help(currentPath ?? "")
                .textSelection(.enabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
