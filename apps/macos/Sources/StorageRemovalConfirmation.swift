import SwiftUI
import ShouCore

struct StorageRemovalConfirmation: View {
    var model: AppModel
    var session: StorageSession
    let plan: StorageRemovalPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: plan.action == "permanent" ? "trash.slash.fill" : "trash.fill").font(.system(size: 30)).foregroundStyle(plan.action == "permanent" ? Color.red : Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.t(plan.action == "permanent" ? "Delete these items permanently?" : "Move these items to Trash?")).font(.title2.weight(.semibold))
                    Text(String(format: model.t("%lld items selected"), plan.items.count) + " · " + model.bytes(plan.allocatedBytesEstimate)).foregroundStyle(.secondary)
                }
            }
            Text(model.t(plan.action == "permanent" ? "These files will be permanently removed. This action cannot be undone." : "You can restore these items from History. Moving to Trash does not free disk space."))
                .font(.callout).foregroundStyle(plan.action == "permanent" ? Color.red : Color.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(plan.items) { item in
                        HStack(alignment: .top) {
                            Text(StorageRemovalPolicy.absolute(root: plan.rootPath, relative: item.path)).font(.caption.monospaced()).textSelection(.enabled)
                            Spacer()
                            Text(model.bytes(item.allocatedBytesEstimate)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }.padding(14)
            }.frame(minHeight: 100, maxHeight: 250).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button(model.t("Cancel")) { session.plan=nil }.keyboardShortcut(.cancelAction)
                Button(model.t(plan.action == "permanent" ? "Delete Permanently" : "Move to Trash"), role: .destructive) { session.execute(app: model, plan: plan) }
                    .buttonStyle(.borderedProminent).tint(plan.action == "permanent" ? .red : .accentColor).accessibilityIdentifier("storage.confirm-delete")
            }
        }.padding(28).frame(width: 610)
    }
}
