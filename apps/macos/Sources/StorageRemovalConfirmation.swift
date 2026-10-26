import SwiftUI
import ShouCore

struct StorageRemovalButton: View {
    var model: AppModel
    var session: StorageSession
    var disabled=false
    var identifier="storage.delete"

    var body: some View {
        CleanupActionButton(model: model, enabled: !disabled && !session.selected.isEmpty && !model.busy,
            clean: { session.removeSelected(app: model, action: "permanent") },
            trash: { session.removeSelected(app: model, action: "trash") }, identifier: identifier)
    }
}
