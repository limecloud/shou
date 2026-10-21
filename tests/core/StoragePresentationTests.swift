import Foundation
import ShouCore
import ShouPlatform

func storagePresentationReusesSnapshotAndPreservesAccounting() async throws {
    for catalog in [true, false] {
        let fixture=try Fixture()
        try fixture.put("scope/cache/a.JS", String(repeating: "x", count: 9000))
        try fixture.put("scope/cache/b.js", "generated")
        try FileManager.default.linkItem(at:fixture.workspace.appendingPathComponent("scope/cache/a.JS"), to:fixture.workspace.appendingPathComponent("scope/cache/linked.js"))
        try fixture.put("scope/.env", "fixture")
        try fixture.put("scope2/elsewhere.js", String(repeating: "y", count: 20000))
        let native=NativeFileSystem(), engine=ShouEngine(store:fixture.store, filesystem:native)
        let scan=try await engine.scanStorage(path:fixture.workspace.path, budget: catalog ? nil : ScanBudget())
        let presentation=try await engine.storagePresentation(scanId:scan.id,path:"scope")
        try expect(presentation.scanId == scan.id && presentation.scope.node.path == "scope")
        try expect(presentation.items.allSatisfy { $0.node.path.hasPrefix("scope/") })
        let js=try require(presentation.extensions.items.first { $0.suffix == "js" })
        try expect(js.fileCount == 3)
        try expect(presentation.extensions.items.first { $0.suffix.isEmpty }?.fileCount == 1)
        let expected=try await engine.storageDirectory(scanId:scan.id,path:"scope/cache")
        try expect(js.allocatedBytes == expected.children.reduce(0) { $0 + $1.node.allocatedBytes })
        // Subsequent reads must return old evidence even if a new file appears.
        try fixture.put("scope/new.json", "new fixture after scan")
        let reused=try await engine.storagePresentation(scanId:scan.id,path:"scope")
        try expect(!reused.items.contains { $0.node.path == "scope/new.json" })
        let page=try await engine.storageDirectoryPage(scanId:scan.id,path:"scope/cache",limit:1)
        let next=try await engine.storageDirectoryPage(scanId:scan.id,path:"scope/cache",offset:try require(page.nextOffset),limit:1)
        try expect(page.children.count == 1 && next.children.count == 1 && next.nextOffset == 2)
        try expect(page.children[0].node.path != next.children[0].node.path)
        let context=try await engine.storageAnalysisContext(scanId:scan.id,path:"scope",focusedPath:"scope/cache",selectedPaths:["scope/cache"],removedPaths:["scope/.env"],nameFilter:"cache",extensionFilter:"js",cliPath:"/tmp/Shou's app/shou")
        let text=try context.text(locale:"zh-CN")
        try expect(text.contains(scan.id) && text.contains("scope/cache") && text.contains("removed_paths") && text.contains("analysis children"))
        try expect(text.contains("Shou'\\''s app") && context.absolutePaths.contains(fixture.workspace.path + "/scope/cache"))
        try expect(context.selectedPaths == ["scope/cache"] && context.removedPaths == ["scope/.env"])
        let history=try await engine.history()
        try expect(history.isEmpty)
    }
}

func storageNestedMapIsBoundedAndPreservesParentArea() async throws {
    for catalog in [true, false] {
        let fixture=try Fixture(), engine=ShouEngine(store:fixture.store,filesystem:NativeFileSystem())
        for n in 0..<300 { try fixture.put("wide/child-\(n)/file.bin", "generated") }
        try fixture.put("deep/users/developer/projects/alpha/.build/arm64/debug/output/main.bin", String(repeating: "x", count: 100000))
        for n in 0..<700 { try fixture.put("file-heavy/item-\(n).\(n % 2 == 0 ? "bin" : "js")", "generated") }
        let scan=try await engine.scanStorage(path:fixture.workspace.path,budget:catalog ? nil : ScanBudget())
        let map=try await engine.storagePresentation(scanId:scan.id,path:"wide")
        try expect(map.items.count <= 8192 && map.omissions.first?.childCount == 300 && map.omissions.first?.displayedChildCount == 256)
        try expect(map.aggregates.first { $0.parentPath == "wide" && $0.suffix == "bin" }?.fileCount == 44)
        let nodes=map.items.map(\.node), scope=map.scope.node
        let first=SpaceMap.nested(nodes,scope:scope,width:1000,height:600), second=SpaceMap.nested(nodes,scope:scope,width:1000,height:600)
        try expect(first.map(\.id) == second.map(\.id))
        try expect(first.allSatisfy { $0.tile.x >= 0 && $0.tile.y >= 0 && $0.tile.x + $0.tile.width <= 1000.001 && $0.tile.y + $0.tile.height <= 600.001 })
        let area=first.filter { $0.depth == 0 }.reduce(0.0) { $0 + $1.tile.width * $1.tile.height }
        try expect(abs(area - 600000) < 0.01 && first.contains { $0.remainder })
        let deep=try await engine.storagePresentation(scanId:scan.id,path:"deep")
        let deepTiles=SpaceMap.nested(deep.items.map(\.node),scope:deep.scope.node,width:1000,height:600)
        try expect(deep.items.contains { $0.node.name == "main.bin" && $0.node.kind == "file" })
        try expect(deepTiles.contains { $0.id.hasSuffix("/main.bin") && $0.depth > 3 })
        try expect(deepTiles.allSatisfy { $0.tile.x >= 0 && $0.tile.y >= 0 && $0.tile.x + $0.tile.width <= 1000.001 && $0.tile.y + $0.tile.height <= 600.001 })
        let context=try await engine.storageAnalysisContext(scanId:scan.id,path:"wide")
        try expect(context.presentation.items.count <= 512)
        try expect(StorageMapPalette.hex(forExtension:"JS") == StorageMapPalette.hex(forExtension:"js"))
        try expect(Set(["", "js", "sqlite", "bin", "db", "png", "dmg", "ts"].map { StorageMapPalette.hex(forExtension:$0) }).count == 8)
        let dense=try await engine.storagePresentation(scanId:scan.id,path:"file-heavy")
        try expect(dense.items.count == 256 && dense.aggregates.count == 2)
        try expect(dense.aggregates.reduce(0) { $0 + $1.fileCount } + dense.items.reduce(0) { $0 + $1.node.fileCount } == 700)
        let denseDirectory=try await engine.storageDirectory(scanId:scan.id,path:"file-heavy")
        try expect(dense.aggregates.reduce(Int64(0)) { $0 + $1.allocatedBytes } + dense.items.reduce(Int64(0)) { $0 + $1.node.allocatedBytes } == denseDirectory.children.reduce(0) { $0 + $1.node.allocatedBytes })
        try expect(dense.aggregates.allSatisfy { !StorageRemovalPolicy.validRelative($0.id) && $0.parentPath == "file-heavy" })
        let denseTiles=SpaceMap.nested(dense.items.map(\.node),scope:dense.scope.node,width:1000,height:600,aggregates:dense.aggregates)
        try expect(denseTiles.filter { $0.aggregate != nil }.count == 2)
        try expect(dense.aggregates.count <= 2048)
        let task=Task { () throws -> StoragePresentation in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.storagePresentation(scanId:scan.id,path:"wide")
        }
        do { _ = try await task.value; throw CheckFailure(description:"Cancelled map query must stop") }
        catch let error as ShouError { try expect(error.code == "cancelled") }
    }
}

func storagePresentationReadsMillionRowCatalog() async throws {
    let fixture=try Fixture(), engine=ShouEngine(store:fixture.store,filesystem:NativeFileSystem())
    var scan=try await engine.scanStorage(path:fixture.workspace.path,budget:ScanBudget())
    let url=try require(fixture.store.storageCatalogURL(id:scan.id)), count=1_000_005
    let catalog=try StorageCatalog(url:url,create:true)
    let root=try catalog.append(scan.identity,complete:true)
    var total=root
    for number in 0..<count {
        var entry=scan.identity
        entry.path=String(format:"generated-%08d.cache",number); entry.kind="file"; entry.inode += UInt64(number+1)
        entry.links=1; entry.logicalBytes=4096; entry.allocatedBytes=4096
        _ = try catalog.append(entry)
        total.logicalBytes += 4096; total.allocatedBytes += 4096; total.fileCount += 1
    }
    total.isComplete=true
    try catalog.setTotals(total); try catalog.seal()
    scan.catalogId=scan.id; scan.measuredEntryCount=count+1; scan.tree.entries=[scan.identity]
    try fixture.store.write("storage-scans",id:scan.id,data:Codec.encode(scan))
    let start=Date()
    let map=try await engine.storagePresentation(scanId:scan.id)
    let mapSeconds=Date().timeIntervalSince(start)
    try expect(map.items.count == 256 && map.omissions[0].childCount == count)
    try expect(map.extensions.items.count == 1 && map.extensions.items[0].fileCount == count)
    try expect(map.extensions.items[0].allocatedBytes == Int64(count)*4096)
    try expect(map.aggregates.count == 1 && map.aggregates[0].fileCount == count - 256)
    let pageStart=Date()
    let last=try await engine.storageDirectoryPage(scanId:scan.id,offset:count-5,limit:200)
    try expect(last.children.count == 5 && last.nextOffset == nil)
    print("Million-row presentation query: \(mapSeconds)s; final directory page: \(Date().timeIntervalSince(pageStart))s; 256 returned map nodes.")
}
