import SwiftUI
import Accessibility
import ShouCore

/// All destructive workflows share the same visible operation state.
struct ExecutionProgressView: View {
    var model: AppModel

    var body: some View {
        let update=model.executionProgress
        OperationProgressView(title: model.executionTitle,
            subtitle: model.t("Tidy up. That's it."),
            symbol: update?.stage == "restoring" ? "folder.fill" : update?.stage == "moving" ? "trash.fill" : model.section == "privacy" ? "hand.raised.fill" : "tray.fill",
            currentPath: update?.path ?? "",
            countText: update.map { String(format: model.t(model.section == "privacy" ? "%lld of %lld sources processed" : "%lld of %lld items processed"), locale: model.language.locale, $0.processedCount, $0.itemCount) } ?? model.t("Preparing cleanup…"),
            fraction: update.flatMap { $0.stage == "preflight" || $0.itemCount <= 0 ? nil : Double(min(max(0, $0.processedCount), $0.itemCount)) / Double($0.itemCount) },
            stopRequested: model.stopRequested,
            stopLabel: model.t("Stop"), stoppingLabel: model.t("Stopping at a safe boundary…"), onStop: model.cancel)
    }
}

/// The fraction describes a known set of items, never an estimated duration.
struct OperationProgressView: View {
    let title: String
    var subtitle=""
    var symbol="magnifyingglass"
    var currentPath=""
    var countText=""
    var fraction: Double?
    var stopRequested=false
    let stopLabel: String
    let stoppingLabel: String
    let onStop: () -> Void
    @ReduceMotion private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            OperationActivityArtwork(symbol: symbol, stopped: stopRequested)
                .frame(width: 196, height: 138).padding(.bottom, 20)
            Text(stopRequested ? stoppingLabel : title)
                .font(.system(size: 23, weight: .semibold)).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty {
                Text(subtitle).font(.callout).foregroundStyle(.secondary).padding(.top, 7)
            }
            OperationProgressMeter(fraction: fraction, countText: countText)
                .padding(.top, 24)
            Text(currentPath.isEmpty ? " " : currentPath)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(currentPath)
                .frame(height: 20).padding(.top, 12)
                .accessibilityIdentifier("operation.current-path")
            Button(stopRequested ? stoppingLabel : stopLabel, action: onStop)
                .controlSize(.large).keyboardShortcut(".", modifiers: .command)
                .disabled(stopRequested).padding(.top, 25)
                .accessibilityIdentifier("operation.stop")
            Spacer(minLength: 16)
        }
        .frame(maxWidth: 520).padding(.horizontal, 36).padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { AccessibilityNotification.Announcement(title).post() }
        .onChange(of: stopRequested) { _, stopping in
            if stopping { AccessibilityNotification.Announcement(stoppingLabel).post() }
        }
    }
}

struct OperationProgressMeter: View {
    var fraction: Double?
    let countText: String
    var compact=false
    @ReduceMotion private var reduceMotion
    private var value: Double? { fraction.map { min(1, max(0, $0)) } }

    var body: some View {
        VStack(spacing: compact ? 7 : 12) {
            HStack(alignment: .firstTextBaseline) {
                if let value {
                    Text(value, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: compact ? 17 : 42, weight: .semibold, design: .rounded))
                        .monospacedDigit().contentTransition(.numericText(value: value * 100))
                        .accessibilityIdentifier("operation.percentage")
                }
                if compact { Spacer(minLength: 10) }
                if compact || value == nil {
                    Text(countText).font(compact ? .caption : .title3).monospacedDigit().foregroundStyle(.secondary)
                        .contentTransition(.numericText()).accessibilityIdentifier("operation.count")
                }
            }.frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
            Group {
                if let value { ProgressView(value: value, total: 1) }
                else if reduceMotion { Capsule().fill(.quaternary).frame(height: 6) }
                else { ProgressView().progressViewStyle(.linear) }
            }
            .progressViewStyle(.linear).controlSize(compact ? .regular : .large)
            .accessibilityLabel(countText).accessibilityIdentifier("operation.progress")
            if !compact && value != nil {
                Text(countText).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .contentTransition(.numericText()).accessibilityIdentifier("operation.count")
            }
        }.animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: value)
    }
}

/// Decorative motion stays separate from measured progress and stops immediately
/// for cancellation, background windows, or either Reduce Motion preference.
struct OperationActivityArtwork: View {
    var symbol: String
    var stopped=false
    @ReduceMotion private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: stopped || reduceMotion || activeState == .inactive)) { timeline in
            let phase=stopped || reduceMotion || activeState == .inactive ? 0.5 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.065)).frame(width: 128, height: 128)
                Circle().stroke(Color.accentColor.opacity(0.13), lineWidth: 1).frame(width: 128, height: 128)
                ForEach(0..<3) { index in
                    let position=(phase + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                    Image(systemName: "doc.fill").font(.system(size: 19))
                        .foregroundStyle(Color.accentColor.opacity(0.5))
                        .rotationEffect(.degrees(-16 + position * 28))
                        .offset(x: CGFloat(index - 1) * 35, y: -60 + position * 80)
                        .opacity(reduceMotion || stopped ? 0 : max(0, sin(position * .pi)))
                }
                Image(systemName: symbol).font(.system(size: 50, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .padding(20).background(.background.opacity(0.94), in: Circle())
                    .offset(y: 24)
            }.frame(width: 196, height: 138)
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}
