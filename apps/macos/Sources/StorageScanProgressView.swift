import SwiftUI

struct StorageScanProgressView: View {
    var model: AppModel
    var session: StorageSession
    var body: some View {
        VStack(spacing: 8) {
            OperationProgressView(title: model.t(session.progressTitle), symbol: "internaldrive.fill",
                currentPath: session.progress?.currentPath ?? session.location,
                fraction: session.progress?.fractionCompleted,
                stopRequested: session.stopRequested, stopLabel: model.t("Stop"), stoppingLabel: model.t("Stopping…"), onStop: session.stop)
            if session.progress?.limitReached == true {
                Text(model.t("Scan limit reached. Preparing the measured results; coverage is incomplete."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.padding(.bottom, 24)
    }
}
