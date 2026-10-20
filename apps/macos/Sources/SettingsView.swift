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
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var scanLocations=false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(model.t("Settings")).font(.largeTitle.bold())
                group("General") {
                    row("Interface language", "Choose the language used in Shou.", icon: "character.bubble") {
                        LanguagePicker(model: model).labelsHidden().frame(width: 200)
                    }
                    Divider().padding(.leading, 58)
                    row("Appearance", "Use light, dark, or your system appearance.", icon: "circle.lefthalf.filled") {
                        Picker(model.t("Appearance"), selection: $appearance) {
                            Text(model.t("Follow System")).tag("system")
                            Text(model.t("Light")).tag("light")
                            Text(model.t("Dark")).tag("dark")
                        }.labelsHidden().frame(width: 200)
                    }
                    Divider().padding(.leading, 58)
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
                    Divider().padding(.leading, 58)
                    row("Shou " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.0"), "Updates are verified before installation.", icon: "shippingbox") {
                        Button(model.t("Check for Updates…")) { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates || model.busy)
                    }
                }
                group("Scanning and Privacy") {
                    row("Scan Locations", "App caches and developer projects are discovered automatically. Extra folders are remembered.", icon: "folder.badge.magnifyingglass") {
                        Button(model.t("View…")) { scanLocations=true }.disabled(model.busy)
                    }
                    Divider().padding(.leading, 58)
                    row("Exclusions", "Keep chosen files and projects out of cleanup.", icon: "hand.raised") {
                        Button(model.t("Manage…")) { model.showingExclusions=true }.disabled(model.busy)
                    }
                    Divider().padding(.leading, 58)
                    row("Full Disk Access", "Allow access to application caches that macOS protects.", icon: "internaldrive") {
                        Button { openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) } label: {
                            Label(model.t("System Settings…"), systemImage: "arrow.up.right.square")
                        }
                    }
                    Divider().padding(.leading, 58)
                    row("Local data", "Rules and cleanup history stay on this Mac.", icon: "externaldrive") {
                        Button(model.t("Open Folder…")) { NSWorkspace.shared.open(LocalRecordStore.defaultDirectory) }
                            .help(LocalRecordStore.defaultDirectory.path)
                    }
                }
                group("Support") {
                    row("Report an Issue", "Share a problem or suggest an improvement.", icon: "questionmark.circle") {
                        Link(model.t("Send Feedback…"), destination: URL(string: "https://github.com/limecloud/shou/issues")!)
                    }
                    Divider().padding(.leading, 58)
                    row("Open Source", "Shou is available under the Apache License 2.0.", icon: "chevron.left.forwardslash.chevron.right") {
                        Link(model.t("GitHub"), destination: URL(string: "https://github.com/limecloud/shou")!)
                    }
                }
                Text(model.t("Cleanup always requires confirmation. Moving items to Trash does not immediately free disk space."))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 1040, alignment: .leading).frame(maxWidth: .infinity)
        }.background(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(red: 1, green: 0.976, blue: 0.945))
            .sheet(isPresented: $scanLocations) { ScanLocationsView(model: model) }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t(title)).font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0, content: content)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
        }
    }

    private func row<Control: View>(_ title: String, _ subtitle: String, icon: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 19, weight: .regular)).foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.t(title)).font(.system(size: 13, weight: .semibold))
                Text(model.t(subtitle)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
            control().controlSize(.regular)
        }.padding(.horizontal, 18).padding(.vertical, 17)
    }
}
