import SwiftUI
import ShouCore
import ShouPlatform
import ShouAgentSupport
import AppKit
import Observation

struct StorageLocation: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let symbol: String
}

@MainActor @Observable final class StorageSession {
    var detailed=UserDefaults.standard.bool(forKey: "ShouStorageDetailed") {
        didSet { UserDefaults.standard.set(detailed, forKey: "ShouStorageDetailed") }
    }
    var presentation: StoragePresentation?
    var loadingPresentation=false
    var extensionFilter: String?
    var copyingAnalysis=false
    var analysisCopied=false
    var analysisHandoffStarted=false
    var directoryOffsets=[String: Int]()
    var directoryTotals=[String: Int]()
    private var presentationCache=[String: StoragePresentation]()
    private var presentationTask: Task<Void, Never>?
    var presentationAggregates: [StorageMapAggregate] {
        guard let presentation else { return [] }
        let individualPaths=Set(presentation.items.map { $0.node.path })
        // An unrepresented directory may span several type groups. Keep its
        // remainder neutral until refreshed rather than showing stale colors.
        if removedNodes.contains(where: { $0.kind == "directory" && !individualPaths.contains($0.path) }) { return [] }
        let directories=Set([presentation.scope.node.path] + presentation.items.filter { $0.node.kind == "directory" }.map { $0.node.path })
        func parent(_ path: String) -> String {
            var value=StorageIndex.parent(path)
            while !directories.contains(value) && value != "." { value=StorageIndex.parent(value) }
            return value
        }
        return presentation.aggregates.compactMap { group in
            guard index.nodes[group.parentPath] != nil else { return nil }
            let removed=removedNodes.filter { $0.kind == "file" && !individualPaths.contains($0.path) && parent($0.path) == group.parentPath && StorageExtensionStat.suffix($0.name) == group.suffix }
            let bytes=max(0,group.allocatedBytes - removed.reduce(0) { $0 + $1.allocatedBytes })
            guard bytes > 0 else { return nil }
            return StorageMapAggregate(parentPath: group.parentPath, suffix: group.suffix, allocatedBytes: bytes, logicalBytes: max(0,group.logicalBytes - removed.reduce(0) { $0 + $1.logicalBytes }), fileCount: max(0,group.fileCount - removed.reduce(0) { $0 + $1.fileCount }))
        }
    }
    func loadPresentation(app: AppModel) {
        presentationTask?.cancel(); loadingPresentation=false
        guard detailed, let scan, let engine=app.engine else { return }
        let key=scan.id + ":" + path
        if let cached=presentationCache[key] { applyPresentation(cached); return }
        presentation=nil; loadingPresentation=true
        let scope=path
        presentationTask=Task {
            do {
                let result=try await engine.storagePresentation(scanId: scan.id, path: scope)
                try Task.checkCancellation()
                guard self.scan?.id == scan.id, path == scope else { return }
                if presentationCache.count >= 8 { presentationCache.removeAll() }
                presentationCache[key]=result; applyPresentation(result); loadingPresentation=false
            } catch { if !Task.isCancelled { loadingPresentation=false; app.error=error.localizedDescription } }
        }
    }
    private func applyPresentation(_ value: StoragePresentation) {
        presentation=value; includeItems(value.items)
        for row in value.omissions {
            directoryTotals[row.path]=row.childCount
            directoryOffsets[row.path]=max(directoryOffsets[row.path] ?? 0, row.displayedChildCount)
            if row.displayedChildCount == row.childCount { loadedDirectories.insert(row.path) }
        }
    }
    func expandDirectory(_ scope: String, app: AppModel, more: Bool = false) async {
        guard let engine=app.engine, let scan else { return }
        do {
            let offset=more ? directoryOffsets[scope] ?? 0 : 0
            let page=try await engine.storageDirectoryPage(scanId: scan.id, path: scope, offset: offset)
            guard self.scan?.id == scan.id else { return }
            includeItems(page.children); directoryTotals[scope]=page.totalCount
            directoryOffsets[scope]=offset + page.children.count
            if page.nextOffset == nil && offset == 0 { loadedDirectories.insert(scope) }
        } catch { if !Task.isCancelled { app.error=error.localizedDescription } }
    }
    func copyAnalysis(app: AppModel) {
        guard !copyingAnalysis, let engine=app.engine, let scan else { return }
        copyingAnalysis=true; analysisCopied=false
        let scope=path, focus=focus, selection=Array(selected), removed=removedNodes.map(\.path), query=query, filter=extensionFilter
        let executable=Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shou").path : "shou"
        let skill=(try? ShouAgentSkill.directory().appendingPathComponent("SKILL.md").path)
        Task {
            defer { copyingAnalysis=false }
            do {
                let context=try await engine.storageAnalysisContext(scanId: scan.id, path: scope, focusedPath: focus, selectedPaths: selection,
                    removedPaths: removed, nameFilter: query, extensionFilter: filter, cliPath: executable, skillPath: skill)
                let text=try context.text(locale: app.language.rawValue)
                guard self.scan?.id == scan.id, path == scope else { return }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(text, forType: .string) else { throw ShouError("clipboard_unavailable", "Could not copy analysis.") }
                analysisCopied=true; analysisHandoffStarted=true
                Task { try? await Task.sleep(for: .seconds(3)); analysisCopied=false }
            } catch { app.error=error.localizedDescription }
        }
    }
    var scan: StorageScan?
    var index=StorageIndex(entries: []) {
        didSet { indexRevision += 1; directoryChildrenCache=nil; visibleChildrenCache=nil }
    }
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
    var loadingDirectory=false
    var elapsed: TimeInterval=0
    var startedAt=Date()
    private var task: Task<Void, Never>?
    private var operation=UUID()
    private var engine: ShouEngine?
    private weak var application: AppModel?
    private var directoryTask: Task<Void, Never>?
    private var loadedDirectories=Set<String>()
    private var removedNodes=[StorageNode]()
    @ObservationIgnored private var indexRevision=0
    @ObservationIgnored private var directoryChildrenCache: (revision: Int, path: String, nodes: [StorageNode])?
    @ObservationIgnored private var visibleChildrenCache: (revision: Int, path: String, query: String, sort: String, root: String?, nodes: [StorageNode], eligible: [StorageNode])?
    private let homeDirectory=FileManager.default.homeDirectoryForCurrentUser.path
    private let recordDirectory=LocalRecordStore.defaultDirectory.path
    var hasChanges: Bool { !removedNodes.isEmpty }
    var coverageNotes: [StorageCoverageNote] { (scan?.tree.issues ?? []).map { StorageCoverageNote(issue: $0, root: scan?.rootPath ?? location) }.filter { $0.concerns(path) } }
    var actionableCoverage: [StorageCoverageNote] { coverageNotes.filter { !$0.systemManaged } }
    var currentFolderIncomplete: Bool { index.nodes[path]?.isComplete == false }
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
    var measuredChildren: [StorageNode] {
        // Read the observed inputs even on cache hits so SwiftUI still tracks
        // index replacement and navigation. Hover/selection need no re-sort.
        let index=index, path=path
        if let cached=directoryChildrenCache, cached.revision == indexRevision, cached.path == path { return cached.nodes }
        let nodes=index.children(of: path)
        directoryChildrenCache=(indexRevision, path, nodes)
        return nodes
    }
    var children: [StorageNode] {
        let base=measuredChildren, query=query, sort=sort, path=path, root=scan?.rootPath
        if let cached=visibleChildrenCache, cached.revision == indexRevision, cached.path == path,
           cached.query == query, cached.sort == sort, cached.root == root { return cached.nodes }
        let filtered=query.isEmpty ? base : base.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let nodes: [StorageNode]
        switch sort {
        case "name": nodes=filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case "count": nodes=filtered.sorted { $0.fileCount == $1.fileCount ? $0.path < $1.path : $0.fileCount > $1.fileCount }
        default: nodes=filtered
        }
        visibleChildrenCache=(indexRevision, path, query, sort, root, nodes, nodes.filter { reason($0) == nil })
        return nodes
    }
    var eligibleChildren: [StorageNode] {
        _ = children
        return visibleChildrenCache?.eligible ?? []
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
        do { location=try NativeDirectorySelection.path(for: url) }
        catch { app.error=error.localizedDescription; return }
        if !locations.contains(where: { $0.path == location }) { locations.append(StorageLocation(path: location, name: url.lastPathComponent, symbol: "folder")) }
        scan=nil; selected=[]
    }
    func reason(_ node: StorageNode) -> String? {
        guard let scan, let entry=entries[node.path] else { return "Item is absent from this analysis." }
        if entry.owner != getuid() { return "This item is not owned by the current user." }
        return StorageRemovalPolicy.reason(root: scan.rootPath, path: node.path, entry: entry, home: homeDirectory, protectedPaths: [recordDirectory])
    }
    func isSelected(_ path: String) -> Bool { StorageSelection.contains(path, in: selected) }
    func toggle(_ node: StorageNode, app: AppModel) {
        guard !app.busy, !loadingDirectory, reason(node) == nil else { return }
        if isSelected(node.path), let ancestor=selected.first(where: { node.path.hasPrefix($0 + "/") }), let engine, let scan {
            // A partial map cannot represent the siblings of a deselected child.
            // Read just its ancestry before expanding the selected parent.
            app.busy=true
            Task {
                defer { app.busy=false }
                do {
                    var current=ancestor
                    while current != node.path {
                        if !loadedDirectories.contains(current) {
                            let directory=try await engine.storageDirectory(scanId: scan.id, path: current)
                            guard self.scan?.id == scan.id else { return }
                            merge(directory)
                        }
                        guard let next=index.children(of: current).first(where: { node.path == $0.path || node.path.hasPrefix($0.path + "/") }) else { return }
                        current=next.path
                    }
                    selected=StorageSelection.toggle(node.path, selected: false, paths: selected, index: index)
                    selected=selected.filter { index.nodes[$0].map { reason($0) == nil } ?? false }
                } catch { app.error=error.localizedDescription }
            }
            return
        }
        selected=StorageSelection.toggle(node.path, selected: !isSelected(node.path), paths: selected, index: index)
        selected=selected.filter { index.nodes[$0].map { reason($0) == nil } ?? false }
    }
    func selectVisible(app: AppModel, toggle: Bool = true) {
        guard !app.busy, !loadingDirectory else { return }
        let eligible=eligibleChildren
        let all=toggle && eligible.allSatisfy { isSelected($0.path) }
        selected=StorageSelection.setting(Set(eligible.map(\.path)), selected: !all, in: selected, index: index)
        selected=selected.filter { index.nodes[$0].map { reason($0) == nil } ?? false }
    }
    func navigate(_ next: String) {
        guard next != path, index.nodes[next]?.kind == "directory" else { return }
        back.append(path); forward=[]; path=next; focus=nil; query=""
        loadDirectory(next)
    }
    func goBack() { guard let previous=back.popLast() else { return }; forward.append(path); path=previous; query=""; loadDirectory(previous) }
    func goForward() { guard let next=forward.popLast() else { return }; back.append(path); path=next; query=""; loadDirectory(next) }
    private func adjusted(_ node: StorageNode) -> StorageNode? {
        if removedNodes.contains(where: { node.path == $0.path || node.path.hasPrefix($0.path + "/") }) { return nil }
        var result=node
        for removed in removedNodes where node.path == "." || removed.path.hasPrefix(node.path + "/") {
            result.logicalBytes=max(0, result.logicalBytes - removed.logicalBytes)
            result.allocatedBytes=max(0, result.allocatedBytes - removed.allocatedBytes)
            result.fileCount=max(0, result.fileCount - removed.fileCount)
            result.isComplete=false
        }
        return result
    }
    private func merge(_ directory: StorageDirectory) {
        includeItems([directory.item] + directory.children)
        loadedDirectories.insert(directory.item.node.path)
    }
    func includeItems(_ items: [StorageCatalogItem]) {
        var nodes=index.nodes
        for item in items {
            guard let node=adjusted(item.node) else { continue }
            nodes[node.path]=node; entries[node.path]=item.entry
        }
        index=StorageIndex(nodes: Array(nodes.values))
    }
    func useExistingScan(_ result: StorageScan, app: AppModel) async throws {
        guard let engine=app.engine, !app.busy else { return }
        let directory=try await engine.storageDirectory(scanId: result.id)
        try Task.checkCancellation()
        self.engine=engine; application=app; directoryTask?.cancel()
        loadingDirectory=false; scan=result; location=result.rootPath
        index=StorageIndex(entries: []); entries=[:]; loadedDirectories=[]; removedNodes=[]
        directoryOffsets=[:]; directoryTotals=[:]; presentation=nil; presentationCache=[:]; extensionFilter=nil
        selected=[]; path="."; back=[]; forward=[]
        merge(directory)
    }
    private func loadDirectory(_ next: String) {
        directoryTask?.cancel()
        loadingDirectory=false
        guard !loadedDirectories.contains(next), let engine, let scan else { return }
        loadingDirectory=true
        directoryTask=Task {
            do {
                let directory=try await engine.storageDirectory(scanId: scan.id, path: next)
                try Task.checkCancellation()
                guard self.scan?.id == scan.id, self.path == next else { return }
                merge(directory); loadingDirectory=false
            } catch {
                if !Task.isCancelled, self.path == next { loadingDirectory=false; application?.error=error.localizedDescription }
            }
        }
    }
    func start(app: AppModel, retainPath: Bool = false, accessChecked: Bool = false) {
        guard let engine=app.engine, !app.busy else { return }
        if !accessChecked {
            app.scanAccess.prepareScan { [weak self, weak app] in
                guard let self, let app else { return }
                self.start(app: app, retainPath: retainPath, accessChecked: true)
            }
            return
        }
        self.engine=engine; application=app; directoryTask?.cancel(); loadingDirectory=false
        let root=location, previous=retainPath ? path : ".", token=UUID(); operation=token
        app.busy=true; scanning=true; stopRequested=false; progress=nil; selected=[]; startedAt=Date()
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
                let parts=previous == "." ? [] : previous.split(separator: "/")
                let total=1 + parts.count
                progress=ScanProgress(stage: "indexing", entryCount: result.entryCount, currentPath: root, completedUnitCount: 0, totalUnitCount: total)
                let directory=try await engine.storageDirectory(scanId: result.id)
                try Task.checkCancellation()
                guard operation == token else { return }
                scan=result; directoryOffsets=[:]; directoryTotals=[:]; presentation=nil; presentationCache=[:]; extensionFilter=nil; index=StorageIndex(entries: []); entries=[:]; loadedDirectories=[]; removedNodes=[]
                merge(directory)
                progress=ScanProgress(stage: "indexing", entryCount: result.entryCount, currentPath: root, completedUnitCount: 1, totalUnitCount: total)
                // Refresh restores the previous directory without loading every
                // file in the volume or building a million-entry UI dictionary.
                path="."
                if previous != "." {
                    for end in parts.indices {
                        try Task.checkCancellation()
                        let next=parts[...end].joined(separator: "/")
                        guard let current=try? await engine.storageDirectory(scanId: result.id, path: next) else { break }
                        merge(current); path=next
                        progress=ScanProgress(stage: "indexing", entryCount: result.entryCount, currentPath: root + "/" + next,
                            completedUnitCount: end + 2, totalUnitCount: total)
                    }
                }
                focus=nil; hovered=nil; back=[]; forward=[]
                elapsed=Date().timeIntervalSince(startedAt)
                app.statusKey=result.tree.complete ? "Space analysis complete." : "Some locations could not be measured. Review scan coverage."
            } catch {
                if Task.isCancelled { app.statusKey="Scan stopped." }
                else {
                    app.error=error.localizedDescription
                    app.statusKey="Space analysis could not be completed."
                }
            }
        }
    }
    func stop() { if scanning || reviewing { stopRequested=true }; task?.cancel() }
    func waitForOperation() async { await task?.value }
    func restart(app: AppModel) {
        guard !app.busy else { return }
        resetAnalysis()
    }
    private func resetAnalysis() {
        directoryTask?.cancel(); loadingDirectory=false
        presentationTask?.cancel(); presentation=nil; presentationCache=[:]; loadingPresentation=false
        scan=nil; selected=[]; focus=nil; hovered=nil; path="."; back=[]; forward=[]; query=""; extensionFilter=nil
        index=StorageIndex(entries: []); entries=[:]; loadedDirectories=[]; removedNodes=[]
        directoryOffsets=[:]; directoryTotals=[:]
    }
    func discardRemovedCatalogs(_ paths: Set<String>) {
        guard let id=scan?.catalogId,
              paths.contains(StorageRemovalPolicy.canonical(recordDirectory + "/storage-catalogs/" + id + ".sqlite")) else { return }
        resetAnalysis()
    }
    func rescanCurrentFolder(app: AppModel) {
        guard !app.busy, let scan else { return }
        location=StorageRemovalPolicy.absolute(root: scan.rootPath, relative: path)
        start(app: app)
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
    func removeSelected(app: AppModel, action: String) {
        guard let engine=app.engine, let scan, !selected.isEmpty, !app.busy else { return }
        // The inline action confirms this exact selection. Freeze it before
        // preparing the plan so subsequent UI changes cannot expand the scope.
        let paths=StorageSelection.normalized(selected).sorted(), sourceSection=app.section
        reviewing=true; stopRequested=false; app.busy=true; app.statusKey="Checking selected files…"
        let execution=app.beginExecution(total: paths.count, action: action, stage: "preparing")
        task=Task {
            defer { reviewing=false; app.busy=false; app.isExecuting=false; app.stopRequested=false; stopRequested=false }
            do {
                let plan=try await engine.createStorageRemovalPlan(scanId: scan.id, paths: paths, action: action, progress: { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.reviewing, !self.stopRequested else { return }
                        app.updateExecutionProgress(update, operation: execution)
                    }
                })
                guard !Task.isCancelled else { return }
                reviewing=false
                try await execute(app: app, engine: engine, plan: plan, sourceSection: sourceSection, execution: execution)
            } catch {
                app.operationHadError=app.isExecuting
                if !Task.isCancelled || app.isExecuting {
                    let details=(error as? ShouError)?.details ?? [:]
                    let failure=([error.localizedDescription] + [details["path"], details["reasons"]].compactMap { $0 }).joined(separator: "\n")
                    app.completion=CleanupCompletion(receipts: [], failures: [failure], sourceSection: sourceSection)
                    app.statusKey="Some items could not be removed. Review the result."
                }
            }
        }
    }
    private func execute(app: AppModel, engine: ShouEngine, plan: StorageRemovalPlan, sourceSection: String, execution: UUID) async throws {
        let receipt=try await engine.executeStorageRemoval(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "desktop", progress: { update in
            Task { @MainActor in app.updateExecutionProgress(update, operation: execution) }
        })
        let removed=receipt.items.filter { ["trashed", "purged"].contains($0.state) }.map(\.relativePath)
        app.operationHadError=receipt.items.contains { ["failed", "unknown", "moving", "purging"].contains($0.state) }
        if var current=scan {
            let removedNow=removed.compactMap { index.nodes[$0] }
            var nodes=index.nodes
            for key in Array(nodes.keys) {
                if removed.contains(where: { key == $0 || key.hasPrefix($0 + "/") }) { nodes.removeValue(forKey: key); entries.removeValue(forKey: key); continue }
                guard var node=nodes[key] else { continue }
                for item in removedNow where key == "." || item.path.hasPrefix(key + "/") {
                    node.logicalBytes=max(0, node.logicalBytes - item.logicalBytes)
                    node.allocatedBytes=max(0, node.allocatedBytes - item.allocatedBytes)
                    node.fileCount=max(0, node.fileCount - item.fileCount)
                    node.isComplete=false
                }
                nodes[key]=node
            }
            removedNodes.append(contentsOf: removedNow)
            current.tree.complete=false; scan=current; index=StorageIndex(nodes: Array(nodes.values))
            while path != "." && index.nodes[path] == nil { path=StorageIndex.parent(path) }
        }
        selected=[]; focus=nil
        let removedPaths=Set(removed.map { StorageRemovalPolicy.canonical(StorageRemovalPolicy.absolute(root: plan.rootPath, relative: $0)) })
        app.space.discardRemovedCatalogs(removedPaths)
        app.largeFiles.storage.discardRemovedCatalogs(removedPaths)
        app.completion=CleanupCompletion(receipts: [receipt], sourceSection: sourceSection)
        app.statusKey=receipt.state == "completed" ? "Selected items processed. Refresh to measure current disk usage." : "Some items could not be removed. Review the result."
        await app.refresh()
    }
}
