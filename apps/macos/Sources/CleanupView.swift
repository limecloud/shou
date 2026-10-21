import SwiftUI
import ShouCore
import ShouPlatform
import AppKit

struct CleanupView: View {
    @Bindable var model: AppModel
    @ReduceMotion private var reduceMotion
    let inspector: Bool
    var body: some View {
        VStack(spacing: 0) {
            CleanupPageHeader(model: model)
            if model.workspace == nil { LocationPicker(model: model) }
            else {
                CleanupSummary(model: model).padding(.horizontal, 24).padding(.bottom, 16)
                Divider()
                ZStack(alignment: .topLeading) {
                    if model.snapshot != nil && !model.scanning {
                        HSplitView {
                            CleanupOutlineTable(model: model, language: model.language, snapshotID: model.snapshot?.id, selection: model.selection, busy: model.busy, storageReady: !model.storage.nodes.isEmpty).frame(minWidth: 550)
                            if inspector { CandidateInspector(model: model).frame(minWidth: 230, idealWidth: 270, maxWidth: 320) }
                        }.transition(.opacity)
                    } else { ScanPlaceholder(model: model).transition(.opacity) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.scanning)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.snapshot?.id)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CleanupPageHeader: View {
    var model: AppModel
    var body: some View {
        HStack {
            Button { model.section="smart" } label: { Label(model.t("Smart Cleanup"), systemImage: "chevron.left") }
                .buttonStyle(.borderless).padding(.trailing, 12)
            Text(model.workspace?.path ?? model.t("Tidy up. That's it.")).font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(model.workspace?.path ?? "")
            Spacer()
        }.padding(.horizontal, 16).frame(height: 42)
    }
}

struct CleanupSummary: View {
    var model: AppModel
    @ReduceMotion private var reduceMotion
    private var segments: [(String, Int64, Color)] {
        var values=model.categories.map { (categoryTitle($0.id, model: model), $0.allocatedBytesEstimate, categoryColor($0.id)) }
        let known=values.reduce(Int64(0)) { $0 + $1.1 }
        let other=max(0, (model.storage.nodes["."]?.allocatedBytes ?? 0)-known)
        if other > 0 && model.snapshot?.scope != .cleanup { values.append((model.t("Other Files"),other,Color(nsColor: .systemGray))) }
        return values
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: "sparkles").font(.system(size: 22, weight: .medium)).foregroundStyle(.orange)
                    .frame(width: 44, height: 44).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.t(model.scanning ? "Scanning…" : "Ready to review")).font(.system(size: 12)).foregroundStyle(.secondary)
                    CapacityValue(bytes: model.eligibleBytes, measured: model.snapshot != nil && !model.scanning)
                    if model.scanning {
                        Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text(model.t("Selected") + " " + model.bytes(model.selectedBytes) + " · " + String(model.selected.count) + " " + model.t("items"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(model.selectedBytes)))
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.selectedBytes)
                    }
                }
                Spacer()
                Menu {
                    Button(model.t("Delete Permanently…"), role: .destructive) { model.previewCleanup() }
                    Button(model.t("Move to Trash…")) { model.previewCleanup(permanent: false) }
                } label: { Text(model.t("Clean & Free Space")) }
                    primaryAction: { model.previewCleanup() }
                    .menuStyle(.borderlessButton).fixedSize().buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.busy || model.selected.isEmpty || model.selected.contains { !$0.eligible } || model.snapshot?.previewOnly == true)
            }
            CapacityDots(segments: segments.map { ($0.1,$0.2) }, scanning: model.scanning).frame(height: 88).accessibilityHidden(true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 15) {
                    ForEach(model.scanning ? [] : Array(segments.indices), id: \.self) { index in
                        HStack(spacing: 5) {
                            Circle().fill(segments[index].2).frame(width: 6, height: 6)
                            Text(segments[index].0 + " " + model.bytes(segments[index].1))
                        }
                    }
                    if let path=model.workspace?.path, let available=NativeFileSystem().availableBytes(path) {
                        HStack(spacing: 5) { Circle().fill(.quaternary).frame(width: 6, height: 6); Text(model.t("Available") + " " + model.bytes(available)) }
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !model.scanning, let snapshot=model.snapshot, snapshot.status != "complete" {
                HStack(spacing: 8) {
                    Label(model.t("Some paths could not be fully scanned. Only independently verified items can be reviewed for cleanup."), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Spacer()
                    Button(model.t("Choose Folder…")) { model.addWorkspace() }.disabled(model.busy)
                }.font(.caption)
            }
        }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
    }
}

struct WorkspaceHeader: View {
    var model: AppModel
    let title: String
    let symbol: String
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Label(model.t(title), systemImage: symbol).font(.title2.weight(.semibold))
                Text(model.workspace?.path ?? model.t("Tidy up. That's it.")).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer()
            if let root=model.workspace, let free=NativeFileSystem().availableBytes(root.path) {
                VStack(alignment: .trailing, spacing: 4) { Text(model.bytes(free)).font(.title3.monospacedDigit()); Text(model.t("Available on volume")).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(24)
    }
}

struct LocationPicker: View {
    var model: AppModel
    private var locations: [(String,String,String)] {
        let home=FileManager.default.homeDirectoryForCurrentUser.path
        return [("Developer Tool Caches", "shippingbox", home + "/Library/Caches"), ("npm Cache", "shippingbox", home + "/.npm"), ("Cargo Cache", "shippingbox", home + "/.cargo"), ("Xcode Data", "hammer", home + "/Library/Developer/Xcode")].filter { FileManager.default.fileExists(atPath: $0.2) }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "externaldrive.badge.magnifyingglass").font(.system(size: 52, weight: .light)).foregroundStyle(Color.accentColor)
                VStack(spacing: 10) {
                    Text(model.t("Find what is taking up space.")).font(.largeTitle.weight(.semibold))
                    Text(model.t("Choose your project collection. Shou finds build outputs and caches with built-in rules, then shows exactly what can be reviewed."))
                        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
                }
                Button(model.t("Choose Project Folder…")) { model.addWorkspace() }.buttonStyle(.borderedProminent).controlSize(.large)
                Text(model.t("Or inspect a common location")).font(.callout).foregroundStyle(.secondary).padding(.top, 12)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(locations, id: \.2) { location in
                        Button { model.addSuggestedLocation(location.2) } label: {
                            HStack { Image(systemName: location.1).foregroundStyle(Color.accentColor); Text(model.t(location.0)); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }.padding(12)
                        }.buttonStyle(.bordered)
                    }
                }.frame(maxWidth: 540)
                Label(model.t("Read-only scanning. Nothing is deleted or selected automatically."), systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            }.padding(40).frame(maxWidth: .infinity)
        }
    }
}

struct ScanPlaceholder: View {
    var model: AppModel
    var body: some View {
        Group {
            if model.scanning { ScanActivity(model: model) }
            else {
                ContentUnavailableView {
                    Label(model.t("Ready to inspect this folder"), systemImage: "externaldrive.badge.magnifyingglass")
                } description: {
                Text(model.t("Built-in rules identify common artifacts. Personal rules cover your own tools."))
                } actions: {
                    Button(model.t("Scan Workspace")) { model.startScan() }.buttonStyle(.borderedProminent).disabled(model.busy)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor func categoryTitle(_ category: String, model: AppModel) -> String {
    model.t(["build":"Build Outputs", "dependencies":"Installed Dependencies", "cache":"Project Caches", "packages":"Package Manager Caches", "personal":"Personal Rules"][category] ?? "Other")
}
func categorySymbol(_ category: String) -> String { ["build":"hammer.fill", "dependencies":"shippingbox.fill", "cache":"arrow.triangle.2.circlepath", "packages":"cube.box.fill", "personal":"slider.horizontal.3"][category] ?? "folder" }
func categoryColor(_ category: String) -> Color { ["build": Color.blue, "dependencies": .orange, "cache": .teal, "packages": .purple, "personal": .indigo][category] ?? .secondary }

struct PathActions: View {
    var model: AppModel
    let path: String
    var body: some View {
        if model.workspace != nil {
            Button(model.t("Reveal in Finder")) { model.revealPath(path) }
            Button(model.t("Copy Path")) { model.copyPath(path) }
            Button(model.t("Show in Space Analysis")) { model.showInSpaceAnalysis(path) }
        }
    }
}
