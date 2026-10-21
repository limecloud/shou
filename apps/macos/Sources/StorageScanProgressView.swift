import SwiftUI

struct StorageReviewProgressView: View {
    var model: AppModel
    var session: StorageSession
    var body: some View {
        OperationProgressView(title: model.t("Checking selected items…"), symbol: "doc.text.magnifyingglass",
            currentPath: session.reviewProgress?.path ?? "",
            countText: session.reviewProgress.map { String(format: model.t("%lld of %lld items processed"), locale: model.language.locale, $0.processedCount, $0.itemCount) } ?? model.t("Preparing cleanup…"),
            fraction: session.reviewProgress?.fractionCompleted,
            stopRequested: session.stopRequested, stopLabel: model.t("Stop"), stoppingLabel: model.t("Stopping…"), onStop: session.stop)
    }
}

struct StorageScanProgressView: View {
    var model: AppModel
    var session: StorageSession
    var body: some View {
        VStack(spacing: 8) {
            OperationProgressView(title: model.t(session.progressTitle), symbol: "internaldrive.fill",
                currentPath: session.progress?.currentPath ?? session.location,
                countText: String(format: model.t("%lld items measured"), locale: model.language.locale, session.progress?.entryCount ?? 0),
                fraction: session.progress?.fractionCompleted,
                stopRequested: session.stopRequested, stopLabel: model.t("Stop"), stoppingLabel: model.t("Stopping…"), onStop: session.stop)
            if session.progress?.limitReached == true {
                Text(model.t("Scan limit reached. Preparing the measured results; coverage is incomplete."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            TimelineView(.periodic(from: session.startedAt, by: 1)) { timeline in
                Text(Duration.seconds(max(0, timeline.date.timeIntervalSince(session.startedAt))).formatted(.time(pattern: .minuteSecond)))
                    .font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }.padding(.bottom, 24)
    }
}
