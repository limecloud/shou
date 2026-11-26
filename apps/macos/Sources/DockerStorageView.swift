import ShouCore
import ShouPlatform
import SwiftUI

struct DockerStorageButton: View {
    var model: AppModel
    var identifier="storage.docker-storage"
    @State private var presented=false
    var body: some View {
        Button(model.t("Docker storage…")) { presented=true }
            .disabled(model.busy).accessibilityIdentifier(identifier)
            .sheet(isPresented: $presented) { DockerStorageView(model: model) }
    }
}

struct DockerStorageView: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var service: DockerStorageService?
    @State private var contexts=[DockerStorageContext]()
    @State private var context=""
    @State private var scan: DockerStorageScan?
    @State private var selected=Set<String>()
    @State private var category="all"
    @State private var volumeConsent=false
    @State private var reclaimDisk=false
    @State private var plan: DockerStoragePlan?
    @State private var result: DockerStorageReceipt?
    @State private var loading=false
    @State private var executing=false
    @State private var issue: String?
    @State private var operation: Task<Void, Never>?
    private var selectedObjects: [DockerStorageObject] { scan?.inventory.objects.filter { selected.contains($0.id) } ?? [] }
    private var volumeSelected: Bool { selectedObjects.contains { $0.kind == .volume } }
    private var visibleObjects: [DockerStorageObject] {
        (scan?.inventory.objects.filter { category == "all" || $0.kind.rawValue == category } ?? []).sorted {
            ($0.bytes ?? -1) == ($1.bytes ?? -1) ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : ($0.bytes ?? -1) > ($1.bytes ?? -1)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.t("Docker storage")).font(ShouType.title.weight(.semibold))
            if executing {
                ProgressView(model.t("Cleaning tool-managed storage…"))
                Text(model.t("Wait for Docker's result. An interrupted request can have an uncertain outcome."))
                    .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                Spacer()
            } else if let result { results(result) }
            else {
                HStack {
                    Picker(model.t("Local Docker context"), selection: $context) {
                        ForEach(contexts) { Text($0.name).tag($0.name) }
                    }.disabled(loading || plan != nil).onChange(of: context) { _, _ in load() }
                    Button(model.t("Check Again")) { load() }.disabled(loading || plan != nil)
                }
                if loading { ProgressView(model.t("Checking Docker storage…")) }
                if let scan {
                    Text(scan.inventory.context.endpoint).font(ShouType.caption.monospaced()).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
                    Text(model.t("Image sizes can share layers. Volumes may contain databases; unused does not mean disposable."))
                        .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    if plan == nil {
                        HStack {
                            Picker(model.t("Show"), selection: $category) {
                                Text(model.t("All")).tag("all")
                                ForEach([DockerStorageKind.buildCache, .container, .image, .volume], id: \.rawValue) { kind in Text(title(kind)).tag(kind.rawValue) }
                            }.pickerStyle(.segmented)
                            let eligible=Set(visibleObjects.filter { $0.blockingReason == nil }.map(\.id))
                            Button(model.t(!eligible.isEmpty && eligible.isSubset(of: selected) ? "Clear Selection" : "Select All")) {
                                if eligible.isSubset(of: selected) { selected.subtract(eligible) } else { selected.formUnion(eligible) }
                                volumeConsent=false
                            }.disabled(loading || eligible.isEmpty)
                        }
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(plan?.objects ?? visibleObjects) { object in objectRow(object) }
                            if (plan?.objects ?? visibleObjects).isEmpty { Text(model.t("No items in this category.")).font(ShouType.body).foregroundStyle(ShouPalette.secondary).padding(.vertical) }
                        }
                    }.frame(maxHeight: .infinity)
                    if volumeSelected {
                        Toggle(model.t("Permanently delete the data in the selected volumes"), isOn: $volumeConsent).disabled(plan != nil)
                            .accessibilityIdentifier("docker.volume-data-consent")
                    }
                    if let disk=scan.inventory.reclamation {
                        Text(model.t("Virtual disk allocated space") + " " + model.bytes(disk.allocatedBytes) + ", " + model.t("Guest free space") + " " + model.bytes(disk.guestAvailableBytes))
                            .font(ShouType.caption).monospacedDigit()
                        Toggle(model.t("Reclaim virtual disk space after cleanup"), isOn: $reclaimDisk).disabled(plan != nil)
                            .accessibilityIdentifier("docker.reclaim-after-cleanup")
                        Text(model.t("Colima VZ uses online TRIM to return unused blocks. The VM stays running; logical capacity stays unchanged."))
                            .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    } else {
                        Text(model.t("This backend has no verified disk reclamation adapter. Containers and volumes are not stopped or removed to shrink a disk."))
                            .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                        if let reason=scan.inventory.reclamationIssue { Text(model.diagnostic(reason)).font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
                    }
                    if let plan {
                        if plan.objects.contains(where: { $0.kind == .container }) {
                            Text(model.t("Removing a stopped container permanently deletes its writable files. Its volumes are kept."))
                                .font(ShouType.caption).foregroundStyle(ShouPalette.warning)
                        }
                        if plan.objects.contains(where: { $0.kind == .image || $0.kind == .buildCache }) {
                            Text(model.t("Images and build cache may need to be downloaded or rebuilt later."))
                                .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                        }
                        Text(plan.objects.contains { $0.kind == .buildCache }
                            ? model.t("The reviewed cache scope includes unused build cache last used before this scan; later cache entries are kept.")
                            : model.t("Only the reviewed objects are removed. Running containers and unselected data are kept."))
                            .font(ShouType.caption).foregroundStyle(ShouPalette.warning)
                    }
                } else { Spacer() }
            }
            if let issue { Text(issue).font(ShouType.caption).foregroundStyle(ShouPalette.danger).textSelection(.enabled) }
            Divider()
            HStack {
                Button(model.t(executing ? "Stop" : "Done")) { if executing { model.cancel() } else { dismiss() } }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !executing && result == nil {
                    if let plan {
                        Button(model.t("Cancel")) { self.plan=nil }
                        Button(model.t(plan.objects.isEmpty ? "Reclaim Disk Space" : "Clean Permanently"), role: plan.objects.isEmpty ? nil : .destructive) { execute(plan) }
                            .buttonStyle(.borderedProminent).tint(plan.objects.isEmpty ? ShouPalette.accent : ShouPalette.danger)
                            .accessibilityIdentifier("docker.confirm-cleanup")
                    } else {
                        Text(String(format: model.t("%lld items selected"), locale: model.language.locale, selected.count)).font(ShouType.caption)
                        Button(model.t("Review Cleanup…")) { prepare() }
                            .disabled(loading || scan == nil || (selected.isEmpty && !reclaimDisk) || (volumeSelected && !volumeConsent))
                            .accessibilityIdentifier("docker.review-cleanup")
                    }
                }
            }
        }.font(ShouType.body).padding(24).frame(width: 740, height: 560)
            .interactiveDismissDisabled(executing || loading)
            .task { load() }
            .onDisappear { if !executing { operation?.cancel() } }
    }
    private func title(_ kind: DockerStorageKind) -> String {
        model.t([.buildCache: "Build cache", .container: "Docker containers", .image: "Docker images", .volume: "Volumes"][kind]!)
    }
    private func objectRow(_ object: DockerStorageObject) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(get: { selected.contains(object.id) }, set: { if $0 { selected.insert(object.id) } else { selected.remove(object.id) }; volumeConsent=false })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(object.kind == .buildCache ? model.t("Unused build cache") : object.kind == .image && object.name == object.objectId ? model.t("Untagged Docker image") : object.name).lineLimit(1).truncationMode(.middle)
                    Text(title(object.kind) + ", " + model.t(object.blockingReason ?? (object.state == "local" ? "No container references" : object.state))).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    if object.name != object.objectId || object.kind == .image { Text(object.objectId).font(ShouType.caption.monospaced()).foregroundStyle(ShouPalette.secondary).lineLimit(1).textSelection(.enabled) }
                }
            }.toggleStyle(.checkbox).disabled(plan != nil || object.blockingReason != nil)
            Spacer(minLength: 8)
            Text(object.bytes.map(model.bytes) ?? model.t("Not measured")).font(ShouType.caption).monospacedDigit().foregroundStyle(ShouPalette.secondary)
        }.padding(.vertical, 8)
    }
    private func load() {
        guard !loading, !executing else { return }
        loading=true; issue=nil; scan=nil; plan=nil; selected=[]; volumeConsent=false; reclaimDisk=false
        operation=Task {
            defer { loading=false }
            do {
                let current: DockerStorageService
                if let service { current=service }
                else { current=DockerStorageService(platform: NativeDockerStorage(), store: try LocalRecordStore()); service=current }
                if contexts.isEmpty {
                    contexts=try await current.contexts()
                    context=contexts.first(where: \.current)?.name ?? contexts.first?.name ?? ""
                }
                guard !context.isEmpty else { throw ShouError("tool_unavailable", model.t("No local Docker context found.")) }
                scan=try await current.scan(context: context)
            } catch { if !Task.isCancelled { issue=model.diagnostic(error.localizedDescription) } }
        }
    }
    private func prepare() {
        guard let service, let scan, !loading else { return }
        loading=true; issue=nil
        operation=Task {
            defer { loading=false }
            do { plan=try await service.createPlan(scan: scan, objectIds: selected, reclaimDisk: reclaimDisk, volumeDataConsent: volumeConsent) }
            catch { issue=model.diagnostic(error.localizedDescription) }
        }
    }
    private func execute(_ plan: DockerStoragePlan) {
        guard let service, !executing, !model.busy else { return }
        executing=true; issue=nil
        model.executeDockerStorage(plan, service: service) { outcome in
            executing=false; self.plan=nil; selected=[]
            switch outcome {
            case .success(let receipt): result=receipt
            case .failure(let error): issue=model.diagnostic(error.localizedDescription); scan=nil
            }
        }
    }
    @ViewBuilder private func results(_ value: DockerStorageReceipt) -> some View {
        Text(model.t(value.state == "completed" ? "Cleanup complete" : "Some items need attention")).font(ShouType.body.weight(.semibold))
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(value.items) { item in
                    HStack { Text(item.object.name).lineLimit(1); Spacer(); Text(model.t(item.state)).foregroundStyle(ShouPalette.secondary) }
                    if let error=item.error { Text(model.diagnostic(error)).font(ShouType.caption).foregroundStyle(ShouPalette.warning) }
                }
                if let before=value.diskBefore, let after=value.diskAfter {
                    Divider()
                    diskMetric("Virtual disk logical capacity", before.logicalBytes, after.logicalBytes)
                    diskMetric("Virtual disk allocated space", before.allocatedBytes, after.allocatedBytes)
                    diskMetric("Guest free space", before.guestAvailableBytes, after.guestAvailableBytes)
                }
                if let before=value.volumeAvailableBefore, let after=value.volumeAvailableAfter {
                    Text(model.t("Volume available change") + " " + (after >= before ? "+" : "−") + model.bytes(abs(after-before))).monospacedDigit()
                }
                if let diskState=value.diskState { Text(model.t("Disk reclamation") + ": " + model.t(diskState)) }
                if let error=value.error { Text(model.diagnostic(error)).foregroundStyle(ShouPalette.warning) }
                Text(model.t("Available space changed during this operation. Other writes, APFS and virtual disks can affect it.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                if value.state != "completed" { Text(model.t("Review the tool's current state before trying again. The previous operation may have changed data.")).font(ShouType.caption).foregroundStyle(ShouPalette.warning) }
            }
        }
    }
    private func diskMetric(_ title: String, _ before: Int64, _ after: Int64) -> some View {
        HStack { Text(model.t(title)); Spacer(); Text(model.bytes(before) + " → " + model.bytes(after)).monospacedDigit() }
    }
}
