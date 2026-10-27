import SwiftUI

/// Opening the toolbox does not start a software inventory or service probe.
struct ToolboxView: View {
    @Bindable var model: AppModel

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: ShouDesign.sectionSpacing) {
                    Text(model.t("Toolbox")).font(ShouType.title)
                    HStack(alignment: .top, spacing: ShouDesign.sectionSpacing) {
                        module("AI Workbench", detail: "AI apps, configuration and extensions.", artwork: .rules, section: "ai-tools")
                        module("Developer Tools", detail: "Manage services and development tools.", artwork: .projects, section: "developer-tools")
                    }
                }
                .frame(maxWidth: ShouDesign.homeMaxWidth, alignment: .leading)
                .padding(ShouDesign.workspaceInset)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }.disabled(model.busy).accessibilityIdentifier("tools.welcome")
    }

    private func module(_ title: String, detail: String, artwork: WorkspaceArtworkKind, section: String) -> some View {
        Button { model.section=section } label: {
            VStack(alignment: .leading, spacing: ShouDesign.sectionSpacing) {
                WorkspacePageArtwork(kind: artwork)
                    .frame(maxWidth: .infinity).frame(height: ShouDesign.homeCompactArtworkHeight)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.t(title)).font(ShouType.body.weight(.semibold)).foregroundStyle(ShouPalette.text)
                        Text(model.t(detail)).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").foregroundStyle(ShouPalette.accent)
                }
            }.padding(ShouDesign.workspaceInset).frame(maxWidth: .infinity, alignment: .leading)
                .modifier(WorkspaceSurface())
                .overlay { RoundedRectangle(cornerRadius: ShouDesign.cardRadius).stroke(ShouPalette.border, lineWidth: ShouDesign.hairlineWidth) }
                .contentShape(RoundedRectangle(cornerRadius: ShouDesign.cardRadius))
        }.buttonStyle(.plain).accessibilityIdentifier("tools.open." + section)
    }
}

struct CleanupOptionsMenu: View {
    @Bindable var model: AppModel
    let showLocations: () -> Void
    let showAgentSetup: () -> Void

    var body: some View {
        Menu {
            Button(model.t("Scan Locations…"), action: showLocations)
            Button(model.t("Cleanup Rules")) { model.section="rules" }
            Button(model.t("Project Cleanup")) { model.section="projects" }
            Divider()
            Button(model.t("Investigate with AI…")) { model.ai.requestLaunch(app: model) }
            Button(model.t("External AI Tools…"), action: showAgentSetup)
        } label: {
            Label(model.t("Cleanup Options"), systemImage: "slider.horizontal.3")
        }.disabled(model.busy).accessibilityIdentifier("smart.scan-options")
    }
}
