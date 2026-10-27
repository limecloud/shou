import ShouCore
import ShouPlatform
import SwiftUI

struct ToolCleanupPanel: View {
    var model: AppModel
    @State private var service: ToolCleanupService?
    @State private var scan: ToolCleanupScan?
    @State private var plan: ToolCleanupPlan?
    @State private var loading=false
    @State private var history: [ToolCleanupReceipt]=[]
    @State private var operation: Task<Void,Never>?
    var body: some View {
        DisclosureGroup {
            if loading { ProgressView(model.t("Checking tool-managed storage…")).controlSize(.small) }
            if let scan {
                ForEach(scan.targets) { target in
                    HStack {
                        Image(systemName: "shippingbox").foregroundStyle(ShouPalette.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.t(target.title)).font(ShouType.body)
                            Text(target.estimatedBytes.map(model.bytes) ?? model.t("Review tool preview")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                        }
                        Spacer()
                        Button(model.t("Clean…")) { prepare(target, scan: scan) }.disabled(model.busy || loading)
                    }.padding(.vertical, 4)
                }
                if scan.targets.isEmpty && !loading { Text(model.t(scan.issues.contains { $0.code != "tool_not_installed" } ? "Some tools could not be checked. Open the owning tool, then check again." : "No reclaimable tool-managed storage found.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
                ForEach(Array(scan.issues.filter { $0.code != "tool_not_installed" }.enumerated()), id: \.offset) { _, issue in
                    Text(issue.tool + ", " + model.t(issue.code)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                }
            }
            HStack {
                Button(model.t("Check Again")) { load() }.disabled(model.busy || loading)
                Spacer()
                if !history.isEmpty {
                    Menu(model.t("Recent Tool Cleanups")) {
                        ForEach(history.prefix(10)) { receipt in
                            Button(model.t(receipt.target.title) + ", " + model.t(receipt.state)) { model.toolCompletion=receipt }
                        }
                    }
                }
            }
        } label: { Label(model.t("Tool-managed Storage"), systemImage: "wrench.and.screwdriver") }
        .task(id: model.systemResult?.snapshots.first?.id) { load() }
        .onDisappear { operation?.cancel() }
        .alert(model.t("Permanently clean this tool's storage?"), isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan=nil } })) {
            Button(model.t("Cancel"), role: .cancel) { plan=nil }
            Button(model.t("Clean Permanently"), role: .destructive) {
                if let plan, let service { model.executeToolCleanup(plan, service: service) }; plan=nil
            }
        } message: {
            if let plan { Text(model.t(plan.target.title) + "\n\n" + model.t(plan.target.impact)) }
        }
    }
    private func load() {
        guard !loading else { return }
        loading=true
        operation=Task {
            defer { loading=false }
            do {
                let current: ToolCleanupService
                if let service { current=service }
                else { current=ToolCleanupService(runner: NativeCleanupTools(), store: try LocalRecordStore()); service=current }
                let result=try await current.scan(), receipts=try await current.history()
                guard !Task.isCancelled else { return }
                scan=result; history=receipts
            } catch { if !Task.isCancelled { model.error=error.localizedDescription } }
        }
    }
    private func prepare(_ target: ToolCleanupTarget, scan: ToolCleanupScan) {
        guard let service else { return }
        loading=true
        operation=Task {
            defer { loading=false }
            do { plan=try await service.createPlan(scanId: scan.id, targetId: target.id) }
            catch { model.error=error.localizedDescription }
        }
    }
}

struct ToolCleanupResultView: View {
    var model: AppModel
    let result: ToolCleanupReceipt
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: result.state == "completed" ? "checkmark.circle" : "exclamationmark.triangle").font(.system(size: 72, weight: .light)).foregroundStyle(result.state == "completed" ? ShouPalette.success : ShouPalette.warning)
            Text(model.t(result.state == "completed" ? "Cleanup complete" : "Some items need attention")).font(ShouType.title.bold())
            Text(model.t(result.target.title)).font(ShouType.body.weight(.semibold))
            Text(model.t("The tool completed its operation and its storage was checked again. Space estimates are separate from available disk space.")).foregroundStyle(ShouPalette.secondary).multilineTextAlignment(.center)
                .opacity(result.state == "completed" ? 1 : 0)
            if let error=result.error { Text(model.diagnostic(error)).font(ShouType.body).textSelection(.enabled) }
            if result.state != "completed" { Text(model.t("Review the tool's current state before trying again. The previous operation may have changed data.")).font(ShouType.body).foregroundStyle(ShouPalette.secondary) }
            Spacer()
            Button(model.t("Back")) { model.toolCompletion=nil; model.section="smart" }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }.padding(30).frame(maxWidth: 600).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
