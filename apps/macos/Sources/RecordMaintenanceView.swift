import ShouCore
import SwiftUI

struct RecordMaintenanceButton: View {
    var model: AppModel
    @State private var preview: RecordRetentionPreview?
    @State private var loading=false
    var body: some View {
        Button(model.t("Clean Scan Records…")) {
            guard let engine=model.engine else { return }
            loading=true
            Task {
                defer { loading=false }
                do { preview=try await engine.recordRetentionPreview() }
                catch { model.presentFailure(error) }
            }
        }
        .disabled(model.busy || loading)
        .accessibilityIdentifier("settings.clean-scan-records")
        .alert(model.t("Clean scan records?"), isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview=nil } })) {
            Button(model.t("Cancel"), role: .cancel) { preview=nil }
            Button(model.t("Clean Records")) {
                guard let engine=model.engine else { return }
                preview=nil; loading=true
                Task {
                    defer { loading=false }
                    do { _ = try await engine.collectRecords() }
                    catch { model.presentFailure(error) }
                }
            }.disabled(preview?.records.isEmpty != false)
        } message: {
            if let preview {
                Text(model.bytes(preview.removableBytes) + "\n" + model.t("Expired scan records are removed automatically. Active plans, cleanup history, recovery data and your files are kept.") + (preview.issues.isEmpty ? "" : "\n" + model.t("Some records need verification and were kept.")))
            }
        }
    }
}
