import AppKit
import SwiftUI
import ShouCore

struct DeveloperInstallationsView: View {
    var model: AppModel
    @Bindable var session: DeveloperToolsSession
    let tool: DeveloperToolDefinition

    private var installations: [DeveloperToolInstallation] {
        session.installations(tool.id).filter { session.sourceFilter == "all" || $0.source == session.sourceFilter }
    }
    private var available: [DeveloperToolInspection] {
        session.versionInspections.filter { !$0.installed && ["all", "Homebrew"].contains(session.sourceFilter) }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text(model.t("Installation & Versions")).font(ShouType.body.weight(.semibold))
                Spacer()
                if !session.packages.isEmpty {
                    Button(model.t("Refresh Versions")) { session.loadVersions() }.disabled(model.busy || session.versionsLoading)
                }
            }
            ForEach(installations) { row in
                ShouDivider()
                installation(row)
            }
            ForEach(available,id:\.package.id) { value in
                ShouDivider()
                HStack(spacing:16) {
                    VStack(alignment:.leading,spacing:5) {
                        Text(value.package.token).font(ShouType.body.weight(.medium))
                        Text("Homebrew").font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    }
                    Spacer()
                    Text(value.availableVersion ?? model.t("Unavailable")).font(ShouType.body).monospacedDigit()
                    Button(model.t("Install")) {
                        session.package=value.package; session.inspection=value
                        session.prepare(.install,app:model)
                    }.disabled(model.busy || !value.allows(.install)).tint(ShouPalette.accent)
                }
            }
        }.padding(18).frame(maxWidth:.infinity,alignment:.leading).modifier(WorkspaceSurface())
            .onAppear { if session.versionInspections.isEmpty && !session.packages.isEmpty { session.loadVersions() } }
    }
    private func installation(_ row: DeveloperToolInstallation) -> some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(alignment:.top,spacing:20) {
                version("Installed Version",row.version ?? model.t("Version not verified"))
                if let package=session.managedPackage(row), let value=session.versionInspections.first(where:{ $0.package == package }) {
                    version("Available Version",value.availableVersion ?? model.t("Unavailable"))
                }
                VStack(alignment:.leading,spacing:5) {
                    Text(model.t("Installation Source")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    Text(model.t(row.source)).font(ShouType.body)
                }
                Spacer(minLength:8)
                if session.managedPackage(row) != nil {
                    Button(model.t("Uninstall")) { session.reviewUninstall(row,app:model) }
                        .tint(ShouPalette.danger).disabled(model.busy || session.inventoryLoading || session.servicesLoading)
                        .accessibilityIdentifier("developer.installation.uninstall." + row.id)
                }
            }
            Text(row.path).font(ShouType.body).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            if !row.launchPaths.isEmpty {
                Text(model.t("Launch Paths") + ": " + row.launchPaths.joined(separator:", "))
                    .font(ShouType.caption).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
            }
            let services=session.servicesForInstallation(row)
            if !services.isEmpty {
                Button {
                    session.detailTab=tool.id == "mysql" ? "mysql.service" : "overview"
                } label: {
                    Text(String(format:model.t("%lld services use this installation"),services.count))
                }.buttonStyle(.link).font(ShouType.caption)
            }
        }.padding(.vertical,4)
    }
    private func version(_ title: String, _ value: String) -> some View {
        VStack(alignment:.leading,spacing:5) {
            Text(model.t(title)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            Text(value).font(ShouType.body.weight(.medium)).monospacedDigit()
        }
    }
}
