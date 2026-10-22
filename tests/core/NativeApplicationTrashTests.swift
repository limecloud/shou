import Foundation
import ShouCore
import ShouPlatform
#if os(macOS)
import Darwin

private final class FixtureApplicationRecycler: ApplicationRecycling, @unchecked Sendable {
    enum Behavior: Sendable, Equatable { case cancel, move, corruptAfterMove }
    let trash: URL
    let behavior: Behavior
    private let lock=NSLock()
    private var calls=0
    init(trash: URL, behavior: Behavior) { self.trash=trash; self.behavior=behavior }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func recycle(_ url: URL, completion: @escaping @Sendable (Result<URL, any Error>) -> Void) {
        lock.lock(); calls += 1; lock.unlock()
        DispatchQueue.global().async { [self] in
            if behavior == .cancel { completion(.failure(NSError(domain:NSCocoaErrorDomain,code:NSUserCancelledError))); return }
            let destination=trash.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at:url,to:destination)
                if behavior == .corruptAfterMove { try Data("changed-after-recycle".utf8).write(to:destination.appendingPathComponent("Contents/MacOS/Fixture")) }
                completion(.success(destination))
            } catch { completion(.failure(error)) }
        }
    }
    func isTrashLocation(_ path: String) -> Bool {
        URL(fileURLWithPath:path).deletingLastPathComponent().path == trash.path
    }
}
private struct ApplicationTrashFixture: Sendable {
    let root: URL
    let applications: URL
    let app: URL
    let trash: URL
    let recycler: FixtureApplicationRecycler
    let filesystem: NativeFileSystem
    init(_ behavior: FixtureApplicationRecycler.Behavior) throws {
        let temporaryPath=FileManager.default.temporaryDirectory.path
        let temporary=URL(fileURLWithPath:temporaryPath.hasPrefix("/var/") ? "/private" + temporaryPath : temporaryPath)
        root=temporary.appendingPathComponent("shou-application-recycle-" + UUID().uuidString)
        applications=root.appendingPathComponent("Applications")
        app=applications.appendingPathComponent("Fixture.app")
        trash=root.appendingPathComponent("fixture-trash")
        try FileManager.default.createDirectory(at:app.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:trash,withIntermediateDirectories:true)
        try Data("isolated-application-payload".utf8).write(to:app.appendingPathComponent("Contents/MacOS/Fixture"))
        recycler=FixtureApplicationRecycler(trash:trash,behavior:behavior)
        filesystem=NativeFileSystem(applicationRoots:[applications.path],applicationRecycler:recycler)
    }
    func manifest() throws -> [FileEntry] {
        let tree=try filesystem.inspectTarget(app.path,budget:ScanBudget(maxEntries:100,maxSeconds:5),cancelled:{ false })
        try expect(tree.complete); return tree.entries
    }
    func cleanup() { try? FileManager.default.removeItem(at:root) }
}
#endif

func nativeApplicationTrashUsesRecyclerAndVerifiesFixtureOutcomes() async throws {
    #if os(macOS)
    let cancelled=try ApplicationTrashFixture(.cancel); defer { cancelled.cleanup() }
    let original=try cancelled.manifest()
    do {
        _ = try await Task.detached { try cancelled.filesystem.moveApplicationToTrash(cancelled.app.path,expected:original) }.value
        throw CheckFailure(description:"Cancelled native recycling must fail without moving its source")
    } catch {
        let native=error as NSError
        try expect(native.domain == NSCocoaErrorDomain && native.code == NSUserCancelledError)
    }
    try expect(cancelled.recycler.count == 1 && FileManager.default.fileExists(atPath:cancelled.app.path))
    try expect(try cancelled.manifest() == original)

    let moved=try ApplicationTrashFixture(.move); defer { moved.cleanup() }
    let expected=try moved.manifest()
    let filesystem: any PlatformFileSystem=moved.filesystem
    try expect(filesystem.supportsAuthorizedApplicationTrash)
    let result=try await Task.detached { try filesystem.moveApplicationToTrash(moved.app.path,expected:expected) }.value
    try expect(result.verified && moved.recycler.count == 1 && !FileManager.default.fileExists(atPath:moved.app.path))
    try expect(result.path == moved.trash.appendingPathComponent("Fixture.app").path)
    try expect(result.manifest.first { $0.path == "." }?.sameObject(as:expected.first { $0.path == "." }!) == true)
    try expect(try Data(contentsOf:URL(fileURLWithPath:result.path).appendingPathComponent("Contents/MacOS/Fixture")) == Data("isolated-application-payload".utf8))

    let changed=try ApplicationTrashFixture(.corruptAfterMove); defer { changed.cleanup() }
    let changedExpected=try changed.manifest()
    let unverified=try await Task.detached { try changed.filesystem.moveApplicationToTrash(changed.app.path,expected:changedExpected) }.value
    try expect(!unverified.verified && changed.recycler.count == 1)
    #endif
}

func nativeApplicationTrashRejectsLinksStaleAndForeignOwnerManifests() async throws {
    #if os(macOS)
    let fixture=try ApplicationTrashFixture(.move); defer { fixture.cleanup() }
    let expected=try fixture.manifest()
    let linked=fixture.applications.appendingPathComponent("Linked.app")
    try FileManager.default.createSymbolicLink(at:linked,withDestinationURL:fixture.app)
    try await expectThrows { try await Task.detached { try fixture.filesystem.moveApplicationToTrash(linked.path,expected:expected) }.value }
    var foreign=expected
    foreign[0].owner=UInt32(getuid()) + 10_000
    let foreignManifest=foreign
    try await expectThrows { try await Task.detached { try fixture.filesystem.moveApplicationToTrash(fixture.app.path,expected:foreignManifest) }.value }
    let outside=NativeFileSystem(applicationRoots:["/Applications"],applicationRecycler:fixture.recycler)
    try await expectThrows { try await Task.detached { try outside.moveApplicationToTrash(fixture.app.path,expected:expected) }.value }
    do {
        _ = try await MainActor.run { try fixture.filesystem.moveApplicationToTrash(fixture.app.path,expected:expected) }
        throw CheckFailure(description:"A synchronous native recycle bridge must refuse the main thread")
    } catch let error as ShouError { try expect(error.code == "capability_unavailable") }
    try Data("stale-application-payload".utf8).write(to:fixture.app.appendingPathComponent("Contents/MacOS/Fixture"))
    try await expectThrows { try await Task.detached { try fixture.filesystem.moveApplicationToTrash(fixture.app.path,expected:expected) }.value }
    try expect(fixture.recycler.count == 0 && FileManager.default.fileExists(atPath:fixture.app.path))
    #endif
}
