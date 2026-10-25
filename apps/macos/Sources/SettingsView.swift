import AppKit
import ShouPlatform
import SwiftUI

struct CheckForUpdatesButton: View {
    var model: AppModel
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Button(model.t("Check for Updates…")) { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates || model.busy)
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @ObservedObject var updater: AppUpdater
    @AppStorage("ShouAppearance") private var appearance="system"
    @State private var scanLocations=false
    @State private var diagnostics=false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShouDesign.pageSpacing) {
                group("General") {
                    row("Interface language", "Choose the language used in Shou.", icon: "character.bubble") {
                        LanguagePicker(model: model).labelsHidden().frame(width: 200)
                    }
                    Divider().padding(ShouDesign.settingsSeparatorInset)
                    row("Appearance", "Use light, dark, or your system appearance.", icon: "circle.lefthalf.filled") {
                        Picker(model.t("Appearance"), selection: $appearance) {
                            Text(model.t("Follow System")).tag("system")
                            Text(model.t("Light")).tag("light")
                            Text(model.t("Dark")).tag("dark")
                        }.labelsHidden().frame(width: 200)
                    }
                    Divider().padding(ShouDesign.settingsSeparatorInset)
                    row("Reduce Motion", "Use static indicators and immediate transitions. When off, follow macOS Reduce Motion.", icon: "pause.circle") {
                        Toggle(model.t("Reduce Motion"), isOn: $model.reduceMotion)
                            .labelsHidden().toggleStyle(.switch)
                            .help(model.t("Use static indicators and immediate transitions. When off, follow macOS Reduce Motion."))
                            .accessibilityIdentifier("settings.reduceMotion")
                    }
                }
                group("Software Updates") {
                    row("Automatic update checks", "Get notified when a new version is available.", icon: "arrow.triangle.2.circlepath") {
                        Toggle(model.t("Automatic update checks"), isOn: $updater.automaticChecks).labelsHidden().toggleStyle(.switch)
                    }
                    Divider().padding(ShouDesign.settingsSeparatorInset)
                    row("Shou " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.11.0"), "Updates are verified before installation.", icon: "shippingbox") {
                        Button(model.t("Check for Updates…")) { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates || model.busy)
                    }
                }
                AIConnectionsSettings(model: model, session: model.ai)
                group("Scanning and Privacy") {
                    row("Scan Locations", "App caches and developer projects are discovered automatically. Extra folders are remembered.", icon: "folder.badge.magnifyingglass") {
                        Button(model.t("View…")) { scanLocations=true }.disabled(model.busy)
                    }
                    Divider().padding(ShouDesign.settingsSeparatorInset)
                    row("Exclusions", "Keep chosen files and projects out of cleanup.", icon: "hand.raised") {
                        Button(model.t("Manage…")) { model.showingExclusions=true }.disabled(model.busy)
                    }
                    Divider().padding(ShouDesign.settingsSeparatorInset)
                    row("Full Disk Access", model.scanAccess.statusTitle, icon: "internaldrive") {
                        Button { model.scanAccess.showingSetup=true } label: {
                            Label(model.t("Setup Guide…"), systemImage: "list.bullet.rectangle")
                        }.disabled(model.busy)
                    }
                    Divider().padding(ShouDesign.settingsSeparatorInset)
                    row("Installation and CLI", "Review app installation, disk permissions, and the optional terminal command.", icon: "shippingbox") {
                        Button(model.t("Setup Guide…")) { model.scanAccess.showingSetup=true }.disabled(model.busy)
                    }
                    Divider().padding(ShouDesign.settingsSeparatorInset)
                    row("Local data", "Rules and cleanup history stay on this Mac.", icon: "externaldrive") {
                        RecordMaintenanceButton(model: model)
                        Button(model.t("Open Folder…")) { NSWorkspace.shared.open(LocalRecordStore.defaultDirectory) }
                            .help(LocalRecordStore.defaultDirectory.path)
                    }
                }
                group("Support") {
                    row("Diagnostics", "Check disk access, free space, and local records without changing files.", icon: "stethoscope") {
                        Button(model.t("Run Diagnostics…")) { diagnostics=true }
                            .accessibilityIdentifier("settings.diagnostics")
                    }
                    Divider().padding(ShouDesign.settingsSeparatorInset)
                    row("Report an Issue", "Share a problem or suggest an improvement.", icon: "questionmark.circle") {
                        Link(model.t("Send Feedback…"), destination: URL(string: "https://github.com/limecloud/shou/issues")!)
                    }
                    Divider().padding(ShouDesign.settingsSeparatorInset)
                    row("Open Source", "Shou is available under the Apache License 2.0.", icon: "chevron.left.forwardslash.chevron.right") {
                        Link(model.t("GitHub"), destination: URL(string: "https://github.com/limecloud/shou")!)
                    }
                }
                Text(model.t("Cleanup always requires confirmation. Moving items to Trash does not immediately free disk space."))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(ShouDesign.settingsPagePadding).frame(maxWidth: ShouDesign.settingsMaxWidth, alignment: .leading).frame(maxWidth: .infinity)
        }
            .sheet(isPresented: $scanLocations) { ScanLocationsView(model: model) }
            .sheet(isPresented: $diagnostics) { DiagnosticsView(model: model) }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ShouDesign.itemSpacing) {
            Text(model.t(title)).font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0, content: content)
                .modifier(WorkspaceSurface())
                .overlay(RoundedRectangle(cornerRadius: ShouDesign.cardRadius).strokeBorder(.primary.opacity(0.08)))
        }
    }

    private func row<Control: View>(_ title: String, _ subtitle: String, icon: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: ShouDesign.sectionSpacing) {
            Image(systemName: icon).font(.system(size: ShouDesign.settingsIconSize, weight: .regular)).foregroundStyle(.secondary).frame(width: ShouDesign.settingsIconWidth)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.t(title)).font(.system(size: ShouDesign.bodyFontSize, weight: .semibold))
                Text(model.t(subtitle)).font(.system(size: ShouDesign.settingsSubtitleSize)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
            control().controlSize(.regular)
        }.padding(ShouDesign.settingsRowPadding)
    }
}
