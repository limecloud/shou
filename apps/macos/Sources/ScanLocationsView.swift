import SwiftUI
import ShouCore

/// Optional scope inspection; never a prerequisite for the main cleanup action.
struct ScanLocationsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var removing: Workspace?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t("Scan Locations")).font(ShouType.title.weight(.semibold))
            Text(model.t("Common locations are found automatically. Extra folders only need to be included once."))
                .font(ShouType.body).foregroundStyle(ShouPalette.secondary)
            List {
                Section(model.t("Developer Projects")) {
                    if model.projectLocations.isEmpty {
                        Text(model.t("No conventional project folders found. Include another folder or ask your AI agent."))
                            .foregroundStyle(ShouPalette.secondary)
                    }
                    ForEach(model.projectLocations) { location in
                        HStack(spacing: 12) {
                            locationLabel(location, symbol: "hammer")
                            if let root=model.projectWorkspaces.first(where: { $0.path == location.path }), canStopIncluding(root.path) {
                                Button { removing=root } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help(model.t("Stop Including Folder"))
                                    .accessibilityLabel(model.t("Stop Including Folder") + " " + root.path)
                                    .disabled(model.busy)
                            }
                        }
                    }
                }
                Section(model.t("Application Caches")) {
                    ForEach(model.knownLocations.filter { $0.exists || $0.availabilityIssue != nil }) { location in
                        locationLabel(location, symbol: "app.badge")
                    }
                }
            }.listStyle(.inset).frame(minHeight: 300)
            HStack {
                Button(model.t("Include Folder…")) { model.addWorkspace(startScan: false) }.disabled(model.busy)
                    .accessibilityIdentifier("scan-locations.include")
                Spacer()
                Button(model.t("Done")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
            }
        }.padding(ShouDesign.pagePadding).frame(width: 680, height: 600)
            .task { await model.refresh() }
            .interactiveDismissDisabled(model.busy)
            .alert(model.t("Stop including this folder?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing=nil } })) {
                Button(model.t("Cancel"), role: .cancel) { removing=nil }
                Button(model.t("Stop Including Folder")) { if let root=removing { model.removeWorkspace(root) }; removing=nil }
            } message: {
                Text(model.t("Its saved rules and exclusions will be detached. Files in the folder stay untouched.") + "\n" + (removing?.path ?? ""))
            }
    }

    private func locationLabel(_ location: KnownLocation, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(ShouPalette.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(location.category == "build" ? URL(fileURLWithPath: location.path).lastPathComponent : model.t(location.title))
                    .font(ShouType.body.weight(.medium))
                Text(location.path).font(ShouType.caption.monospaced()).foregroundStyle(ShouPalette.secondary).lineLimit(1).truncationMode(.middle).help(location.path)
            }
            Spacer()
            if location.availabilityIssue != nil {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(ShouPalette.warning).help(model.t("Unable to scan this location"))
            }
        }.padding(.vertical, 6)
    }

    private func canStopIncluding(_ path: String) -> Bool {
        // Unavailable hints cannot establish that a saved folder is removable.
        (try? ProjectLocations.isConventional(path, homeDirectory: FileManager.default.homeDirectoryForCurrentUser, platform: "macos")) == false
    }
}
