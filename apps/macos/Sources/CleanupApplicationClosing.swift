import ShouCore
import SwiftUI

struct CleanupApplicationCloseButton: View {
    var model: AppModel
    @State private var plan: ApplicationClosePlan?
    @State private var loading=false
    var body: some View {
        Button(model.t("Quit Apps & Refresh…")) {
            guard let engine=model.engine, let scans=model.systemResult?.snapshots else { return }
            loading=true
            Task {
                defer { loading=false }
                do { plan=try await engine.cleanupApplicationClosePlan(scanIds: scans.map(\.id)) }
                catch { model.presentFailure(error) }
            }
        }.disabled(model.busy || loading)
        .accessibilityIdentifier("cleanup.quit-and-refresh")
        .alert(model.t("Quit apps to clean their caches?"), isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan=nil } })) {
            Button(model.t("Cancel"), role: .cancel) { plan=nil }
            Button(model.t("Quit Apps & Refresh")) { if let plan { model.closeCleanupApplications(plan) }; plan=nil }
                .disabled(plan?.applications.isEmpty != false)
        } message: {
            Text((plan?.applications.map(\.name).joined(separator: ", ") ?? "") + "\n" + model.t("Save your work first. Shou requests a normal quit, verifies closure, and refreshes affected items. Files are not deleted by this action."))
        }
    }
}
