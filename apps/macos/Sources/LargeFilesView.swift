import AppKit
import QuickLook
import ShouCore
import SwiftUI

struct LargeFilesView: View {
    @Bindable var model: AppModel
    @Bindable var session: LargeFilesSession
    @State private var previewURL: URL?
    @State private var coverage=false
    @FocusState private var listFocused: Bool
    private var storage: StorageSession { session.storage }

    var body: some View {
        VStack(spacing: 0) {
            if storage.scanning { StorageScanProgressView(model: model, session: storage) }
            else if storage.scan == nil { entry }
            else { results }
        }
        .task { storage.loadLocations(); session.loadIfNeeded(app: model) }
        .onChange(of: storage.scan?.id) { _, _ in session.loadIfNeeded(app: model) }
        .onChange(of: model.busy) { _, busy in if !busy { session.loadIfNeeded(app: model) } }
        .onChange(of: session.minimumBytes) { _, _ in session.load(app: model) }
        .onChange(of: session.type) { _, _ in session.load(app: model) }
        .quickLookPreview($previewURL)
        .toolbar {
            ToolbarItemGroup {
                if storage.scan != nil && !storage.scanning {
                    Button { storage.start(app: model) } label: { Label(model.t("Scan Again"), systemImage: "arrow.clockwise") }
                        .labelStyle(.iconOnly).help(model.t("Scan Again")).disabled(model.busy || session.loading)
                    Button(model.t("Start Over")) { storage.restart(app: model) }.disabled(model.busy || session.loading)
                }
                DiskCapacityView(model: model, path: storage.location)
            }
        }
    }
    private var entry: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 52, weight: .light)).foregroundStyle(Color.accentColor)
            Text(model.t("Find the files taking up the most space")).font(.title2.weight(.semibold))
            Text(model.t("See large files across folders, then choose what to remove."))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Picker(model.t("Scan Location"), selection: Binding(get: { storage.location }, set: { storage.location=$0 })) {
                ForEach(storage.locations) { Label($0.name, systemImage: $0.symbol).tag($0.path) }
            }.frame(width: 300).labelsHidden().accessibilityLabel(model.t("Scan Location"))
            HStack(spacing: 14) {
                Button(model.t("Choose Folder…")) { storage.chooseFolder(app: model) }
                if model.space.scan != nil && !model.space.hasChanges {
                    Button(model.t("Use Latest Space Analysis")) { session.useSpaceAnalysis(app: model) }
                        .accessibilityIdentifier("large-files.reuse-analysis")
                }
            }.buttonStyle(.link).disabled(model.busy || session.loading)
            if session.loading {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(model.t("Loading measured results…")).foregroundStyle(.secondary)
                    Button(model.t("Stop")) { session.stop() }
                }
            }
            Button { storage.start(app: model) } label: {
                Label(model.t("Start Scan"), systemImage: "magnifyingglass").padding(.horizontal, 18).padding(.vertical, 7)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || session.loading)
                .accessibilityIdentifier("large-files.start")
            Text(model.t("Scanning reads file sizes. Nothing is selected or deleted automatically."))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(28).frame(maxWidth: .infinity)
    }
    private var results: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(storage.hasChanges ? model.t("Files changed. Scan again to update totals.") : session.hasLoaded ? String(format: model.t("%lld large files found"), session.totalCount) : model.t(session.loading ? "Loading measured results…" : "Results are not ready"))
                        .font(.headline)
                    Text(storage.scan?.rootPath ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if storage.scan?.tree.complete == false {
                    Button { coverage=true } label: { Label(model.t("Scan Coverage"), systemImage: "exclamationmark.triangle") }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help(model.t("Partial analysis: some locations could not be fully measured."))
                        .popover(isPresented: $coverage) { StorageCoverageView(model: model, session: storage, dismiss: { coverage=false }) }
                }
                if !storage.hasChanges && session.hasLoaded { Text(model.bytes(session.totalBytes)).font(.title2.weight(.semibold)).monospacedDigit() }
            }.padding(.horizontal, 16).padding(.vertical, 10)
            HStack(spacing: 14) {
                Picker(model.t("Minimum Size"), selection: $session.minimumBytes) {
                    ForEach([50, 100, 500, 1024], id: \.self) { value in Text(value == 1024 ? "1 GiB" : "\(value) MiB").tag(Int64(value) * 1024 * 1024) }
                }.frame(width: 210).disabled(model.busy || session.loading)
                Picker(model.t("File Type"), selection: $session.type) {
                    ForEach(StorageFileType.allCases, id: \.self) { Text(model.t(typeTitle($0))).tag($0) }
                }.frame(width: 220).disabled(model.busy || session.loading)
                Spacer()
                if session.loading {
                    ProgressView().controlSize(.small)
                    Button(model.t("Stop")) { session.stop() }
                }
            }.padding(.horizontal, 20).padding(.bottom, 14)
            Divider()
            HStack(spacing: 10) {
                let eligible=session.visibleItems.filter { storage.reason($0.node) == nil }
                let count=eligible.filter { storage.isSelected($0.node.path) }.count
                SelectionCheckbox(state: count == 0 ? .off : count == eligible.count ? .on : .mixed,
                    enabled: !eligible.isEmpty && !model.busy && !session.loading,
                    label: model.t("Select Loaded Files"), identifier: "large-files.select-loaded") { session.selectLoaded(app: model) }
                    .frame(width: 18, height: 18)
                Text(model.t("Name")).font(.caption.weight(.medium))
                Spacer()
                Text(model.t("Size on Disk")).font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(session.visibleItems, id: \.node.path) { row($0) }
                    if session.nextCursor != nil {
                        Button(model.t("Load More")) { session.load(app: model, more: true) }
                            .disabled(session.loading || model.busy).padding(18).accessibilityIdentifier("large-files.more")
                    }
                }
            }.focusable().focusEffectDisabled().focused($listFocused)
                .onKeyPress(keys: ["a", .escape]) { press in
                    guard listFocused, !model.busy, !session.loading else { return .ignored }
                    if press.key == "a", press.modifiers == .command { session.selectAll(app: model); return .handled }
                    if press.key == .escape { storage.selected=[]; return .handled }
                    return .ignored
                }
                .overlay {
                    if !session.loading && session.visibleItems.isEmpty {
                        if session.hasLoaded {
                            ContentUnavailableView(model.t("No matching large files"), systemImage: "doc.text.magnifyingglass",
                                description: Text(model.t("Try a smaller size or another file type.")))
                        } else {
                            VStack(spacing: 14) {
                                Label(model.t("Results are not ready"), systemImage: "pause.circle").foregroundStyle(.secondary)
                                Button(model.t("Continue")) { session.load(app: model) }
                                    .disabled(model.busy)
                            }
                        }
                    }
                }
            actionBar
        }
    }
    private func row(_ item: StorageCatalogItem) -> some View {
        let node=item.node, reason=storage.reason(item.node)
        return HStack(spacing: 12) {
            SelectionCheckbox(state: storage.isSelected(node.path) ? .on : .off,
                enabled: reason == nil && !model.busy && !session.loading,
                label: model.t("Select Item") + " " + node.name, identifier: "large-files.select." + node.path) { storage.toggle(node, app: model) }
                .frame(width: 18, height: 18).help(reason.map(model.t) ?? model.t("Select Item"))
            Image(nsImage: NSWorkspace.shared.icon(forFile: absolute(node.path))).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(node.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(node.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(model.bytes(node.allocatedBytes)).font(.callout.monospacedDigit())
            Button { previewURL=URL(fileURLWithPath: absolute(node.path)) } label: { Image(systemName: "eye") }
                .buttonStyle(.borderless).help(model.t("Quick Look")).accessibilityLabel(model.t("Quick Look") + " " + node.name)
        }.padding(.horizontal, 20).padding(.vertical, 12)
            .background(storage.isSelected(node.path) ? Color.accentColor.opacity(0.06) : .clear)
            .contentShape(Rectangle()).onTapGesture(count: 2) { previewURL=URL(fileURLWithPath: absolute(node.path)) }
            .contextMenu {
                Button(model.t("Investigate Containing Folder")) { model.ai.requestLaunch(app: model, path: (absolute(node.path) as NSString).deletingLastPathComponent) }.disabled(model.busy)
                Button(model.t("Reveal in Finder")) { storage.reveal(node.path) }
                Button(model.t("Copy Path")) { storage.copy(node.path) }
                Button(model.t("Quick Look")) { previewURL=URL(fileURLWithPath: absolute(node.path)) }
            }
    }
    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: model.t("%lld items selected"), storage.selected.count)).font(.caption).foregroundStyle(.secondary)
                    Text(model.bytes(storage.selectedBytes)).font(.title3.weight(.semibold)).monospacedDigit()
                }
                Spacer()
                Menu(model.t("Select Items")) {
                    Button(model.t("Select All Matching Files")) { session.selectAll(app: model) }
                    Button(model.t("Clear Selection")) { storage.selected=[] }
                }.fixedSize().disabled(model.busy || session.loading || !session.hasLoaded)
                StorageRemovalButton(model: model, session: storage, disabled: session.loading, identifier: "large-files.clean")
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }.background(.bar)
    }
    private func absolute(_ path: String) -> String { StorageRemovalPolicy.absolute(root: storage.scan?.rootPath ?? storage.location, relative: path) }
    private func typeTitle(_ type: StorageFileType) -> String {
        switch type {
        case .all: "All Types"
        case .video: "Videos"
        case .audio: "Audio"
        case .image: "Images"
        case .archive: "Archives"
        case .document: "Documents"
        case .aiModel: "AI Models"
        case .other: "Other Files"
        }
    }
}
