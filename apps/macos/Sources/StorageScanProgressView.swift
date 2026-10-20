import SwiftUI

struct StorageScanProgressView: View {
    var model: AppModel
    var session: StorageSession
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().stroke(Color.accentColor.opacity(0.1), lineWidth: 12).frame(width: 152, height: 152)
                ProgressView().controlSize(.large).scaleEffect(1.6).frame(width: 152, height: 152)
                Image(systemName: "internaldrive.fill").font(.system(size: 48)).foregroundStyle(Color.accentColor).offset(y: -1)
            }.padding(.bottom, 8)
            Text(model.t(session.progressTitle)).font(.system(size: 26, weight: .semibold))
            Text(String(format: model.t("%lld items measured"), locale: model.language.locale, session.progress?.entryCount ?? 0))
                .font(.title3.monospacedDigit()).foregroundStyle(.secondary)
            if session.progress?.limitReached == true {
                Text(model.t("Scan limit reached. Preparing the measured results; coverage is incomplete."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Text(session.progress?.currentPath ?? session.location).font(.caption.monospaced())
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
            TimelineView(.periodic(from: session.startedAt, by: 1)) { timeline in
                Text(Duration.seconds(max(0, timeline.date.timeIntervalSince(session.startedAt))).formatted(.time(pattern: .minuteSecond)))
                    .font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Button(model.t(session.stopRequested ? "Stopping…" : "Stop")) { session.stop() }.controlSize(.large).padding(.top, 8)
                .disabled(session.stopRequested)
                .accessibilityIdentifier("storage.stop")
            Spacer()
        }.padding(30)
    }
}
