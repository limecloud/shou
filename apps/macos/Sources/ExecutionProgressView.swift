import SwiftUI
import Accessibility
import ShouCore

/// Preparation and execution share one stable page with stage-specific feedback.
struct ExecutionProgressView: View {
    var model: AppModel
    private var symbol: String {
        switch model.executionAction {
        case "restore": "folder"
        case "privacy": "hand.raised"
        default: "trash"
        }
    }

    var body: some View {
        OperationProgressView(title: model.executionTitle, symbol: symbol,
            currentPath: model.executionAction == "privacy" ? "" : model.executionProgress?.path ?? "",
            fraction: model.executionProgress?.stage == "preparing" ? nil : model.executionProgress?.fractionCompleted,
            stopRequested: model.stopRequested, stopLabel: model.t("Stop"),
            stoppingLabel: model.t("Stopping at a safe boundary…"), onStop: model.cancel)
    }
}

/// The fraction describes a known set of items, never an estimated duration.
struct OperationProgressView: View {
    let title: String
    var symbol="magnifyingglass"
    var currentPath=""
    var fraction: Double?
    var stopRequested=false
    let stopLabel: String
    let stoppingLabel: String
    let onStop: () -> Void
    var body: some View {
        GeometryReader { geometry in
            content(compact: geometry.size.height < ShouDesign.operationCompactThreshold)
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
                .scaleEffect(compact ? ShouDesign.operationCompactArtworkScale : 1)
                .frame(width: ShouDesign.cleanupArtworkWidth, height: compact ? ShouDesign.operationCompactArtworkHeight : ShouDesign.cleanupArtworkHeight)
                .padding(.bottom, compact ? ShouDesign.operationCompactArtworkBottom : ShouDesign.operationArtworkBottom)
            Text(stopRequested ? stoppingLabel : title)
                .font(.system(size: compact ? ShouDesign.operationCompactTitleSize : ShouDesign.operationTitleSize, weight: .semibold)).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("operation.title")
            OperationProgressMeter(fraction: fraction, label: title, compact: compact)
                .padding(.top, compact ? ShouDesign.operationCompactMeterTop : ShouDesign.operationMeterTop)
            Text(currentPath.isEmpty ? " " : ProgressPresentation.singleLinePath(currentPath))
                .font(ShouType.code).foregroundStyle(ShouPalette.secondary)
                .lineLimit(1).truncationMode(.middle).help(currentPath)
                .frame(maxWidth: ShouDesign.cleanupPathMaxWidth)
                .frame(height: compact ? ShouDesign.operationCompactPathHeight : ShouDesign.operationPathHeight)
                .padding(.top, compact ? ShouDesign.operationCompactPathTop : ShouDesign.operationPathTop)
                .accessibilityValue(currentPath)
                .accessibilityIdentifier("operation.current-path")
                .transaction { $0.animation=nil }
            Button(action: onStop) {
                Text(stopRequested ? stoppingLabel : stopLabel).frame(minWidth: ShouDesign.operationStopTextWidth)
            }
                .buttonStyle(.bordered).controlSize(.large).keyboardShortcut(".", modifiers: .command)
                .disabled(stopRequested).padding(.top, compact ? ShouDesign.operationCompactStopTop : ShouDesign.operationStopTop)
                .accessibilityIdentifier("operation.stop")
            Spacer(minLength: compact ? 8 : 16)
        }
        .frame(maxWidth: ShouDesign.operationContentWidth)
        .padding(.horizontal, compact ? ShouDesign.operationCompactHorizontalPadding : ShouDesign.operationHorizontalPadding)
        .padding(.vertical, compact ? ShouDesign.operationCompactVerticalPadding : ShouDesign.operationVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OperationProgressMeter: View {
    var fraction: Double?
    let label: String
    var compact=false
    @ReduceMotion private var reduceMotion
    private var value: Double? { fraction.map { min(1, max(0, $0)) } }

    var body: some View {
        VStack(spacing: compact ? ShouDesign.operationCompactMeterSpacing : ShouDesign.operationMeterSpacing) {
            if let value {
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: compact ? ShouDesign.operationCompactPercentageSize : ShouDesign.operationPercentageSize, weight: .semibold, design: .rounded))
                    .monospacedDigit().contentTransition(.identity)
                    .transaction { $0.animation=nil }
                    .accessibilityIdentifier("operation.percentage")
            }
            Group {
                if let value { ProgressView(value: value, total: 1) }
                else if reduceMotion { Capsule().fill(.quaternary).frame(height: ShouDesign.operationMeterHeight) }
                else { ProgressView().progressViewStyle(.linear) }
            }
            .progressViewStyle(.linear).controlSize(compact ? .regular : .large)
            .accessibilityLabel(label).accessibilityIdentifier("operation.progress")
        }.animation(reduceMotion ? nil : .easeOut(duration: Double(ShouDesign.transitionDuration)), value: value)
    }
}
