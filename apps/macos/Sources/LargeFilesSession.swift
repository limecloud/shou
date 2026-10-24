import Foundation
import Observation
import ShouCore

@MainActor @Observable final class LargeFilesSession {
    let storage=StorageSession()
    var minimumBytes: Int64=50 * 1024 * 1024
    var type=StorageFileType.all
    var items=[StorageCatalogItem]()
    var totalCount=0
    var totalBytes: Int64=0
    var nextCursor: String?
    var loading=false
    var selectingAll=false
    var hasLoaded=false
    private var task: Task<Void, Never>?
    private var operation=UUID()
    private struct Query: Equatable {
        let scanId: String
        let minimumBytes: Int64
        let type: StorageFileType
    }
    private var loadedQuery: Query?

    var visibleItems: [StorageCatalogItem] { items.filter { storage.index.nodes[$0.node.path] != nil } }
    var selectedItems: [StorageCatalogItem] { visibleItems.filter { storage.isSelected($0.node.path) } }

    func loadIfNeeded(app: AppModel) {
        guard let scan=storage.scan, !storage.scanning, !loading, !app.busy else { return }
        let query=Query(scanId: scan.id, minimumBytes: minimumBytes, type: type)
        if !hasLoaded || loadedQuery != query { load(app: app) }
    }
    func load(app: AppModel, more: Bool = false) {
        guard let engine=app.engine, let scan=storage.scan, !app.busy else { return }
        task?.cancel()
        let token=UUID(); operation=token
        let cursor=more ? nextCursor : nil, minimum=minimumBytes, filter=type
        if !more { items=[]; totalCount=0; totalBytes=0; nextCursor=nil; storage.selected=[]; hasLoaded=false; loadedQuery=nil }
        loading=true
        task=Task {
            defer { if operation == token { loading=false } }
            do {
                let page=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: minimum, type: filter, cursor: cursor)
                try Task.checkCancellation()
                guard operation == token, storage.scan?.id == scan.id else { return }
                storage.includeItems(page.items)
                items += page.items
                totalCount=page.totalCount; totalBytes=page.totalAllocatedBytes; nextCursor=page.nextCursor
                loadedQuery=Query(scanId: scan.id, minimumBytes: minimum, type: filter); hasLoaded=true
            } catch { if !Task.isCancelled { app.error=error.localizedDescription } }
        }
    }
    func useSpaceAnalysis(app: AppModel) {
        guard let scan=app.space.scan, !app.busy, !loading else { return }
        task?.cancel(); loading=true
        task=Task {
            do { try await storage.useExistingScan(scan, app: app); loading=false; load(app: app) }
            catch { loading=false; if !Task.isCancelled { app.error=error.localizedDescription } }
        }
    }
    func selectLoaded(app: AppModel) {
        guard hasLoaded, !app.busy, !loading else { return }
        let eligible=visibleItems.filter { storage.reason($0.node) == nil }
        let all=eligible.allSatisfy { storage.isSelected($0.node.path) }
        let paths=Set(eligible.map { $0.node.path })
        if all { storage.selected.subtract(paths) }
        else { storage.selected.formUnion(paths) }
    }
    func selectAll(app: AppModel) {
        guard hasLoaded, let engine=app.engine, let scan=storage.scan, !app.busy, !loading else { return }
        task?.cancel(); loading=true; selectingAll=true; app.busy=true
        let minimum=minimumBytes, filter=type
        task=Task {
            defer { loading=false; selectingAll=false; app.busy=false }
            do {
                var cursor: String?
                var selected=Set<String>()
                repeat {
                    let page=try await engine.storageLargeFiles(scanId: scan.id, minimumBytes: minimum, type: filter, limit: 500, cursor: cursor)
                    try Task.checkCancellation()
                    storage.includeItems(page.items)
                    for item in page.items where storage.index.nodes[item.node.path] != nil && storage.reason(item.node) == nil {
                        selected.insert(item.node.path)
                    }
                    cursor=page.nextCursor
                } while cursor != nil
                storage.selected=selected
            } catch { if !Task.isCancelled { app.error=error.localizedDescription } }
        }
    }
    func stop() { task?.cancel(); storage.stop() }
    func waitForOperation() async { await task?.value; await storage.waitForOperation() }
}
