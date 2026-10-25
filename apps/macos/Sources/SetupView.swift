import AppKit
import Observation
import ShouPlatform
import SwiftUI

@MainActor @Observable final class ScanAccessController {
    var status=DiskAccessStatus.unknown
    var checking=false
    var showingSetup=false
    var cliMessage: String?
    var setupError: String?
    private var pendingScan: (() -> Void)?
    private var refreshTask: Task<Void, Never>?
    private var preparingScan=false
    private let defaults=UserDefaults.standard
    var needsAccess: Bool { status != .available && status != .notRequired }
    var isInstalled: Bool {
        let path=Bundle.main.bundleURL.standardizedFileURL.path
        let userApplications=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApplications + "/")
    }
    var statusTitle: String {
        if checking { return "Checking disk access…" }
        switch status {
        case .available, .notRequired: return "Disk access is ready"
        case .limited: return "Protected locations have limited access"
        case .unknown: return "Disk access needs verification"
        }
    }
    func refresh() async {
        guard !checking else { await refreshTask?.value; return }
        checking=true
        refreshTask=Task {
            status=await Task.detached(priority: .utility) { NativeDiskAccess.check() }.value
            checking=false
        }
        await refreshTask?.value
    }
    func initialize() async {
        await refresh()
        if !defaults.bool(forKey: "ShouSetupCompleted.v1") { showingSetup=true }
    }
    func prepareScan(_ action: @escaping () -> Void) {
        guard pendingScan == nil, !preparingScan else { return }
        preparingScan=true
        Task {
            defer { preparingScan=false }
            await refresh()
            if needsAccess && !defaults.bool(forKey: "ShouLimitedScanAcknowledged.v1") {
                pendingScan=action; showingSetup=true
            } else { action() }
        }
    }
    func finish() {
        defaults.set(true, forKey: "ShouSetupCompleted.v1")
        defaults.set(needsAccess, forKey: "ShouLimitedScanAcknowledged.v1")
        showingSetup=false
        let action=pendingScan; pendingScan=nil
        // Let the setup sheet dismiss before scan/cleanup sheets can appear.
        Task { @MainActor in await Task.yield(); action?() }
    }
    func dismissed() { pendingScan=nil }
    func openSystemSettings() {
        setupError=nil
        if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) {
            setupError="System Settings could not be opened. Open Privacy & Security → Full Disk Access manually."
        }
    }
    func revealApplication() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    func installCLI(model: AppModel) {
        setupError=nil
        do {
            let url=try NativeCLIInstallation.install(app: Bundle.main.bundleURL)
            cliMessage=url.path
        } catch { setupError=error.localizedDescription }
    }
}

struct SetupView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var access: ScanAccessController { model.scanAccess }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: AppIdentity.icon).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.t("A little setup. More room to breathe.")).font(.title2.bold())
                    Text(model.t("Set up Shou once, then get straight to cleaning.")).foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    step(1, title: "Keep Shou in Applications", symbol: access.isInstalled ? "checkmark.circle.fill" : "shippingbox") {
                        Text(model.t(access.isInstalled ? "Shou is installed in Applications. Updates keep the same location." : "Drag Shou.app into Applications, then open that copy before granting disk access."))
                        if !access.isInstalled {
                            Button(model.t("Show Shou in Finder")) { access.revealApplication() }
                        }
                    }
                    Divider()
                    step(2, title: "Enable complete scanning", symbol: access.needsAccess ? "internaldrive" : "checkmark.circle.fill") {
                        Text(model.t("Full Disk Access lets Shou measure protected app data and caches, and avoids repeated macOS app-data prompts. It does not start cleanup."))
                        Label(model.t(access.statusTitle), systemImage: access.needsAccess ? "info.circle" : "checkmark.circle.fill")
                            .foregroundStyle(access.needsAccess ? Color.secondary : Color.green)
                            .accessibilityIdentifier("setup.disk-access-status")
                        if access.needsAccess {
                            Text(model.t("Open Privacy & Security → Full Disk Access. Turn on Shou; if it is missing, click + and select Shou.app in Applications. Reopen Shou if macOS asks."))
                            HStack {
                                Button(model.t("Open System Settings…")) { access.openSystemSettings() }
                                    .disabled(!access.isInstalled).accessibilityIdentifier("setup.open-settings")
                                Button(model.t("Check Again")) { Task { await access.refresh() } }
                                    .disabled(access.checking).accessibilityIdentifier("setup.recheck")
                                Button(model.t("Show Shou in Finder")) { access.revealApplication() }
                            }
                            Text(model.t("You can continue with accessible folders. Protected app containers stay unmeasured until access is enabled; scan again afterward."))
                        }
                    }
                    Divider()
                    step(3, title: "Terminal and AI agents · optional", symbol: "terminal") {
                        Text(model.t("Install the shou command for your terminal, Codex, Claude Code, or WorkBuddy. No model connection is needed."))
                        HStack {
                            Button(model.t("Install CLI Command")) { access.installCLI(model: model) }
                                .disabled(!access.isInstalled).accessibilityIdentifier("setup.install-cli")
                            Text("~/.local/bin/shou").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if let message=access.cliMessage {
                            Text(model.t("CLI installed. If shou is not on PATH, use the full path shown below.")).foregroundStyle(.green)
                            Text(message + " --help").font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }.padding(14)
            }
            DisclosureGroup(model.t("After an update")) {
                Text(model.t("macOS links privacy permissions to the signed app. Development builds with temporary signatures may need access enabled again after an update. If the switch is on but access still fails, remove the old Shou entry with −, add this installed copy with +, and reopen Shou."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            if let error=access.setupError {
                Text(model.diagnostic(error)).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(model.t("You can revisit this guide in Settings.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.t(access.needsAccess ? "Continue with Accessible Folders" : "Start Using Shou")) { access.finish(); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("setup.continue")
            }
        }.padding(28).frame(width: 650)
            .task { await access.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await access.refresh() }
            }
    }
    private func step<Content: View>(_ number: Int, title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(String(number)).font(.callout.bold()).frame(width: 25, height: 25)
                .background(Color.accentColor.opacity(0.1), in: Circle()).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 9) {
                Label(model.t(title), systemImage: symbol).font(.headline)
                content().font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ScanAccessBanner: View {
    var model: AppModel
    var body: some View {
        if model.scanAccess.needsAccess {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive.badge.exclamationmark").foregroundStyle(.orange)
                Text(model.t("Protected app data needs Full Disk Access for complete scanning.")).font(.caption)
                Spacer()
                Button(model.t("Finish Setup…")) { model.scanAccess.showingSetup=true }
                    .controlSize(.small).disabled(model.busy).accessibilityIdentifier("scan.finish-setup")
            }.padding(.horizontal, 20).padding(.vertical, 9).background(.orange.opacity(0.06))
        }
    }
}
