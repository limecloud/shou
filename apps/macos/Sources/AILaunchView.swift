import ShouCore
import SwiftUI

struct AILaunchView: View {
    var model: AppModel
    @Bindable var session: AIWorkspaceSession
    let target: AILaunchTarget
    @Environment(\.dismiss) private var dismiss
    private var conflict: Bool { session.running || session.investigation?.status == .waiting }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(model.t("AI Investigation"), systemImage: "sparkles").font(.title2.weight(.semibold))
            Text(model.t("Investigation Folder")).font(.caption).foregroundStyle(.secondary)
            Text(target.path).font(.callout.monospaced()).textSelection(.enabled).lineLimit(4).truncationMode(.middle)
            if conflict {
                Label(model.t("An investigation is already active. Return to it or stop it before preparing this folder."), systemImage: "questionmark.bubble")
                Text(session.folder).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            } else if !session.enabled {
                Label(model.t("AI is off. Local scanning and cleanup remain available."), systemImage: "pause.circle")
                Toggle(model.t("Enable AI Investigation"), isOn: $session.enabled).toggleStyle(.switch)
                    .accessibilityIdentifier("ai.launch.enable")
            } else if session.connections.isEmpty {
                Label(model.t("Add a connection in Settings before starting AI. You can configure Jev independently of a main model."), systemImage: "network")
                Button(model.t("Open AI Settings")) { dismiss(); model.section="settings" }
            } else {
                Picker(model.t("Connection"), selection: $session.connectionId) {
                    ForEach(session.connections) { Text($0.name).tag($0.id) }
                }
                Label(model.t(session.canReuse(target.path, app: model) ? "Reuse the current space index. AI starts only after you review the scope and choose Start Investigation." : "Measure this folder locally first. AI starts only after you review the results and choose Start Investigation."), systemImage: "internaldrive")
            }
            Text(model.t("Only bounded relative metadata and your answers are sent to the disclosed services. File contents are excluded. No automatic deletion."))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button(model.t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if conflict {
                    Button(model.t("Return to Current Investigation")) { dismiss(); model.section="storage"; session.showingInspector=true }
                    Button(model.t("Stop & Prepare This Folder")) { session.stop(); session.launchTarget(target.path, app: model) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(model.t(session.canReuse(target.path, app: model) ? "Review Investigation Scope" : "Measure Folder")) { session.launchTarget(target.path, app: model) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(!session.enabled || session.connections.isEmpty || model.busy)
                        .accessibilityIdentifier("ai.launch.prepare")
                }
            }
        }.padding(24).frame(width: 560).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("ai.launch.sheet")
    }
}
