import SwiftUI
import ShouCore

struct CleanupApplicationClosePanel: View {
    @Bindable var model: AppModel
    @State private var applications=[ApplicationDefinition]()
    @State private var selected=Set<String>()
    @State private var loading=true
    @State private var issue: String?
    private var scanKey: String { model.systemResult?.snapshots.map(\.id).joined(separator: ":") ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.t("Apps using cleanup files"), systemImage: "app.badge").font(ShouType.body.weight(.medium))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button {
                    model.closeSelectedCleanupApplications(applications.filter { selected.contains($0.id) })
                } label: {
                    HStack(spacing: 8) {
                        if model.busy && !model.scanning { ProgressView().controlSize(.small) }
                        Text(model.t("Quit Selected Apps & Refresh"))
                    }
                }.disabled(model.busy || selected.isEmpty || loading)
                    .accessibilityIdentifier("cleanup.quit-selected")
            }
            if !applications.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(applications) { app in
                            Toggle(app.name, isOn: Binding(get: { selected.contains(app.id) }, set: { if $0 { selected.insert(app.id) } else { selected.remove(app.id) } }))
                                .toggleStyle(.checkbox).font(ShouType.body).disabled(model.busy)
                                .accessibilityIdentifier("cleanup.quit-app." + app.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: min(112, CGFloat(applications.count) * 30))
                Text(model.t("Save your work first. Apps that stay open will remain blocked."))
                    .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            }
            if let issue { Text(issue).font(ShouType.caption).foregroundStyle(ShouPalette.warning) }
        }.padding(16)
        .background(ShouPalette.surface, in: RoundedRectangle(cornerRadius: ShouDesign.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: ShouDesign.cardRadius).stroke(ShouPalette.border, lineWidth: ShouDesign.hairlineWidth) }
        .padding(.horizontal, ShouDesign.workspaceInset).padding(.bottom, 18)
        .task(id: scanKey) {
            applications=[]; selected=[]; issue=nil; loading=true
            guard let engine=model.engine, let scans=model.systemResult?.snapshots else { loading=false; return }
            do {
                let plan=try await engine.cleanupApplicationClosePlan(scanIds: scans.map(\.id))
                guard !Task.isCancelled else { return }
                applications=plan.applications
                if applications.isEmpty { issue=model.t("Quit affected apps, then scan again.") }
            } catch { if !Task.isCancelled { issue=error.localizedDescription } }
            guard !Task.isCancelled else { return }
            loading=false
        }
    }
}
