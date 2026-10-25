import Foundation
import Dispatch
import ShouCore
import ShouPlatform
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private final class WorkerProgressProbe: @unchecked Sendable {
    private let lock=NSLock()
    private var values: [String]=[]
    func record(_ progress: ScanProgress) {
        lock.lock(); defer { lock.unlock() }
        values.append(progress.currentPath)
    }
    func contains(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values.contains(path)
    }
}

func nativeReadWorkerMatchesDirectEvidenceWithoutOpeningStore() throws {
    let fixture=try Fixture()
    let executable=URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let worker=NativeFileSystem(readWorkerExecutable: executable)
    let direct=try fixture.fs.inspect(fixture.workspace.path, budget: ScanBudget(), cancelled: { false })
    let progress=WorkerProgressProbe()
    let isolated=try worker.inspect(fixture.workspace.path, budget: ScanBudget(), cancelled: { false }, progress: { progress.record($0) })
    try expect(isolated.entries == direct.entries && isolated.complete == direct.complete)
    try expect(isolated.completedPaths == direct.completedPaths && isolated.issues == direct.issues)
    try expect(progress.contains(fixture.workspace.path))
    try expect(try worker.rootIdentity(fixture.workspace.path) == fixture.fs.rootIdentity(fixture.workspace.path))

    let rule=try CleanupRule.parse(fixtureRule())
    let directCleanup=try fixture.fs.inspectCleanup(fixture.workspace.path, rules: [rule], budget: ScanBudget(), cancelled: { false }, progress: { _ in })
    let isolatedCleanup=try worker.inspectCleanup(fixture.workspace.path, rules: [rule], budget: ScanBudget(), cancelled: { false }, progress: { _ in })
    try expect(isolatedCleanup.entries == directCleanup.entries && isolatedCleanup.completedPaths == directCleanup.completedPaths)
    try expect(isolatedCleanup.discoveryComplete == directCleanup.discoveryComplete)
    try expect(try fixture.store.ids("configuration").isEmpty)
    try expect(try fixture.store.ids("scans").isEmpty)
}

private final class BatchReadProbe: @unchecked Sendable {
    private let lock=NSLock()
    private var active=0
    private var peak=0
    var maxActive: Int { lock.lock(); defer { lock.unlock() }; return peak }
    func read<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); active += 1; peak=max(peak, active); lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        return try body()
    }
}

/// Delegates every read to a real isolated worker and observes concurrent calls.
private struct BatchWorkerFileSystem: PlatformFileSystem {
    let native: NativeFileSystem
    let probe: BatchReadProbe
    var platform: String { native.platform }
    var supportsTrash: Bool { false }
    var maximumConcurrentReadOperations: Int { native.maximumConcurrentReadOperations }
    func locationAvailability(_ path: String) -> LocationAvailability { native.locationAvailability(path) }
    func rootIdentity(_ path: String) throws -> FileEntry { try probe.read { try native.rootIdentity(path) } }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        try probe.read { try native.inspect(path, budget: budget, cancelled: cancelled) }
    }
    func inspectCleanup(_ path: String, rules: [CleanupRule], budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        try probe.read { try native.inspectCleanup(path, rules: rules, budget: budget, cancelled: cancelled, progress: progress) }
    }
    func availableBytes(_ path: String) -> Int64? { native.availableBytes(path) }
    func isTrashLocation(_ path: String) -> Bool { false }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult { throw ShouError("capability_unavailable", "Read-only worker fixture.") }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws { throw ShouError("capability_unavailable", "Read-only worker fixture.") }
    func purge(_ path: String, expected: [FileEntry]) throws { throw ShouError("capability_unavailable", "Read-only worker fixture.") }
}

private struct WorkerBatchApplicationCatalog: ApplicationCatalogReading {
    func read(options: ApplicationCatalogOptions) throws -> ApplicationCatalog { .init(checkedAt: Date(), sources: [], items: [], issues: []) }
    func application(at path: String) throws -> ApplicationDefinition { throw ShouError("not_found", "Generated worker fixture has no applications.") }
}

func workerBackedSystemScanBoundsConcurrentReadsWithoutLosingRoots() async throws {
    let fixture=try Fixture(), probe=BatchReadProbe()
    let paths=["Library/Caches/pip", ".cache/pip", ".npm/_cacache", ".yarn/berry/cache", ".cargo/registry/cache",
               "Library/Application Support/Slack/Cache", "Library/Application Support/Code/CachedData", "Library/Application Support/Google/Chrome/Default/Cache"]
    for path in paths { for index in 0..<8 { try fixture.put(path + "/shard-\(index)/payload.bin") } }
    try fixture.put("Documents/dev/example/Cargo.toml", "[package]")
    try fixture.put("Documents/dev/example/target/artifact.bin")
    let executable=URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let native=NativeFileSystem(readWorkerExecutable: executable)
    let filesystem=BatchWorkerFileSystem(native: native, probe: probe)
    try expect((filesystem as any PlatformFileSystem).maximumConcurrentReadOperations == 2)
    try expect((NativeFileSystem() as any PlatformFileSystem).maximumConcurrentReadOperations == 4)
    let engine=ShouEngine(store: fixture.store, filesystem: filesystem, artifactEvidence: ArtifactFixtureEvidence(),
        applicationCatalog: WorkerBatchApplicationCatalog(), homeDirectory: fixture.workspace)
    let result=try await engine.scanKnownLocations(includeProjects: true, maxConcurrentLocations: 4)
    let existing=result.locations.filter(\.exists)
    if result.status != "complete" || result.snapshots.count != existing.count {
        print("Worker batch: existing=\(existing.count), snapshots=\(result.snapshots.count), issues=\(result.issues.map { $0.locationId + ":" + $0.code + ":" + $0.message })")
    }
    try expect(existing.count > 4 && result.snapshots.count == existing.count)
    try expect(result.status == "complete" && result.issues.isEmpty)
    try expect(Set(result.snapshots.map(\.workspace.path)) == Set(existing.map(\.path)))
    try expect(result.snapshots.contains { $0.workspace.path == fixture.workspace.path + "/Library/Caches" })
    try expect(result.snapshots.contains { $0.workspace.path == fixture.workspace.path + "/Documents/dev" })
    try expect(probe.maxActive <= 2)
    if ProcessInfo.processInfo.activeProcessorCount > 1 { try expect(probe.maxActive == 2) }
    try expect(result.snapshots.flatMap(\.candidates).contains { $0.relativePath == "example/target" && $0.eligible })
    try expect(try await engine.history().isEmpty)
    print("Isolated worker batch: \(existing.count) roots, \(result.snapshots.count) complete snapshots, peak \(probe.maxActive) reads; generated fixtures only.")
}

func isolatedCleanupDiscoveryKeepsLaterProjectsWithinSharedBudget() async throws {
    let fixture=try Fixture()
    let expected=try addFairCleanupFixture(fixture)
    let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs, homeDirectory: fixture.workspace)
    let workspace=try await engine.addWorkspace(path: fixture.workspace.path, rootRef: "test-workspace")
    let rules=try BuiltinCatalog.rules(for: workspace, homeDirectory: fixture.workspace, platform: "macos")
    let budget=ScanBudget(maxEntries: 256)
    let direct=try fixture.fs.inspectCleanup(fixture.workspace.path, rules: rules, budget: budget, cancelled: { false }, progress: { _ in })
    let worker=NativeFileSystem(readWorkerExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
    let isolated=try worker.inspectCleanup(fixture.workspace.path, rules: rules, budget: budget, cancelled: { false }, progress: { _ in })
    try expect(direct.entries == isolated.entries && direct.completedPaths == isolated.completedPaths)
    try expect(direct.issues == isolated.issues && isolated.issues.contains("resource_limit"))
    try expect(isolated.entries.count <= budget.maxEntries && isolated.discoveryComplete == false)
    for path in expected { try expect(isolated.isComplete(at: path)) }
    try expect(!isolated.isComplete(at: "ai/aiclientproxy/node_modules"))
}

func nativeReadWorkerAcceptsSnakeCaseWireRequest() throws {
    let fixture=try Fixture()
    let channel=fixture.base.appendingPathComponent("wire-request")
    try FileManager.default.createDirectory(at: channel, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let id=UUID().uuidString
    let request: [String: Any] = [
        "version": 1, "id": id, "parent_pid": getpid(), "operation": "inspect",
        "path": fixture.workspace.path,
        "budget": ["max_entries": 100, "max_seconds": 5, "max_depth": 10]
    ]
    let requestPath=channel.appendingPathComponent("request.json")
    try JSONSerialization.data(withJSONObject: request).write(to: requestPath)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestPath.path)
    let process=Process()
    process.executableURL=URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.arguments=["--internal-read-worker", channel.path]
    try process.run()
    defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    let deadline=ProcessInfo.processInfo.systemUptime + 8
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
    try expect(!process.isRunning)
    try expect(process.terminationReason == .exit && process.terminationStatus == 0)
    let response=try JSONSerialization.jsonObject(with: Data(contentsOf: channel.appendingPathComponent("result.json"))) as? [String: Any]
    try expect(response?["id"] as? String == id)
    let snapshot=try require(response?["snapshot"] as? [String: Any])
    try expect(snapshot["complete"] as? Bool == true)
    try expect((snapshot["entries"] as? [[String: Any]])?.count == 5)
}

private func fixtureWorkerScript(_ fixture: Fixture, body: String) throws -> URL {
    let executable=fixture.base.appendingPathComponent("worker-" + UUID().uuidString + ".sh")
    try Data(("#!/bin/sh\n" + body).utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}

private func shellLiteral(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

private func expectFixtureWorkerExited(_ marker: URL) throws {
    let pid=try require(Int32(String(contentsOf: marker, encoding: .utf8)))
    let deadline=ProcessInfo.processInfo.systemUptime + 2
    while kill(pid, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
    try expect(kill(pid, 0) != 0 && errno == ESRCH)
}

private final class WorkerCancellationProbe: @unchecked Sendable {
    private let marker: URL
    private let lock=NSLock()
    private var timestamp: TimeInterval?
    init(marker: URL) { self.marker=marker }
    func requested() -> Bool {
        // File creation precedes printf's PID write. Request cancellation only
        // once the owned child has published a complete, usable handshake.
        guard let text=try? String(contentsOf: marker, encoding: .utf8), let pid=Int32(text), pid > 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        if timestamp == nil { timestamp=ProcessInfo.processInfo.systemUptime }
        return true
    }
    var requestedAt: TimeInterval? { lock.lock(); defer { lock.unlock() }; return timestamp }
}

func nativeReadWorkerCancellationStopsOwnedChild() throws {
    let fixture=try Fixture()
    let marker=fixture.base.appendingPathComponent("cancelled-worker.pid")
    let executable=try fixtureWorkerScript(fixture, body: "printf '%s' \"$$\" > " + shellLiteral(marker.path) + "\nexec /bin/sleep 60\n")
    let worker=NativeFileSystem(readWorkerExecutable: executable)
    let cancellation=WorkerCancellationProbe(marker: marker)
    do {
        _ = try worker.inspect(fixture.workspace.path, budget: ScanBudget(), cancelled: { cancellation.requested() })
        throw CheckFailure(description: "A cancelled worker must not return scan evidence.")
    } catch let failure as ShouError { try expect(failure.code == "cancelled") }
    // Measure Stop responsiveness after cancellation is requested, independently
    // of filesystem setup and process startup under host load.
    try expect(ProcessInfo.processInfo.systemUptime - (try require(cancellation.requestedAt)) < 3)
    try expectFixtureWorkerExited(marker)
    try expect(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("project/target/artifact.bin").path))
}

func nativeReadWorkerTimeoutStopsOwnedChildWithoutEvidence() throws {
    let fixture=try Fixture()
    let marker=fixture.base.appendingPathComponent("timed-out-worker.pid")
    let executable=try fixtureWorkerScript(fixture, body: "printf '%s' \"$$\" > " + shellLiteral(marker.path) + "\nexec /bin/sleep 60\n")
    let worker=NativeFileSystem(readWorkerExecutable: executable)
    let started=ProcessInfo.processInfo.systemUptime
    do {
        _ = try worker.inspect(fixture.workspace.path, budget: ScanBudget(maxSeconds: 1), cancelled: { false })
        throw CheckFailure(description: "An unresponsive worker must not return scan evidence.")
    } catch let failure as ShouError { try expect(failure.code == "resource_limit") }
    try expect(ProcessInfo.processInfo.systemUptime - started < 5)
    try expectFixtureWorkerExited(marker)
}

func uninstallContainerWorkersCancelAndTimeoutWithoutBlockingReview() async throws {
    #if os(macOS)
    let fixture=try Fixture()
    let marker=fixture.base.appendingPathComponent("container-worker.pid")
    let executable=try fixtureWorkerScript(fixture, body: "printf '%s' \"$$\" > " + shellLiteral(marker.path) + "\nexec /bin/sleep 60\n")
    let evidence=NativeApplicationUninstallEvidence(homeDirectory: fixture.workspace, readWorkerExecutable: executable)
    let work=Task.detached { try evidence.groupContainerPaths(for: "dev.shou.fixture.uninstall") }
    defer { work.cancel() }
    let deadline=ProcessInfo.processInfo.systemUptime + 8
    while (try? String(contentsOf: marker, encoding: .utf8)).flatMap(Int32.init) == nil,
          ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try expect(FileManager.default.fileExists(atPath: marker.path))
    let stopped=ProcessInfo.processInfo.systemUptime
    work.cancel()
    do { _ = try await work.value; throw CheckFailure(description: "Cancelled container discovery must return no ownership evidence.") }
    catch let failure as ShouError { try expect(failure.code == "cancelled") }
    try expect(ProcessInfo.processInfo.systemUptime - stopped < 3)
    try expectFixtureWorkerExited(marker)

    let started=ProcessInfo.processInfo.systemUptime
    do { _ = try evidence.containerIdentifier(at: fixture.workspace.path); throw CheckFailure(description: "Unresponsive container metadata must time out.") }
    catch let failure as ShouError { try expect(failure.code == "resource_limit") }
    try expect(ProcessInfo.processInfo.systemUptime - started < 6)
    try expectFixtureWorkerExited(marker)
    try expect(try fixture.store.ids("application-reviews").isEmpty)
    #endif
}

func nativeReadWorkerRejectsFailureMalformedAndForeignResponses() throws {
    let fixture=try Fixture()
    for body in [
        "exit 7\n",
        "printf '%s' 'invalid json' > \"$2/result.json\"\n",
        "printf '%s' '{\"version\":1,\"id\":\"another-request\"}' > \"$2/result.json\"\n",
        "dd if=/dev/zero of=\"$2/result.json\" bs=1 count=0 seek=1073741824 2>/dev/null\n",
        "ln -s /dev/zero \"$2/result.json\"\n"
    ] {
        let executable=try fixtureWorkerScript(fixture, body: body)
        let worker=NativeFileSystem(readWorkerExecutable: executable)
        try expectThrows { try worker.inspect(fixture.workspace.path, budget: ScanBudget(), cancelled: { false }) }
        try expectThrows { try worker.rootIdentity(fixture.workspace.path) }
    }
    let missing=NativeFileSystem(readWorkerExecutable: fixture.base.appendingPathComponent("missing-worker"))
    try expectThrows { try missing.inspect(fixture.workspace.path, budget: ScanBudget(), cancelled: { false }) }
    try expect(try fixture.store.ids("scans").isEmpty)
}

private final class WorkerBoundaryState: @unchecked Sendable {
    private let lock=NSLock()
    private var stopping=false
    private var outcomes: [String]=[]
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopping }
    func stop() { lock.lock(); defer { lock.unlock() }; stopping=true }
    func record(_ outcome: String) { lock.lock(); defer { lock.unlock() }; outcomes.append(outcome) }
    var results: [String] { lock.lock(); defer { lock.unlock() }; return outcomes }
}

func nativeReadWorkerCapsConcurrentChildrenAndRecoversCapacity() throws {
    let fixture=try Fixture()
    let markers=fixture.base.appendingPathComponent("children", isDirectory: true)
    try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: false)
    let body="printf '%s' \"$$\" > " + shellLiteral(markers.path) + "/\"$$\".pid\nexec /bin/sleep 60\n"
    let worker=NativeFileSystem(readWorkerExecutable: try fixtureWorkerScript(fixture, body: body))
    let state=WorkerBoundaryState(), group=DispatchGroup()
    for _ in 0..<2 {
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                _ = try worker.inspect(fixture.workspace.path, budget: ScanBudget(maxSeconds: 30), cancelled: { state.cancelled })
                state.record("unexpected-evidence")
            } catch let failure as ShouError { state.record(failure.code) }
            catch { state.record("unexpected-error") }
        }
    }
    defer { state.stop(); _ = group.wait(timeout: .now() + 5) }
    let deadline=ProcessInfo.processInfo.systemUptime + 8
    while try FileManager.default.contentsOfDirectory(atPath: markers.path).count < 2,
          ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
    let children=try FileManager.default.contentsOfDirectory(at: markers, includingPropertiesForKeys: nil)
    try expect(children.count == 2)
    do {
        _ = try worker.inspect(fixture.workspace.path, budget: ScanBudget(), cancelled: { false })
        throw CheckFailure(description: "A third live read child must not be started.")
    } catch let failure as ShouError { try expect(failure.code == "resource_limit") }
    state.stop()
    try expect(group.wait(timeout: .now() + 5) == .success)
    try expect(state.results.count == 2 && state.results.allSatisfy { $0 == "cancelled" })
    for child in children { try expectFixtureWorkerExited(child) }
    let recovered=NativeFileSystem(readWorkerExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
    try expect(try recovered.rootIdentity(fixture.workspace.path) == fixture.fs.rootIdentity(fixture.workspace.path))
}
