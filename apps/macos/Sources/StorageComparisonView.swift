import ShouCore
import SwiftUI

private struct ComparisonRequest: Hashable {
    let baselineId: String
    let path: String
}

struct StorageComparisonView: View {
    var model: AppModel
    let scanId: String
    let initialPath: String
    @Environment(\.dismiss) private var dismiss
    @State private var history: StorageComparisonHistory?
    @State private var baselineId=""
    @State private var path="."
    @State private var comparison: StorageComparison?
    @State private var loading=true
    @State private var comparing=false
    @State private var issue: String?
    private var request: ComparisonRequest { ComparisonRequest(baselineId: baselineId, path: path) }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeading(title: model.t("Compare Analyses"),
                subtitle: model.t("Explain observed space changes between two analyses of the same folder."), artwork: .space)
            VStack(alignment: .leading, spacing: ShouDesign.sectionSpacing) {
                if let history {
                    Text(history.current.rootPath).font(ShouType.body).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    HStack {
                        Picker(model.t("Earlier Analysis"), selection: $baselineId) {
                            Text(model.t("Choose an earlier analysis")).tag("")
                            ForEach(history.candidates) { candidate in
                                Text(analysisDate(candidate.createdAt)).tag(candidate.id)
                            }
                        }.accessibilityIdentifier("comparison.baseline")
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(model.t("Current Analysis")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                            Text(analysisDate(history.current.createdAt)).font(ShouType.body)
                        }
                    }
                    if history.status == "partial" {
                        Text(model.t("History is limited to readable recent analyses. Some records were skipped."))
                            .font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                    }
                    HStack {
                        Button(model.t("Root Folder")) { path="." }.disabled(path == "." || comparing)
                        if path != "." { Button(model.t("Up One Level")) { path=StorageIndex.parent(path) }.disabled(comparing) }
                        Text(path).font(ShouType.body).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                }
                if loading || comparing {
                    ActivityIndicator(title: model.t(loading ? "Reading analysis history…" : "Comparing analyses…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let issue {
                    VStack(alignment: .leading, spacing: ShouDesign.itemSpacing) {
                        Label(model.t("Comparison unavailable"), systemImage: "info.circle").font(ShouType.body.weight(.semibold))
                        Text(model.t(issue)).font(ShouType.body).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if let comparison {
                    results(comparison)
                } else {
                    Text(model.t("Run two space analyses of the same folder to compare them. Cleared and legacy analyses may be unavailable."))
                        .font(ShouType.body).foregroundStyle(ShouPalette.secondary).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.padding(.horizontal, ShouDesign.workspaceInset)
            Divider()
            HStack {
                Text(model.t("Read-only observations. Historical analyses do not authorize cleanup."))
                    .font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                Spacer()
                Button(model.t("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(ShouDesign.workspaceInset)
        }
        .frame(width: ShouDesign.comparisonSheetWidth, height: ShouDesign.comparisonSheetHeight)
        .background { WorkspaceBackdrop() }
        .task {
            guard let engine=model.engine else { loading=false; return }
            do {
                let result=try await engine.storageComparisonHistory(scanId: scanId)
                guard !Task.isCancelled else { return }
                history=result; path=initialPath; baselineId=result.candidates.first?.id ?? ""; loading=false
            } catch {
                guard !Task.isCancelled else { return }
                issue=error.localizedDescription; loading=false
            }
        }
        .task(id: request) {
            let currentRequest=request
            guard !currentRequest.baselineId.isEmpty, let engine=model.engine else { return }
            comparing=true; issue=nil; comparison=nil
            defer { if !Task.isCancelled && request == currentRequest { comparing=false } }
            do {
                let value=try await engine.compareStorage(baselineId: currentRequest.baselineId, scanId: scanId, path: currentRequest.path)
                guard !Task.isCancelled, request == currentRequest else { return }
                comparison=value
            } catch {
                guard !Task.isCancelled, request == currentRequest else { return }
                issue=error.localizedDescription
            }
        }
    }

    private func results(_ value: StorageComparison) -> some View {
        VStack(alignment: .leading, spacing: ShouDesign.sectionSpacing) {
            HStack(spacing: ShouDesign.workspaceInset) {
                metric("Earlier Size", bytes: value.beforeBytes, incomplete: value.baseline.status == "partial")
                metric("Current Size", bytes: value.afterBytes, incomplete: value.current.status == "partial")
                VStack(alignment: .leading, spacing: ShouDesign.itemSpacing) {
                    Text(model.t("Observed Change")).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                    Text(value.deltaBytes.map(signedSize) ?? model.t("Not comparable"))
                        .font(.system(size: ShouDesign.summaryFigureSize, weight: .medium)).monospacedDigit()
                }
                Spacer()
            }
            if value.status == "partial" {
                Label(model.t("Partial comparison. Ranking covers only examined entries; incomplete coverage has no numeric growth conclusion."), systemImage: "exclamationmark.triangle")
                    .font(ShouType.body).foregroundStyle(ShouPalette.secondary)
            }
            Text(String(format: model.t("%lld examined, %lld changed observations, %lld shown"), value.examinedEntryCount, value.changedEntryCount, value.changes.count))
                .font(ShouType.body).foregroundStyle(ShouPalette.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(value.changes) { change in
                        VStack(alignment: .leading, spacing: ShouDesign.itemSpacing) {
                            HStack(spacing: ShouDesign.sectionSpacing) {
                                Image(systemName: change.kind == "directory" ? "folder" : "doc").accessibilityHidden(true)
                                Text(change.path).font(.system(size: ShouDesign.bodyFontSize, weight: .medium))
                                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                                Spacer()
                                Text(change.deltaBytes.map(signedSize) ?? model.t(stateTitle(change.state))).monospacedDigit().font(ShouType.body)
                                if change.kind == "directory" && change.beforeBytes != nil && change.afterBytes != nil && change.state != "replaced" {
                                    Button { path=change.path } label: { Image(systemName: "chevron.right") }
                                        .buttonStyle(.plain).accessibilityLabel(model.t("Open Directory") + " " + change.path)
                                }
                            }
                            HStack {
                                Text(model.t("Earlier Size") + ": " + observedSize(change.beforeBytes, complete: change.beforeComplete))
                                Text("→").accessibilityHidden(true)
                                Text(model.t("Current Size") + ": " + observedSize(change.afterBytes, complete: change.afterComplete))
                            }.font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                        }.padding(ShouDesign.sectionSpacing)
                        Divider()
                    }
                    if value.changes.isEmpty { Text(model.t("No changed observations in this directory.")).font(ShouType.body).padding() }
                }
            }.modifier(WorkspaceSurface())
            Text(model.t("Allocated sizes are estimates. Hard-link attribution, shared blocks and sparse files can affect changes; these values are not reclaimable space. An item seen in only one analysis is not proof of creation or deletion."))
                .font(ShouType.body).foregroundStyle(ShouPalette.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func metric(_ key: String, bytes: Int64, incomplete: Bool) -> some View {
        VStack(alignment: .leading, spacing: ShouDesign.itemSpacing) {
            Text(model.t(key)).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
            Text((incomplete ? "≥ " : "") + model.bytes(bytes)).font(.system(size: ShouDesign.summaryFigureSize, weight: .medium)).monospacedDigit()
        }
    }
    private func signedSize(_ bytes: Int64) -> String { (bytes > 0 ? "+" : bytes < 0 ? "−" : "") + model.bytes(bytes < 0 ? -bytes : bytes) }
    private func analysisDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second().secondFraction(.fractional(3)).locale(model.language.locale))
    }
    private func observedSize(_ bytes: Int64?, complete: Bool?) -> String {
        bytes.map { (complete == false ? "≥ " : "") + model.bytes($0) } ?? model.t("Not observed")
    }
    private func stateTitle(_ state: String) -> String {
        switch state {
        case "only_current": "Only in current analysis"
        case "only_baseline": "Only in earlier analysis"
        case "replaced": "Object replaced"
        default: "Not comparable"
        }
    }
}
