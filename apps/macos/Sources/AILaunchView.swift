import ShouCore
import SwiftUI

struct AILaunchView: View {
    var model: AppModel
    @Bindable var session: AIWorkspaceSession
    let target: AILaunchTarget
    @State private var allScanned=false
    @State private var selectedFolder: String?
    @Environment(\.dismiss) private var dismiss
    private var conflict: Bool { session.running || session.investigation?.status == .waiting }
    private var path: String { allScanned ? model.space.scan?.rootPath ?? target.path : selectedFolder ?? target.path }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(model.t("AI Investigation"), systemImage: "sparkles").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                Picker(model.t("Investigation Scope"), selection: $allScanned) {
                    Text(model.t("One Folder")).tag(false)
                    if model.space.scan != nil { Text(model.t("All Scanned Folders")).tag(true) }
                }.pickerStyle(.segmented).accessibilityIdentifier("ai.launch.scope")
                Label(path, systemImage: allScanned ? "internaldrive" : "folder")
                    .font(.callout.monospaced()).textSelection(.enabled).lineLimit(4).truncationMode(.middle)
                    .accessibilityIdentifier("ai.launch.path")
                if allScanned {
                    Text(model.t("Investigate the entire saved scan, including its child folders. A broad overview may reach the per-investigation limit; you can then investigate individual folders."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button(model.t("Choose Folder…")) { session.chooseLaunchFolder(app: model, initial: path) { selectedFolder=$0 } }
                            .accessibilityIdentifier("ai.launch.choose-folder")
                        if let scan=model.space.scan {
                            Button(model.t("Use Browsed Folder")) { selectedFolder=StorageRemovalPolicy.absolute(root: scan.rootPath, relative: model.space.path) }
                        }
                    }
                    Text(model.t("Only this folder and its children are investigated. This does not select files for cleanup."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(conflict)
            if conflict {
                Label(model.t("An investigation is already active. Return to it or stop it before preparing this folder."), systemImage: "questionmark.bubble")
                Text(session.folder).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            } else if !session.enabled {
                Label(model.t("AI is off. Local scanning and cleanup remain available."), systemImage: "pause.circle")
                Toggle(model.t("Enable AI Investigation"), isOn: $session.enabled).toggleStyle(.switch)
                    .accessibilityIdentifier("ai.launch.enable")
            } else if !session.connections.contains(where: \.usesMainModel) {
                Label(model.t("Add a main model in Settings before starting AI. The optional decision service assists the main model."), systemImage: "network")
                Button(model.t("Open AI Settings")) { dismiss(); model.section="settings" }
            } else {
                Picker(model.t("AI Configuration"), selection: $session.connectionId) {
                    ForEach(session.connections.filter(\.usesMainModel)) { Text($0.name + " · " + $0.serviceSummary).tag($0.id) }
                }
                if let connection=session.connections.first(where: { $0.id == session.connectionId }) {
                    AIConnectionSummary(model: model, connection: connection)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                Label(model.t(session.canReuse(path, app: model) ? "Reuse the current space index. AI starts only after you review the scope and choose Start Investigation." : "Measure this folder locally first. AI starts only after you review the results and choose Start Investigation."), systemImage: "internaldrive")
            }
            Text(model.t("Only bounded relative metadata and your answers are sent to the disclosed services. File contents are excluded. No automatic deletion."))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button(model.t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if conflict {
                    Button(model.t("Return to Current Investigation")) { dismiss(); model.section="storage"; session.showingInspector=true }
                    Button(model.t("Stop & Prepare This Folder")) { session.stop(); session.launchTarget(path, app: model) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(model.t(session.canReuse(path, app: model) ? "Review Investigation Scope" : "Measure Folder")) { session.launchTarget(path, app: model) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(!session.enabled || !session.connections.contains(where: \.usesMainModel) || model.busy)
                        .accessibilityIdentifier("ai.launch.prepare")
                }
            }
        }.padding(24).frame(width: 560).fixedSize(horizontal: false, vertical: true)
            .onAppear { allScanned=target.path == model.space.scan?.rootPath }
            .accessibilityIdentifier("ai.launch.sheet")
    }
}
