import AppKit
import Observation
import ShouPlatform
import ShouCore
import SwiftUI

@MainActor @Observable final class ScanAccessController {
    var status=DiskAccessStatus.unknown
    var checking=false
    var showingSetup=false
    var cliMessage: String?
    var setupError: String?
    var administratorState=SystemAuthorizationState.notRequested
    var authorizingAdministrator=false
    var administratorError: String?
    var administratorTitle: String {
        if authorizingAdministrator { return "Waiting for administrator authorization…" }
        if let administratorError { return administratorError }
        return administratorState == .authorized ? "Authorized for this session" : "Administrator authorization required"
    }
    func authorizeAdministrator(then action: (() -> Void)? = nil) {
        guard !authorizingAdministrator else { return }
        authorizingAdministrator=true; setupError=nil; administratorError=nil
        Task {
            defer { authorizingAdministrator=false; administratorState=NativeSystemAuthorization.shared.administratorState }
            do {
                try await Task.detached(priority: .userInitiated) { try NativeSystemAuthorization.shared.authorizeAdministrator() }.value
                action?()
            } catch { administratorError=(error as? ShouError)?.code ?? "authorization_unavailable"; setupError=administratorError }
        }
    }
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
        administratorState=NativeSystemAuthorization.shared.administratorState
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
        VStack(alignment: .leading, spacing: ShouDesign.pageSpacing) {
            HStack(spacing: ShouDesign.sectionSpacing) {
                Image(nsImage: AppIdentity.icon).resizable().frame(width: ShouDesign.catalogIconSize, height: ShouDesign.catalogIconSize).accessibilityHidden(true)
                Text(model.t("Set Up Shou")).font(ShouType.title)
            }
            VStack(spacing: 0) {
                row("Applications", access.isInstalled ? "Installed" : "Move Shou to Applications", icon: "shippingbox") {
                    Button(model.t("Show Shou in Finder")) { access.revealApplication() }
                }
                ShouDivider()
                row("Full Disk Access", access.statusTitle, icon: "internaldrive") {
                    Button(model.t("Open System Settings…")) { access.openSystemSettings() }
                        .accessibilityIdentifier("setup.open-settings")
                    Button(model.t("Check Again")) { Task { await access.refresh() } }
                        .disabled(access.checking).accessibilityIdentifier("setup.recheck")
                }
                ShouDivider()
                row("Administrator Access", access.administratorState == .authorized ? "Authorized for this session" : "Administrator authorization required", icon: "lock.shield") {
                    if access.authorizingAdministrator { ProgressView().controlSize(.small) }
                    Button(model.t("Authorize…")) { access.authorizeAdministrator() }
                        .disabled(access.authorizingAdministrator || access.administratorState == .authorized)
                        .accessibilityIdentifier("setup.authorize-administrator")
                }
            }
            DisclosureGroup(model.t("Terminal Tools")) {
                HStack {
                    Text(access.isInstalled ? "~/.local/bin/shou" : model.t("Install Shou in Applications first."))
                        .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    Spacer()
                    Button(model.t("Install CLI Command")) { access.installCLI(model: model) }
                        .disabled(!access.isInstalled).accessibilityIdentifier("setup.install-cli")
                }.padding(.top, ShouDesign.itemSpacing)
                if let message=access.cliMessage {
                    Text(message + " --help").font(ShouType.code).textSelection(.enabled)
                }
            }
            DisclosureGroup(model.t("After an update")) {
                Text(model.t("If access remains limited, remove the old Shou entry in Full Disk Access, add this copy again, and reopen Shou."))
                    .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, ShouDesign.itemSpacing)
            }
            if let error=access.setupError {
                Text(model.diagnostic(error)).font(ShouType.caption).foregroundStyle(ShouPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(model.t(access.needsAccess ? "Continue with Accessible Folders" : "Start Using Shou")) { access.finish(); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("setup.continue")
            }
        }.padding(28).frame(width: 650)
            .font(ShouType.body).foregroundStyle(ShouPalette.text).tint(ShouPalette.accent)
            .task { await access.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await access.refresh() }
            }
    }
    private func row<Content: View>(_ title: String, _ status: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: ShouDesign.sectionSpacing) {
            Image(systemName: icon).foregroundStyle(ShouPalette.secondary).frame(width: ShouDesign.catalogIconSize)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.t(title)).font(ShouType.body.weight(.semibold))
                Text(model.t(status)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    .accessibilityIdentifier(title == "Full Disk Access" ? "setup.disk-access-status" : "")
            }
            Spacer(minLength: ShouDesign.sectionSpacing)
            content().controlSize(.regular)
        }.padding(.vertical, ShouDesign.itemSpacing)
    }
}

struct ScanAccessBanner: View {
    var model: AppModel
    var body: some View {
        if model.scanAccess.needsAccess {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive.badge.exclamationmark").foregroundStyle(ShouPalette.warning)
                Text(model.t("Protected app data needs Full Disk Access for complete scanning.")).font(ShouType.caption)
                Spacer()
                Button(model.t("Finish Setup…")) { model.scanAccess.showingSetup=true }
                    .controlSize(.small).disabled(model.busy).accessibilityIdentifier("scan.finish-setup")
            }.padding(.horizontal, 20).padding(.vertical, 9).background(ShouPalette.warning.opacity(0.06))
        }
    }
}
