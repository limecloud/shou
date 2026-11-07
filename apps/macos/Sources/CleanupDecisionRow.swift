import AppKit
import ShouCore
import SwiftUI

struct CleanupDecisionRow: View {
    @Bindable var model: AppModel
    let item: CleanupReviewItem
    @State private var expanded=false
    private var source: CleanupSource { item.source }
    private var kept: Bool { model.commonKept.contains(item.id) }
    private var status: String {
        if kept { return "Kept this time" }
        switch item.disposition { case .recommended: return "Recommended"; case .decision: return "Needs a decision"; case .protected: return "Protected" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Toggle(isOn: Binding(get: { model.commonSelection.contains(item.id) }, set: { model.selectCommon([source], selected: $0) })) { EmptyView() }
                    .toggleStyle(.checkbox).labelsHidden().disabled(model.busy || kept || !source.selectable)
                    .accessibilityLabel(model.t("Select") + " " + source.path)
                    .accessibilityIdentifier("smart.source." + source.path)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.t(item.title)).font(ShouType.body.weight(.medium))
                    Text(source.path).font(ShouType.caption.monospaced()).foregroundStyle(ShouPalette.secondary)
                        .lineLimit(1).truncationMode(.middle).help(source.path).textSelection(.enabled)
                    HStack(spacing: 10) {
                        Text(model.t(status)).foregroundStyle(item.disposition == .decision && !kept ? ShouPalette.warning : ShouPalette.secondary)
                        if let note=source.candidate.rebuildNotes.first { Text(model.t(note)).foregroundStyle(ShouPalette.secondary).lineLimit(2) }
                    }.font(ShouType.caption)
                }
                Spacer(minLength: 8)
                Text(model.bytes(source.candidate.allocatedBytesEstimate)).font(ShouType.body).monospacedDigit()
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                    .buttonStyle(.borderless).accessibilityLabel(model.t("Details") + " " + source.path)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(source.path).font(ShouType.caption.monospaced()).textSelection(.enabled)
                    ForEach(source.candidate.reasons, id: \.self) { Text(model.t($0)).font(ShouType.caption).foregroundStyle(ShouPalette.warning) }
                    ForEach(source.candidate.limitations, id: \.self) { Text(model.t($0)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
                    if source.requiresManualReview && source.selectable {
                        Text(model.t("Select this entire directory for removal. Stop related tasks first. All contents will be checked before deletion.")).font(ShouType.caption).foregroundStyle(ShouPalette.warning)
                    }
                    HStack {
                        Button(model.t(kept ? "Review again" : "Keep this time")) { model.keepCommon(source, keep: !kept) }
                            .accessibilityIdentifier("smart.keep." + source.path)
                        Button(model.t("Investigate This Folder")) { model.ai.requestLaunch(app: model, path: source.path) }
                        if source.candidate.reasons.contains("incomplete_scan") {
                            Button(model.t("Continue Scanning This Directory")) { model.continueCleanupScan(source) }
                        }
                        Spacer()
                        Button(model.t("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)]) }
                    }.buttonStyle(.link).font(ShouType.caption).disabled(model.busy)
                }.padding(.leading, 28)
            }
        }.padding(.vertical, 16).accessibilityElement(children: .contain)
    }
}
