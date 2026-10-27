import AppKit
import ShouCore
import ShouPlatform
import SwiftUI

struct DiagnosticsView: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var report: DiagnosticReport?
    @State private var issue: String?
    @State private var checking=true
    @State private var revision=UUID()
    @State private var showingReport=false
    @State private var copied=false
    @State private var showingSetup=false

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeading(title: model.t("Diagnostics"), subtitle: model.t("Check disk access, free space, and local records without changing files."))
            if checking {
                ActivityIndicator(title: model.t("Checking system facts…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: ShouDesign.sectionSpacing) {
                        ForEach(report.checks) { check in
                            HStack(alignment: .top, spacing: ShouDesign.sectionSpacing) {
                                Image(systemName: check.state == .normal ? "checkmark.circle" : check.state == .unknown ? "questionmark.circle" : "info.circle")
                                    .font(ShouType.title).foregroundStyle(check.state == .attention ? ShouPalette.warning : ShouPalette.accent)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: ShouDesign.itemSpacing) {
                                    HStack {
                                        Text(model.t(check.title)).font(.system(size: ShouDesign.bodyFontSize, weight: .semibold))
                                        Spacer()
                                        Text(model.t(check.state.title)).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                                    }
                                    Text(model.t(check.explanation)).font(ShouType.body)
                                    if let step=check.nextStep { Text(model.t(step)).font(ShouType.body).foregroundStyle(ShouPalette.secondary) }
                                    if check.id == "disk_access" && check.state != .normal && check.state != .notApplicable {
                                        Button(model.t("Setup Guide…")) { showingSetup=true }
                                    }
                                }
                            }.accessibilityElement(children: .combine)
                            Divider()
                        }
                        DisclosureGroup(model.t("Preview Report"), isExpanded: $showingReport) {
                            Text(report.text(locale: model.language.rawValue)).font(ShouType.body.monospaced())
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(model.t("This report contains bounded system facts, not personal paths or file contents. Nothing is uploaded."))
                            .font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                    }.padding(.horizontal, ShouDesign.workspaceInset)
                }
            } else if let issue {
                ContentUnavailableView(model.t("Diagnostics unavailable"), systemImage: "exclamationmark.triangle", description: Text(model.t(issue)))
            }
            HStack(spacing: ShouDesign.sectionSpacing) {
                Button(model.t("Check Again")) { revision=UUID() }.disabled(checking)
                Button(model.t(copied ? "Copied" : "Copy Report")) {
                    guard let report else { return }
                    let clipboard=NSPasteboard.general
                    clipboard.clearContents()
                    copied=clipboard.setString(report.text(locale: model.language.rawValue), forType: .string)
                }.disabled(checking || report == nil).accessibilityIdentifier("diagnostics.copy")
                Spacer()
                Button(model.t("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(ShouDesign.workspaceInset)
        }
        .frame(width: ShouDesign.diagnosticsSheetWidth, height: ShouDesign.diagnosticsSheetHeight)
        .background { WorkspaceBackdrop() }
        .sheet(isPresented: $showingSetup, onDismiss: { model.scanAccess.dismissed() }) { SetupView(model: model) }
        .task(id: revision) {
            checking=true; issue=nil; copied=false
            defer { checking=false }
            let version=Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
            let work=Task.detached(priority: .utility) { try NativeDiagnostics.collect(applicationVersion: version) }
            do {
                let result=try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled else { return }
                report=result
            } catch {
                guard !Task.isCancelled else { return }
                report=nil; issue="Diagnostics could not finish. Check the local data location and try again."
            }
        }
    }
}
