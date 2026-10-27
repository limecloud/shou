import SwiftUI
import ShouCore

/// Presentation only: navigation and visual hierarchy do not grant cleanup authority.
struct WorkspaceNavigation: View {
    @Bindable var model: AppModel

    private var compact: Bool {
        switch model.section {
        case "smart", "projects": model.systemResult != nil || model.scanning
        case "applications": model.packageUpdates.source == "applications"
            ? model.applicationsSession.catalog != nil || !model.applicationsSession.items.isEmpty || model.applicationsSession.scanning
            : model.packageUpdates.loading || model.packageUpdates.inventory != nil || !model.packageUpdates.results.isEmpty
        case "startup": model.startupInventory != nil || model.startupLoading
        case "storage": model.space.scan != nil || model.space.scanning
        case "large-files": model.largeFiles.storage.scan != nil || model.largeFiles.storage.scanning
        case "privacy": model.privacySession.scan != nil || model.privacySession.receipt != nil || model.privacySession.working
        default: true
        }
    }

    private var family: String {
        switch model.section {
        case "applications", "projects", "startup": "applications"
        case "developer-tools", "ai-tools": "tools"
        case "storage", "large-files": "storage"
        case "rules": "rules"
        case "privacy", "smart", "overview": "smart"
        default: model.section
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                HStack(spacing: 6) {
                    navigation("smart", "Cleanup", "sparkle.magnifyingglass")
                    navigation("applications", "Apps & Projects", "square.stack.3d.up")
                    navigation("tools", "Tools", "hammer")
                    navigation("storage", "Space Analysis", "square.grid.2x2")
                    navigation("monitor", "Monitor", "waveform.path.ecg")
                    navigation("rules", "Rules", "slider.horizontal.3")
                }
                Spacer(minLength: 8)
                Button { open("history") } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(.plain).help(model.t("History")).accessibilityLabel(model.t("History"))
                    .accessibilityIdentifier("navigation.history")
                Button { open("settings") } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help(model.t("Settings")).accessibilityLabel(model.t("Settings"))
                    .accessibilityIdentifier("navigation.settings")
            }
            .padding(.horizontal, ShouDesign.workspaceInset)
            .frame(height: compact ? ShouDesign.workspaceCompactHeaderHeight : ShouDesign.workspaceHeaderHeight)
            .disabled(model.busy)

            if ["smart", "applications", "storage", "tools"].contains(family) {
                HStack(spacing: 22) {
                    switch family {
                    case "applications":
                        subsection("applications", "Applications")
                        subsection("projects", "Developer Projects")
                        subsection("startup", "Startup Items")
                    case "storage":
                        subsection("storage", "Space Analysis")
                        subsection("large-files", "Large Files")
                    case "tools":
                        subsection("developer-tools", "Developer Tools")
                        subsection("ai-tools", "AI Workbench")
                    default:
                        subsection("smart", "Smart Cleanup")
                        subsection("privacy", "Privacy")
                    }
                    Spacer()
                }
                .padding(.horizontal, ShouDesign.workspaceInset)
                .padding(.bottom, compact ? 6 : 14)
                .disabled(model.busy)
            }
            ShouDivider()
        }
    }

    private func navigation(_ id: String, _ title: String, _ symbol: String) -> some View {
        Button { open(id) } label: {
            Label(model.t(title), systemImage: symbol)
                .font(.system(size: ShouDesign.bodyFontSize, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, compact ? 6 : 10)
                .foregroundStyle(family == id ? ShouPalette.accent : ShouPalette.secondary)
                .background(family == id ? ShouPalette.selection : .clear, in: Capsule())
        }
        .buttonStyle(.plain).accessibilityAddTraits(family == id ? .isSelected : [])
        .accessibilityIdentifier("navigation." + id)
    }

    private func subsection(_ id: String, _ title: String) -> some View {
        Button { open(id) } label: {
            Text(model.t(title)).font(ShouType.body.weight(model.section == id ? .medium : .regular))
                .foregroundStyle(model.section == id ? ShouPalette.text : ShouPalette.secondary)
                .padding(.vertical, 5)
                .overlay(alignment: .bottom) {
                    if model.section == id { Capsule().fill(ShouPalette.accent).frame(height: 2).offset(y: 7) }
                }
        }
        .buttonStyle(.plain).accessibilityAddTraits(model.section == id ? .isSelected : [])
        .accessibilityIdentifier("navigation." + id + ".detail")
    }

    private func open(_ section: String) {
        guard !model.busy else { return }
        model.completion=nil; model.toolCompletion=nil
        model.section=section == "tools" ? "developer-tools" : section
    }
}

struct WorkspaceHeading: View {
    let title: String
    let subtitle: String
    var artwork: WorkspaceArtworkKind? = nil
    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: ShouDesign.summaryFigureSize, weight: .medium))
                if !subtitle.isEmpty { Text(subtitle).font(ShouType.body).foregroundStyle(ShouPalette.secondary) }
            }
            Spacer(minLength: 0)
            if let artwork { WorkspacePageArtwork(kind: artwork).frame(width: 84, height: 56) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ShouDesign.workspaceInset).padding(.vertical, 10)
    }
}

struct WorkspaceSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.background(scheme == .dark ? ShouDesign.surfaceDark : ShouDesign.surfaceLight, in: RoundedRectangle(cornerRadius: ShouDesign.cardRadius))
    }
}
