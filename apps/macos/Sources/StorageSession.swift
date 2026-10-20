import SwiftUI
import ShouCore
import ShouPlatform
import AppKit
import Observation

struct StorageLocation: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let symbol: String
}

@MainActor @Observable final class StorageSession {
    var scan: StorageScan?
    var index=StorageIndex(entries: [])
    var entries: [String: FileEntry]=[:]
    var location="/System/Volumes/Data"
    var locations: [StorageLocation]=[]
    var path="."
    var focus: String?
    var hovered: String?
    var selected=Set<String>()
    var back=[String]()
    var forward=[String]()
    var query=""
    var sort="size"
    var progress: ScanProgress?
    var scanning=false
    var stopRequested=false
    var reviewing=false
    var plan: StorageRemovalPlan?
    var elapsed: TimeInterval=0
    var startedAt=Date()
    private var task: Task<Void, Never>?
    private var operation=UUID()
    var progressTitle: String {
        if stopRequested { return "Stopping scan…" }
        switch progress?.stage {
        case "analysis": return "Organizing measured entries…"
        case "transferring", "loading", "validating": return "Loading measured results…"
        case "saving": return "Saving space analysis…"
        case "indexing": return "Building the space map…"
        default: return "Analyzing disk space…"
        }
    }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + (index.nodes[$1]?.allocatedBytes ?? 0) } }
    var children: [StorageNode] {
        let nodes=index.children(of: path).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        switch sort {
        case "name": return nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "count": return nodes.sorted { $0.fileCount == $1.fileCount ? $0.path < $1.path : $0.fileCount > $1.fileCount }
        default: return nodes
        }
    }
    func loadLocations() {
        guard locations.isEmpty else { return }
        let volumes=FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey, .volumeIsLocalKey, .volumeIsReadOnlyKey], options: [.skipHiddenVolumes]) ?? []
        locations=[StorageLocation(path: "/System/Volumes/Data", name: (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD", symbol: "internaldrive")]
        for url in volumes where url.path != "/" && url.path != "/System/Volumes/Data" {
            if let values=try? url.resourceValues(forKeys: [.volumeNameKey, .volumeIsLocalKey]), values.volumeIsLocal == true {
                locations.append(StorageLocation(path: url.path, name: values.volumeName ?? url.lastPathComponent, symbol: "externaldrive"))
            }
        }
        let home=FileManager.default.homeDirectoryForCurrentUser
        locations.append(StorageLocation(path: home.path, name: NSFullUserName(), symbol: "house"))
    }
    func chooseFolder(app: AppModel) {
        guard !app.busy else { return }
        let panel=NSOpenPanel(); panel.canChooseFiles=false; panel.canChooseDirectories=true
        panel.message=app.t("Choose a disk or folder to analyze.")
        guard panel.runModal() == .OK, let url=panel.url else { return }
        location=url.resolvingSymlinksInPath().standardizedFileURL.path
        if !locations.contains(where: { $0.path == location }) { locations.append(StorageLocation(path: location, name: url.lastPathComponent, symbol: "folder")) }
        scan=nil; selected=[]
    }
    func reason(_ node: StorageNode) -> String? {
        guard let scan, let entry=entries[node.path] else { return "Item is absent from this analysis." }
        if entry.owner != getuid() { return "This item is not owned by the current user." }
        return StorageRemovalPolicy.reason(root: scan.rootPath, path: node.path, entry: entry, home: FileManager.default.homeDirectoryForCurrentUser.path, protectedPaths: [LocalRecordStore.defaultDirectory.path])
    }
    func isSelected(_ path: String) -> Bool { StorageSelection.contains(path, in: selected) }
    func toggle(_ node: StorageNode, app: AppModel) {
        guard !app.busy, reason(node) == nil else { return }
        selected=StorageSelection.toggle(node.path, selected: !isSelected(node.path), paths: selected, index: index)
        selected=selected.filter { index.nodes[$0].map { reason($0) == nil } ?? false }
    }
    func selectVisible(app: AppModel) {
        guard !app.busy else { return }
        let eligible=children.filter { reason($0) == nil }
        let all=eligible.allSatisfy { isSelected($0.path) }
        for node in eligible { selected=StorageSelection.toggle(node.path, selected: !all, paths: selected, index: index) }
        selected=selected.filter { index.nodes[$0].map { reason($0) == nil } ?? false }
    }
    func navigate(_ next: String) {
        guard next != path, index.nodes[next]?.kind == "directory" else { return }
        back.append(path); forward=[]; path=next; focus=nil; query=""
    }
    func goBack() { guard let previous=back.popLast() else { return }; forward.append(path); path=previous; query="" }
    func goForward() { guard let next=forward.popLast() else { return }; back.append(path); path=next; query="" }
    func start(app: AppModel, retainPath: Bool = false) {
        guard let engine=app.engine, !app.busy else { return }
        let root=location, previous=retainPath ? path : ".", token=UUID(); operation=token
        app.busy=true; scanning=true; stopRequested=false; progress=nil; selected=[]; plan=nil; startedAt=Date()
        app.statusKey="Scanning disk usage…"
        task=Task {
            defer { if operation == token { app.busy=false; scanning=false; stopRequested=false } }
            do {
                let result=try await engine.scanStorage(path: root, progress: { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.operation == token, self.scanning, !self.stopRequested,
                              self.progress?.stage != "indexing" else { return }
                        self.progress=update
                    }
                })
                try Task.checkCancellation()
                progress=ScanProgress(stage: "indexing", entryCount: result.tree.entries.count, currentPath: root, limitReached: result.tree.issues.contains("resource_limit"))
                let indexing=Task.detached(priority: .userInitiated) {
                    let tree=try StorageIndex(entries: result.tree.entries, checkpoint: { try Task.checkCancellation() })
                    var entries=[String: FileEntry]()
                    entries.reserveCapacity(result.tree.entries.count)
                    for (index, entry) in result.tree.entries.enumerated() {
                        if index % 4096 == 0 { try Task.checkCancellation() }
                        entries[entry.path]=entry
                    }
                    try Task.checkCancellation()
                    return (tree, entries)
                }
                let (tree, lookup)=try await withTaskCancellationHandler { try await indexing.value } onCancel: { indexing.cancel() }
                try Task.checkCancellation()
                guard operation == token else { return }
                scan=result; index=tree; entries=lookup
                path=tree.nodes[previous]?.kind == "directory" ? previous : "."; focus=nil; hovered=nil; back=[]; forward=[]
                elapsed=Date().timeIntervalSince(startedAt)
                app.statusKey=result.tree.complete ? "Space analysis complete." : "Some locations could not be measured. Review scan coverage."
            } catch { if !Task.isCancelled { app.error=error.localizedDescription }; app.statusKey="Scan stopped." }
        }
    }
    func stop() { if scanning { stopRequested=true }; task?.cancel() }
    func waitForOperation() async { await task?.value }
    func restart(app: AppModel) {
        guard !app.busy else { return }
        scan=nil; selected=[]; focus=nil; path="."; back=[]; forward=[]
    }
    func reveal(_ path: String) {
        guard let scan else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: StorageRemovalPolicy.absolute(root: scan.rootPath, relative: path))])
    }
    func copy(_ path: String) {
        guard let scan else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(StorageRemovalPolicy.absolute(root: scan.rootPath, relative: path), forType: .string)
    }
    func review(app: AppModel, action: String) {
        guard let engine=app.engine, let scan, !selected.isEmpty, !app.busy else { return }
        let paths=Array(selected)
        reviewing=true; app.busy=true; app.statusKey="Checking selected files…"
        task=Task {
            defer { reviewing=false; app.busy=false }
            do { plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: paths, action: action); app.statusKey="Ready to review" }
            catch { if !Task.isCancelled { app.error=error.localizedDescription } }
        }
    }
    func execute(app: AppModel, plan: StorageRemovalPlan) {
        guard let engine=app.engine, !app.busy else { return }
        self.plan=nil; app.busy=true; app.isExecuting=true; app.stopRequested=false; app.executionProgress=nil; app.operationHadError=false
        task=Task {
            do {
                let receipt=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "desktop", progress: { update in
                    Task { @MainActor in app.executionProgress=update }
                })
                let removed=receipt.items.filter { ["trashed", "purged"].contains($0.state) }.map(\.relativePath)
                app.operationHadError=receipt.items.contains { ["failed", "unknown", "moving", "purging"].contains($0.state) }
                if var current=scan {
                    current.tree.entries.removeAll { entry in removed.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") } }
                    scan=current; index=StorageIndex(entries: current.tree.entries); entries=Dictionary(uniqueKeysWithValues: current.tree.entries.map { ($0.path,$0) })
                    while path != "." && index.nodes[path] == nil { path=StorageIndex.parent(path) }
                }
                selected=[]; focus=nil
                app.completion=CleanupCompletion(receipts: [receipt])
                app.statusKey=receipt.state == "completed" ? "Selected items processed. Refresh to measure current disk usage." : "Some items could not be removed. Review the result."
                await app.refresh()
            } catch { app.operationHadError=true; app.error=error.localizedDescription }
            app.busy=false; app.isExecuting=false; app.stopRequested=false
        }
    }
}
