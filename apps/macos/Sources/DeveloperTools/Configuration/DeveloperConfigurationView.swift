import SwiftUI
import AppKit
import ShouPlatform

struct DeveloperConfigurationView: View {
    @Bindable var model: AppModel
    @Bindable var tools: DeveloperToolsSession
    @Bindable var session: DeveloperConfigurationSession
    let logs: Bool
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            if logs { logView } else { configurationView }
        }
    }
    private var configurationView: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                if !session.targets.isEmpty {
                    Picker(model.t("Configuration File"),selection:Binding(get:{ session.targetID },set:{ session.select($0) })) {
                        ForEach(session.targets) { Text(model.t($0.source) + " / " + $0.path).tag($0.path) }
                    }.labelsHidden().disabled(model.busy || session.reviewing)
                }
                Spacer(minLength:0)
                Button(model.t("Choose Configuration File")) {
                    let panel=NSOpenPanel(); panel.canChooseDirectories=false; panel.allowsMultipleSelection=false
                    // Caddyfile has no extension. File validation still controls
                    // editability after selection, including unknown file types.
                    if panel.runModal() == .OK, let url=panel.url { session.select(url.path) }
                }.disabled(model.busy || session.reviewing).accessibilityIdentifier("developer.configuration.choose")
                Button(model.t("Reload")) { session.select(session.targetID) }.disabled(model.busy || session.targetID.isEmpty || session.loading || session.reviewing)
            }
            if session.loading || session.discovering { ProgressView().controlSize(.small) }
            if let document=session.document {
                Text(document.path).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
                TextEditor(text:$session.text).font(ShouType.code).scrollContentBackground(.hidden)
                    .padding(8).frame(minHeight:320).background(ShouPalette.inset)
                    .overlay { Rectangle().stroke(ShouPalette.border,lineWidth:ShouDesign.hairlineWidth) }
                    .disabled(model.busy || !document.writable || session.reviewing)
                    .accessibilityIdentifier("developer.configuration.editor")
                if session.hasRunningLocalInstance {
                    Text(model.t("Stop this instance before editing its configuration.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                } else if !document.writable {
                    Text(model.t("This configuration is read-only.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                }
                if session.reviewing {
                    Text(model.t("Save changes to this configuration file?")).font(ShouType.body)
                    HStack {
                        Spacer()
                        Button(model.t("Cancel")) { session.reviewing=false }
                        Button(model.t("Save Configuration")) { session.save(app:model) { tools.refreshServices(app:model) } }
                            .buttonStyle(.borderedProminent).disabled(!session.canSave).accessibilityIdentifier("developer.configuration.save")
                    }
                } else {
                    HStack {
                        Spacer()
                        Button(model.t("Review Changes")) { session.reviewing=true }.buttonStyle(.borderedProminent)
                            .disabled(model.busy || !session.canSave).accessibilityIdentifier("developer.configuration.review")
                    }
                }
            } else if !session.loading && !session.discovering && session.failure == nil {
                Text(model.t("No configuration file was found in the detected sources.")).foregroundStyle(ShouPalette.secondary)
            }
            if let failure=session.failure { Text(model.t(failure)).foregroundStyle(ShouPalette.danger).textSelection(.enabled) }
            if let message=session.message { Text(model.t(message)).foregroundStyle(ShouPalette.secondary) }
        }
    }
    private var logView: some View {
        VStack(alignment:.leading,spacing:14) {
            if session.logTargets.isEmpty { Text(model.t("No log path was found for this instance.")).foregroundStyle(ShouPalette.secondary) }
            else {
                HStack {
                    Picker(model.t("Logs"),selection:$session.logID) {
                        ForEach(session.logTargets) { Text(model.t($0.title) + " / " + $0.path).tag($0.path) }
                    }.labelsHidden().disabled(model.busy || session.logCleanup.plan != nil)
                    Button(model.t("Refresh")) { session.readLog() }.disabled(model.busy || session.logLoading || session.logCleanup.plan != nil)
                }
                if session.logLoading { ProgressView().controlSize(.small) }
                DeveloperLogCleanupControls(model:model,session:session.logCleanup,toolID:session.toolID,path:session.logID,
                    canReview:!session.logLoading && session.logText?.isEmpty == false,completed:{ session.logText="" })
                if let log=session.logText {
                    GeometryReader { geometry in
                        ScrollView([.horizontal,.vertical]) {
                            Text(log.isEmpty ? model.t("No log entries yet.") : log).font(ShouType.code).textSelection(.enabled)
                                .frame(minWidth:max(0,geometry.size.width-24),minHeight:max(0,geometry.size.height-24),alignment:.topLeading).padding(12)
                        }.accessibilityIdentifier("developer.logs.content")
                    }.frame(height:320).background(ShouPalette.inset)
                }
                if let failure=session.logFailure { Text(model.t(failure)).foregroundStyle(ShouPalette.secondary) }
            }
        }.onAppear { session.readLog() }.onChange(of:session.logID) { session.readLog() }
    }
}
