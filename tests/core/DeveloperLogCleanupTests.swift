import Foundation
import ShouCore
import ShouPlatform
#if os(macOS)
import Darwin
#endif

private final class DeveloperLogClock: @unchecked Sendable { var date=Date() }

func developerLogsRequireExactSingleUseReviewsAndPreserveOpenFileIdentity() async throws {
    #if os(macOS)
    let fixture=try Fixture(), path=fixture.workspace.appendingPathComponent("generated.log")
    let text=String(repeating:"generated-private-log-never-journaled\n",count:16_384)
    try fixture.put("generated.log",text)
    let native=NativeDeveloperLogCleanup(toolID:"mailpit",target:.init(path:path.path,title:"Service Log"))
    let clock=DeveloperLogClock()
    let service=DeveloperLogCleanup(platform:native,makeStore:{ fixture.store },now:{ clock.date })
    let before=try native.inspect(), openFile=try FileHandle(forUpdating:path)
    defer { try? openFile.close() }
    let plan=try await service.prepare()
    let result=try await service.execute(plan,confirmedID:plan.id)
    try expect(result.state == "succeeded")
    let after=try native.inspect()
    try expect(after.file.sameObject(as:before.file) && after.file.logicalBytes == 0 && after.file.allocatedBytes <= before.file.allocatedBytes)
    try expect(try openFile.seekToEnd() == 0)
    try openFile.write(contentsOf:Data("generated new entry\n".utf8))
    try expect(try String(contentsOf:path,encoding:.utf8) == "generated new entry\n")
    try await expectThrows { try await service.execute(plan,confirmedID:plan.id) }
    for collection in ["developer-log-cleanup-intents","developer-log-cleanup-results"] {
        let bytes=try require(fixture.store.read(collection,id:plan.id))
        try expect(!String(decoding:bytes,as:UTF8.self).contains("generated-private-log-never-journaled"))
    }
    let changed=try await service.prepare()
    try openFile.write(contentsOf:Data("appended after review\n".utf8))
    try await expectThrows { try await service.execute(changed,confirmedID:changed.id) }
    try expect(try String(contentsOf:path,encoding:.utf8).contains("appended after review"))
    let expired=try await service.prepare(); clock.date.addTimeInterval(121)
    try await expectThrows { try await service.execute(expired,confirmedID:expired.id) }
    clock.date=Date()
    let wrong=try await service.prepare()
    try await expectThrows { try await service.execute(wrong,confirmedID:"wrong") }
    let denied=DeveloperLogCleanup(platform:native,makeStore:{ JournalWriteStore(fixture.store,failingCollection:"developer-log-cleanup-intents",failingWrite:1) })
    let deniedPlan=try await denied.prepare(), retained=try Data(contentsOf:path)
    try await expectThrows { try await denied.execute(deniedPlan,confirmedID:deniedPlan.id) }
    try expect(try Data(contentsOf:path) == retained)
    let replaced=try await service.prepare()
    try FileManager.default.moveItem(at:path,to:path.appendingPathExtension("old"))
    try fixture.put("generated.log","replacement must survive\n")
    try await expectThrows { try await service.execute(replaced,confirmedID:replaced.id) }
    try expect(try String(contentsOf:path,encoding:.utf8) == "replacement must survive\n")
    for kind in ["symbolic","hard"] {
        let link=fixture.workspace.appendingPathComponent(kind + ".log")
        if kind == "symbolic" { try FileManager.default.createSymbolicLink(at:link,withDestinationURL:path) }
        else { try FileManager.default.linkItem(at:path,to:link) }
        let unsafe=NativeDeveloperLogCleanup(toolID:"mailpit",target:.init(path:link.path,title:"Service Log"))
        try expectThrows { try unsafe.inspect() }
    }
    try fixture.put("readonly.log","read only\n")
    let readonly=fixture.workspace.appendingPathComponent("readonly.log")
    try FileManager.default.setAttributes([.posixPermissions:0o666],ofItemAtPath:readonly.path)
    let unsafe=DeveloperLogCleanup(platform:NativeDeveloperLogCleanup(toolID:"mailpit",target:.init(path:readonly.path,title:"Service Log")),makeStore:{ fixture.store })
    try await expectThrows { try await unsafe.prepare() }
    try fixture.put(".ssh/credential.log","generated protected fixture\n")
    let credential=NativeDeveloperLogCleanup(toolID:"nginx",target:.init(path:fixture.workspace.appendingPathComponent(".ssh/credential.log").path,title:"Service Log"),homeDirectory:fixture.workspace)
    try expectThrows { try credential.inspect() }
    let recordRoot=try require(fixture.store.protectedPaths.first)
    try expect(recordRoot.hasPrefix(fixture.base.path))
    let protected=URL(fileURLWithPath:recordRoot).appendingPathComponent("protected.log")
    try Data("generated protected record\n".utf8).write(to:protected)
    let record=DeveloperLogCleanup(platform:NativeDeveloperLogCleanup(toolID:"nginx",target:.init(path:protected.path,title:"Service Log")),makeStore:{ fixture.store })
    try await expectThrows { try await record.prepare() }
    #endif
}

func developerPackageUninstallRejectsRunningGeneratedImagesAndAmbiguousPaths() async throws {
    #if os(macOS)
    let fixture=try Fixture(), catalog=try DeveloperToolCatalog.bundled()
    let package=DeveloperToolPackage(provider:"homebrew",kind:"formula",token:"nginx")
    let row=DeveloperToolInstallation(toolID:"nginx",source:"Homebrew",version:"1.0",path:"/opt/homebrew/Cellar/nginx/1.0",evidence:"generated",status:"registered")
    try expect(NativeDeveloperTools.package(for:row,catalog:catalog) == package)
    for (source,path) in [("Executable path",row.path),("Homebrew","/somewhere/Cellar/nginx/1.0"),("Homebrew",row.path + "/bin/nginx")] {
        let invalid=DeveloperToolInstallation(toolID:"nginx",source:source,version:"1.0",path:path,evidence:"generated",status:"detected")
        try expect(NativeDeveloperTools.package(for:invalid,catalog:catalog) == nil)
    }
    let image=fixture.workspace.appendingPathComponent("Cellar/nginx/1.0/bin/nginx")
    try FileManager.default.createDirectory(at:image.deletingLastPathComponent(),withIntermediateDirectories:true)
    try FileManager.default.copyItem(at:URL(fileURLWithPath:"/bin/sleep"),to:image)
    let child=Process(); child.executableURL=image; child.arguments=["30"]
    try child.run()
    defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
    let deadline=ContinuousClock.now.advanced(by:.seconds(3))
    var observed=false
    while ContinuousClock.now < deadline {
        var bytes=[UInt8](repeating:0,count:4096)
        let count=proc_pidpath(child.processIdentifier,&bytes,4096)
        let path=count > 0 ? String(decoding:bytes.prefix(Int(count)).prefix(while:{ $0 != 0 }),as:UTF8.self) : ""
        if !path.isEmpty, URL(fileURLWithPath:path).resolvingSymlinksInPath().path == image.resolvingSymlinksInPath().path { observed=true; break }
        try await Task.sleep(for:.milliseconds(20))
    }
    try expect(observed)
    let activity=NativeDeveloperPackageActivity(prefixes:[fixture.workspace.path])
    try expectThrows { try activity.requireInactive(package) }
    child.terminate(); child.waitUntilExit()
    try activity.requireInactive(package)
    #endif
}
