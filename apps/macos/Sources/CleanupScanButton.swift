import SwiftUI
import ShouCore
import ShouPlatform

struct CleanupScanButton: View {
    @Bindable var model: AppModel
    var rescan=false
    var body: some View {
        HStack(spacing: 0) {
            Button { model.scanCommonLocations(scope: rescan ? nil : .standard) } label: {
                Label(model.t(rescan ? "Scan Again" : "Start Scan"), systemImage: rescan ? "arrow.clockwise" : "sparkle.magnifyingglass")
                    .padding(.horizontal, 18).frame(height: ShouDesign.cleanupScanButtonHeight)
            }.buttonStyle(.plain).accessibilityIdentifier(rescan ? "smart.rescan" : "smart.start")
            Rectangle().fill(ShouPalette.border).frame(width: ShouDesign.hairlineWidth, height: 22)
            Menu {
                Button(model.t("Standard Scan")) { model.scanCommonLocations(scope: .standard) }
                Button(model.t("Select Disks…")) { model.showingCleanupVolumes=true }
                Button(model.t("Select Folders…")) { model.chooseCleanupFolders() }
            } label: { Image(systemName: "chevron.down").frame(width: ShouDesign.cleanupScanMenuWidth, height: ShouDesign.cleanupScanButtonHeight) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(model.t("Scan Scope"))
                .accessibilityIdentifier("smart.scan-mode")
        }
        .font(ShouType.body.weight(.medium)).foregroundStyle(ShouDesign.actionText)
        .background(LinearGradient(colors: [ShouDesign.actionStart, ShouDesign.actionEnd], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: ShouDesign.cardRadius))
        .disabled(model.busy).fixedSize()
    }
}

struct CleanupVolumePicker: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var volumes=[CleanupScanVolume]()
    @State private var selected=Set<String>()
    @State private var error: String?
    @State private var loading=true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.t("Select Disks")).font(ShouType.title.weight(.semibold))
            List(volumes) { volume in
                Toggle(isOn: Binding(get: { volume.isSystem || selected.contains(volume.path) }, set: { if $0 { selected.insert(volume.path) } else { selected.remove(volume.path) } })) {
                    HStack(spacing: 12) {
                        Image(systemName: volume.isSystem ? "internaldrive" : "externaldrive")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(volume.name).font(ShouType.body)
                            Text(volume.isSystem ? model.t("System disk") : volume.path).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                        }
                    }
                }.toggleStyle(.checkbox).disabled(volume.isSystem)
            }.frame(height: 250)
            if loading { ProgressView().controlSize(.small) }
            if let error { Text(error).font(ShouType.caption).foregroundStyle(ShouPalette.warning) }
            HStack {
                Spacer()
                Button(model.t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.t("Start Scan")) { dismiss(); model.scanCommonLocations(scope: .volumes(Array(selected).sorted())) }
                    .buttonStyle(.borderedProminent).disabled(loading || volumes.isEmpty)
                    .accessibilityIdentifier("cleanup.volumes.scan")
            }
        }.padding(ShouDesign.pagePadding).frame(width: 560)
        .task {
            if case .volumes(let paths)=model.cleanupScanScope { selected=Set(paths) }
            do { volumes=try await Task.detached { try NativeCleanupLocations().localVolumes() }.value }
            catch { self.error=error.localizedDescription }
            loading=false
        }
    }
}
