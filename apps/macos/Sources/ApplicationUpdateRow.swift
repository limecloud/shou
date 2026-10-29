import AppKit
import SwiftUI
import ShouCore
import ShouPlatform

struct ApplicationUpdateRow: View {
    @Bindable var model: AppModel
    let application: ApplicationDefinition
    @State private var request: UUID?
    @State private var loading=false
    @State private var result: ApplicationUpdateObservation?
    @State private var failure: String?
    private var source: ApplicationUpdateSource? { try? ApplicationUpdateChecker.source(for: application) }

    var body: some View {
        if source != nil { content }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(model.t("Application Updates"), systemImage: "arrow.down.app").font(ShouType.body.weight(.medium))
                Spacer()
                if source != nil {
                    if loading {
                        ProgressView().controlSize(.small)
                        Button(model.t("Stop")) { request=nil; loading=false }.accessibilityIdentifier("applications.update.stop")
                    } else {
                        Button(model.t("Check Homebrew Catalog")) { result=nil; failure=nil; request=UUID() }
                            .disabled(model.busy).accessibilityIdentifier("applications.update.check")
                            .help(model.t("Checks formulae.brew.sh for this app only. Nothing is installed and your application list is not uploaded."))
                    }
                }
            }
            if let source {
                if let result {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.t(title(result.state))).font(ShouType.body)
                                .foregroundStyle(result.state == .unknown ? ShouPalette.warning : ShouPalette.text)
                            if let version=result.catalogVersion {
                                Text(model.t("Catalog Version") + ": " + version).font(ShouType.caption).monospacedDigit()
                            }
                            Text(model.date(result.observedAt)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                            if let reason=result.issues.first {
                                Text(model.t(reasonTitle(reason))).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        if result.state != .unknown {
                            Button(model.t("Open Homebrew Page")) {
                                if let url=URL(string: source.officialURL) { NSWorkspace.shared.open(url) }
                            }.disabled(model.busy).accessibilityIdentifier("applications.update.open")
                        }
                    }.accessibilityIdentifier("applications.update.result")
                }
                if let failure { Text(model.t(failure)).font(ShouType.caption).foregroundStyle(ShouPalette.warning).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(.vertical, 8)
        .task(id: request) {
            guard let token=request else { return }
            loading=true
            defer { if request == token { loading=false } }
            do {
                let value=try await ApplicationUpdateChecker.native().check(path: application.path, expectedApplication: application)
                try Task.checkCancellation()
                if request == token { result=value }
            } catch {
                if !Task.isCancelled && request == token {
                    failure=(error as? ShouError)?.code == "application_changed" ? "Application changed. Scan applications again before checking its catalog version." : "The catalog check could not finish. Try again."
                }
            }
        }
        .onChange(of: model.busy) { _, busy in if busy { request=nil; loading=false } }
    }

    private func title(_ state: ApplicationUpdateState) -> String {
        switch state {
        case .newerCatalogVersion: "Newer version in catalog"
        case .sameCatalogVersion: "Matches catalog version"
        case .installedVersionNewer: "Installed version is newer than the catalog"
        case .unknown: "Update status unknown"
        case .unsupported: "No supported update source"
        }
    }
    private func reasonTitle(_ reason: String) -> String {
        switch reason {
        case "update_version_ambiguous": "The versions use different or unsupported formats. Compare them in the app."
        case "update_system_unsupported", "update_platform_unknown": "A matching catalog version could not be verified for this system."
        case "update_source_mismatch", "update_catalog_disabled": "The catalog identity or availability could not be verified."
        default: "The catalog check could not finish. Try again."
        }
    }
}
