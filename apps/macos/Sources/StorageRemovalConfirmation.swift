import SwiftUI
import ShouCore

struct StorageRemovalButton: View {
    var model: AppModel
    var session: StorageSession
    var disabled=false
    var identifier="storage.delete"

    var body: some View {
        HStack(spacing: ShouDesign.itemSpacing) {
            Button(role: .destructive) { session.removeSelected(app: model, action: "permanent") } label: {
                Label(model.t("Delete Permanently"), systemImage: "trash")
                    .font(.headline).frame(minWidth: ShouDesign.primaryActionMinWidth, minHeight: ShouDesign.primaryActionContentMinHeight)
            }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                .accessibilityIdentifier(identifier)
                .help(model.t("Permanent deletion cannot be undone."))
                .accessibilityHint(model.t("Permanent deletion cannot be undone."))
            Menu {
                Button(model.t("Move to Trash")) { session.removeSelected(app: model, action: "trash") }
            } label: { Image(systemName: "ellipsis").frame(width: ShouDesign.pageSpacing, height: ShouDesign.primaryActionContentMinHeight) }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.large)
                .accessibilityLabel(model.t("Move to Trash"))
        }.disabled(disabled || session.selected.isEmpty || model.busy)
    }
}
