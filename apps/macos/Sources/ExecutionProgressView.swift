import SwiftUI
import Accessibility
import ShouCore

/// All destructive workflows share the same visible operation state.
struct ExecutionProgressView: View {
    var model: AppModel

    var body: some View {
        let update=model.executionProgress
        let checking=update?.stage == "preflight" || (update?.stage == "purging" && update?.currentItemCount == nil && (update?.processedCount ?? 0) < (update?.itemCount ?? 0))
        OperationProgressView(title: checking ? model.t("Checking selected items…") : model.executionTitle,
            subtitle: model.t("Tidy up. That's it."),
            symbol: checking ? "doc.text.magnifyingglass" : update?.stage == "restoring" ? "folder.fill" : ["moving", "purging", "finalizing"].contains(update?.stage ?? "") ? "trash" : model.executionUsesSources ? "hand.raised.fill" : "doc.text.magnifyingglass",
            currentPath: update?.path ?? "",
            countText: update.map { String(format: model.t(model.executionUsesSources ? "%lld of %lld sources processed" : "%lld of %lld items processed"), locale: model.language.locale, $0.currentItemProcessedCount ?? $0.processedCount, $0.currentItemCount ?? $0.itemCount) } ?? model.t("Preparing cleanup…"),
            fraction: checking ? nil : update?.fractionCompleted,
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
        GeometryReader { geometry in
            content(compact: geometry.size.height < 490)
        }
        .onAppear { AccessibilityNotification.Announcement(title).post() }
        .onChange(of: stopRequested) { _, stopping in
            if stopping { AccessibilityNotification.Announcement(stoppingLabel).post() }
        }
    }

    private func content(compact: Bool) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: compact ? 8 : 16)
            OperationActivityArtwork(symbol: symbol, stopped: stopRequested)
                .scaleEffect(compact ? 0.58 : 1)
                .frame(width: 196, height: compact ? 80 : 138).padding(.bottom, compact ? 8 : 20)
            Text(stopRequested ? stoppingLabel : title)
                .font(.system(size: compact ? 20 : 23, weight: .semibold)).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty && !compact {
                Text(subtitle).font(.callout).foregroundStyle(.secondary).padding(.top, 7)
            }
            OperationProgressMeter(fraction: fraction, countText: countText, compact: compact)
                .padding(.top, compact ? 16 : 24)
            Text(currentPath.isEmpty ? " " : ProgressPresentation.singleLinePath(currentPath))
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(currentPath)
                .frame(maxWidth: 360).frame(height: compact ? 18 : 22).padding(.top, compact ? 8 : 12)
                .accessibilityValue(currentPath)
                .accessibilityIdentifier("operation.current-path")
            Button(action: onStop) {
                Text(stopRequested ? stoppingLabel : stopLabel).frame(minWidth: 140)
            }
                .buttonStyle(.bordered).controlSize(.large).keyboardShortcut(".", modifiers: .command)
                .disabled(stopRequested).padding(.top, compact ? 16 : 25)
                .accessibilityIdentifier("operation.stop")
            Spacer(minLength: compact ? 8 : 16)
        }
        .frame(maxWidth: 520).padding(.horizontal, compact ? 24 : 36).padding(.vertical, compact ? 10 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        .monospacedDigit()
                        .accessibilityIdentifier("operation.percentage")
                }
                if compact { Spacer(minLength: 10) }
                if compact || value == nil {
                    Text(countText).font(compact ? .caption : .title3).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityIdentifier("operation.count")
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
                    .accessibilityIdentifier("operation.count")
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
