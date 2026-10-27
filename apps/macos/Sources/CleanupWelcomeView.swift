import SwiftUI

struct CleanupWelcomeView: View {
    @Bindable var model: AppModel
    let showLocations: () -> Void
    let showAgentSetup: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 1100 || geometry.size.height < ShouDesign.homeCompactHeightBreakpoint
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? ShouDesign.homeCompactSpacing : ShouDesign.sectionSpacing) {
                    hero(compact: compact)
                    HStack(spacing: 16) {
                        destination("Applications", subtitle: "Manage installed apps and updates.", kind: .applications, section: "applications")
                        destination("Space Analysis", subtitle: "Find the files taking up the most room.", kind: .space, section: "storage")
                        destination("Privacy", subtitle: "Review browser history and site data.", kind: .privacy, section: "privacy")
                    }
                }
                .frame(maxWidth: ShouDesign.homeMaxWidth)
                .padding(compact ? ShouDesign.homeCompactInset : ShouDesign.workspaceInset)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
        .disabled(model.busy)
        .accessibilityIdentifier("smart.welcome")
    }

    private func hero(compact: Bool) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: compact ? ShouDesign.homeCompactSpacing : 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.t("Room for"))
                    Text(model.t("what comes next."))
                        .foregroundStyle(LinearGradient(colors: scheme == .dark ? [ShouDesign.accentDark, ShouDesign.artworkBlue] : [ShouDesign.artworkDeep, ShouDesign.actionStart], startPoint: .leading, endPoint: .trailing))
                }
                .font(.system(size: compact ? ShouDesign.heroCompactTitleSize : ShouDesign.heroTitleSize, weight: .semibold))
                .tracking(-0.8).fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                Text(model.t("Find caches and temporary files you can clear."))
                    .font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 430, alignment: .leading)
                HStack(spacing: 12) {
                    Button { model.scanCommonLocations() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkle.magnifyingglass")
                            Text(model.t("Start Scan"))
                            Spacer(minLength: 10)
                            Image(systemName: "arrow.right")
                        }
                    }
                    .buttonStyle(WorkspacePrimaryButtonStyle()).fixedSize().accessibilityIdentifier("smart.start")
                    CleanupOptionsMenu(model: model, showLocations: showLocations, showAgentSetup: showAgentSetup)
                        .fixedSize().menuStyle(.borderlessButton)
                }.padding(.top, 3)
                Label(model.t("Scan first. Review before anything is removed."), systemImage: "checkmark.shield")
                    .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            WorkspaceIllustration()
                .frame(width: compact ? ShouDesign.homeCompactArtworkWidth : ShouDesign.homeArtworkWidth,
                       height: compact ? ShouDesign.homeCompactArtworkHeight : ShouDesign.homeArtworkHeight)
                .accessibilityHidden(true)
        }
        .padding(.leading, compact ? 8 : 42).padding(.trailing, compact ? 0 : 22)
        .padding(.vertical, compact ? 12 : 28)
        .frame(minHeight: compact ? ShouDesign.homeCompactHeroHeight : ShouDesign.heroHeight)
    }

    private func destination(_ title: String, subtitle: String, kind: WorkspaceArtworkKind, section: String) -> some View {
        WorkspaceDestinationCard(title: model.t(title), subtitle: model.t(subtitle), kind: kind) {
            model.section=section
        }.accessibilityIdentifier("smart.destination." + section)
    }
}

private struct WorkspaceDestinationCard: View {
    let title: String
    let subtitle: String
    let kind: WorkspaceArtworkKind
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering=false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: ShouDesign.bodyFontSize, weight: .semibold)).foregroundStyle(ShouPalette.text)
                    Text(subtitle).font(ShouType.caption).foregroundStyle(ShouPalette.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                WorkspacePageArtwork(kind: kind)
                    .frame(width: ShouDesign.homeCardArtworkSize, height: ShouDesign.homeCardArtworkSize)
            }.padding(16).frame(maxWidth: .infinity, minHeight: ShouDesign.homeCardHeight, alignment: .leading)
                .background(scheme == .dark ? ShouDesign.surfaceDark : ShouDesign.surfaceLight, in: RoundedRectangle(cornerRadius: ShouDesign.homeCardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: ShouDesign.homeCardRadius)
                        .stroke(hovering ? ShouPalette.accent.opacity(0.5) : .primary.opacity(contrast == .increased ? 0.35 : 0.07), lineWidth: ShouDesign.hairlineWidth)
                }
        }
        .buttonStyle(.plain).onHover { hovering=$0 }
        .accessibilityElement(children: .combine)
    }
}

struct WorkspacePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: ShouDesign.bodyFontSize, weight: .medium))
            .foregroundStyle(ShouDesign.actionText)
            .padding(.horizontal, 18).frame(minWidth: ShouDesign.primaryActionMinWidth, minHeight: 46)
            .background(LinearGradient(colors: [ShouDesign.actionStart, ShouDesign.actionEnd], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13))
            .shadow(color: ShouDesign.artworkDeep.opacity(configuration.isPressed ? 0.08 : 0.2), radius: configuration.isPressed ? 3 : 10, y: 4)
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}
