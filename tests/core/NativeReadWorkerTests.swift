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

func nativeReadWorkerCancellationStopsOwnedChild() throws {
    let fixture=try Fixture()
    let marker=fixture.base.appendingPathComponent("cancelled-worker.pid")
    let executable=try fixtureWorkerScript(fixture, body: "printf '%s' \"$$\" > " + shellLiteral(marker.path) + "\nexec /bin/sleep 60\n")
    let worker=NativeFileSystem(readWorkerExecutable: executable)
    let started=ProcessInfo.processInfo.systemUptime
    do {
        _ = try worker.inspect(fixture.workspace.path, budget: ScanBudget(), cancelled: { FileManager.default.fileExists(atPath: marker.path) })
        throw CheckFailure(description: "A cancelled worker must not return scan evidence.")
    } catch let failure as ShouError { try expect(failure.code == "cancelled") }
    try expect(ProcessInfo.processInfo.systemUptime - started < 3)
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
