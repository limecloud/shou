import SwiftUI
import AppKit
import ShouCore

struct CleanupSourceRow: View {
    @Bindable var model: AppModel
    let source: CleanupSource
    var body: some View {
                    HStack(alignment: .top, spacing: 10) {
                        Toggle(isOn: Binding(get: { model.commonSelection.contains(source.id) }, set: { model.selectCommon([source], selected: $0) })) { EmptyView() }
                            .toggleStyle(.checkbox).labelsHidden().disabled(!source.selectable || model.busy).padding(.top, 2)
                            .accessibilityLabel(model.t("Select") + " " + source.path)
                            .accessibilityIdentifier("smart.source." + source.path)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.path).font(ShouType.body.monospaced()).lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(source.path)
                            Text(String(format: model.t("%lld files"), locale: model.language.locale, source.fileCount) + ", " + model.date(source.candidate.newestModifiedAt))
                                .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                            ForEach(source.candidate.reasons, id: \.self) { Text(model.t($0)).font(ShouType.caption).foregroundStyle(ShouPalette.warning) }
                            if source.requiresManualReview && source.selectable {
                                Text(model.t("Select this entire directory for removal. Stop related tasks first. All contents will be checked before deletion."))
                                    .font(ShouType.caption).foregroundStyle(ShouPalette.warning)
                            }
                            if source.candidate.reasons.contains("incomplete_scan") {
                                Button(model.t("Continue Scanning This Directory")) { model.continueCleanupScan(source) }
                                    .buttonStyle(.link).font(ShouType.caption).disabled(model.busy)
                                    .accessibilityIdentifier("smart.continue." + source.path)
                            }
                        }
                        Spacer(minLength: 6)
                        Text(model.bytes(source.candidate.allocatedBytesEstimate)).font(ShouType.body).monospacedDigit()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)]) } label: {
                            Image(systemName: "folder")
                        }.buttonStyle(.borderless).help(model.t("Reveal in Finder"))
                            .accessibilityLabel(model.t("Reveal in Finder") + " " + source.path)
                    }.padding(.vertical, 5).accessibilityElement(children: .contain).contextMenu {
                        if source.candidate.reasons.contains("incomplete_scan") {
                            Button(model.t("Continue Scanning This Directory")) { model.continueCleanupScan(source) }.disabled(model.busy)
                        }
                        Button(model.t("Investigate This Folder")) { model.ai.requestLaunch(app: model, path: source.path) }.disabled(model.busy)
                        Button(model.t("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)]) }
                        Button(model.t("Copy Path")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source.path, forType: .string) }
                    }
    }
}
