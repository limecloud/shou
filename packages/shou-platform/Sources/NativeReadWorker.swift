import Foundation
import Dispatch
import ShouCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)
private enum ReadOperation: String, Codable, Sendable { case identity, inspect }
private struct ReadRequest: Codable, Sendable {
    let version: Int
    let id: String
    let parentPid: Int32
    let operation: ReadOperation
    let path: String
    let rules: [CleanupRule]?
    let budget: ScanBudget
}
private struct ReadProgress: Codable, Sendable {
    let id: String
    let stage: String
    let entryCount: Int
    let currentPath: String
    let limitReached: Bool?
}
private struct ReadResponse: Codable, Sendable {
    let version: Int
    let id: String
    let identity: FileEntry?
    var snapshot: TreeSnapshot?
    let error: ShouError?
    var entryCount: Int? = nil
    var pageDigests: [String]? = nil
}

private let readEntryPageSize=10_000

/// Keeps at most two children alive, including any child awaiting kernel exit
/// after SIGKILL. Repeated cancellation cannot accumulate unbounded workers.
private final class ReadChildren: @unchecked Sendable {
    static let shared=ReadChildren()
    private let lock=NSLock()
    private var children: [String: Process]=[:]
    func insert(_ process: Process, id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard children.count < 2 else { throw ShouError("resource_limit", "Read workers are still stopping. Try the scan again shortly.") }
        children[id]=process
    }
    func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        children.removeValue(forKey: id)
    }
}

private enum ReadChannel {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try Codec.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func read(_ url: URL, limit: Int, check: () throws -> Void = {}) throws -> Data {
        let descriptor=open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ShouError("io_error", "Read worker output is unavailable.") }
        defer { close(descriptor) }
        var metadata=stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_nlink == 1, metadata.st_size >= 0,
              metadata.st_size <= limit else { throw ShouError("io_error", "Read worker output exceeded its supported format or size.") }
        var data=Data(), bytes=[UInt8](repeating: 0, count: 65_536)
        while true {
            try check()
            let count=bytes.withUnsafeMutableBytes { buffer in
                #if canImport(Darwin)
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
                #else
                Glibc.read(descriptor, buffer.baseAddress, buffer.count)
                #endif
            }
            if count == 0 { return data }
            if count < 0 && errno == EINTR { continue }
            guard count > 0, data.count + count <= limit else { throw ShouError("io_error", "Read worker output could not be read within its budget.") }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
}

struct NativeReadClient {
    let executable: URL
    func rootIdentity(_ path: String) throws -> FileEntry {
        let request=ReadRequest(version: 1, id: UUID().uuidString, parentPid: getpid(), operation: .identity, path: path, rules: nil, budget: ScanBudget(maxEntries: 1, maxSeconds: 10))
        let response=try run(request, cancelled: { Task.isCancelled }, progress: { _ in })
        guard let identity=response.identity, response.snapshot == nil,
              identity.path == ".", identity.kind == "directory", identity.owner == getuid() else { throw invalidResponse() }
        return identity
    }
    func inspect(_ path: String, rules: [CleanupRule]?, budget: ScanBudget, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        let request=ReadRequest(version: 1, id: UUID().uuidString, parentPid: getpid(), operation: .inspect, path: path, rules: rules, budget: budget)
        progress(ScanProgress(stage: "scanning", entryCount: 0, currentPath: path))
        let response=try run(request, cancelled: cancelled, progress: progress)
        guard let snapshot=response.snapshot, response.identity == nil,
              let root=snapshot.entries.first(where: { $0.path == "." }), root.kind == "directory",
              snapshot.entries.count <= budget.maxEntries,
              !snapshot.complete || snapshot.issues.isEmpty,
              snapshot.discoveryComplete != true || snapshot.issues.isEmpty else { throw invalidResponse() }
        progress(ScanProgress(stage: "validating", entryCount: snapshot.entries.count, currentPath: path, limitReached: snapshot.issues.contains("resource_limit")))
        var previous: String?
        var directories=Set<String>()
        for (index, entry) in snapshot.entries.enumerated() {
            if index % 4096 == 0, cancelled() || Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
            guard validRelativePath(entry.path), ["directory", "file", "symlink", "special"].contains(entry.kind),
                  entry.device == root.device, entry.logicalBytes >= 0, entry.allocatedBytes >= 0,
                  previous.map({ $0 < entry.path }) ?? true else { throw invalidResponse() }
            previous=entry.path
            if entry.kind == "directory" { directories.insert(entry.path) }
        }
        guard (snapshot.completedPaths ?? []).allSatisfy({ directories.contains($0) }) else { throw invalidResponse() }
        if cancelled() || Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        return snapshot
    }
    private func validRelativePath(_ path: String) -> Bool {
        if path == "." { return true }
        return !path.hasPrefix("/") && !path.contains("\0") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private func invalidResponse() -> ShouError { ShouError("io_error", "Read worker returned invalid or incomplete evidence.") }
    private func run(_ request: ReadRequest, cancelled: @Sendable () -> Bool, progress: @Sendable (ScanProgress) -> Void) throws -> ReadResponse {
        guard (1...1_000_000).contains(request.budget.maxEntries), request.budget.maxSeconds.isFinite,
              (1...600).contains(request.budget.maxSeconds), (1...128).contains(request.budget.maxDepth) else {
            throw ShouError("invalid_argument", "Scan budget is outside supported limits.")
        }
        let deadline=ProcessInfo.processInfo.systemUptime + request.budget.maxSeconds + 2
        func check() throws {
            if cancelled() || Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw ShouError("resource_limit", "The location did not respond within the scan time limit.", details: ["path": request.path]) }
        }
        try check()
        var temporary=FileManager.default.temporaryDirectory.path
        if temporary.hasPrefix("/var/") { temporary="/private" + temporary }
        let channel=URL(fileURLWithPath: temporary, isDirectory: true).appendingPathComponent("shou-read-" + request.id, isDirectory: true)
        let requestURL=channel.appendingPathComponent("request.json", isDirectory: false)
        let progressURL=channel.appendingPathComponent("progress.json", isDirectory: false)
        let resultURL=channel.appendingPathComponent("result.json", isDirectory: false)
        try FileManager.default.createDirectory(at: channel, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: channel) }
        try ReadChannel.write(request, to: requestURL)
        let process=Process()
        process.executableURL=executable
        process.arguments=["--internal-read-worker", channel.path]
        process.standardInput=FileHandle.nullDevice; process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
        process.terminationHandler={ _ in ReadChildren.shared.remove(request.id) }
        try ReadChildren.shared.insert(process, id: request.id)
        do { try process.run() }
        catch { ReadChildren.shared.remove(request.id); throw ShouError("capability_unavailable", "The read worker could not be started.") }
        defer {
            // No waitUntilExit: an outstanding kernel request must not hold the caller.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        var lastProgress=Data()
        var lastUpdate: ScanProgress?
        func readProgress() {
            if let data=try? ReadChannel.read(progressURL, limit: 65_536), data != lastProgress,
               let update=try? Codec.decode(ReadProgress.self, from: data), update.id == request.id,
               update.entryCount >= 0, update.entryCount <= request.budget.maxEntries,
               ["scanning", "analysis", "transferring"].contains(update.stage) {
                let value=ScanProgress(stage: update.stage, entryCount: update.entryCount, currentPath: update.currentPath, limitReached: update.limitReached ?? false)
                lastUpdate=value
                progress(value)
                lastProgress=data
            }
        }
        while process.isRunning {
            try check()
            readProgress()
            Thread.sleep(forTimeInterval: 0.025)
        }
        ReadChildren.shared.remove(request.id)
        try check()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw invalidResponse() }
        readProgress()
        let limit=min(536_870_912, max(1_048_576, request.budget.maxEntries * 2048 + 1_048_576))
        if request.operation == .inspect {
            progress(ScanProgress(stage: "loading", entryCount: lastUpdate?.entryCount ?? 0, currentPath: request.path, limitReached: lastUpdate?.limitReached ?? false))
        }
        let data=try ReadChannel.read(resultURL, limit: limit, check: check)
        var response: ReadResponse
        do { response=try Codec.decode(ReadResponse.self, from: data) }
        catch { throw invalidResponse() }
        try check()
        guard response.version == 1, response.id == request.id else { throw invalidResponse() }
        if let failure=response.error {
            guard response.identity == nil, response.snapshot == nil else { throw invalidResponse() }
            throw failure
        }
        if let count=response.entryCount {
            guard request.operation == .inspect, response.identity == nil,
                  var snapshot=response.snapshot, snapshot.entries.isEmpty,
                  count > readEntryPageSize, count <= request.budget.maxEntries,
                  let digests=response.pageDigests, digests.count == (count + readEntryPageSize - 1) / readEntryPageSize else { throw invalidResponse() }
            snapshot.entries.reserveCapacity(count)
            for (index, digest) in digests.enumerated() {
                try check()
                let url=channel.appendingPathComponent("entries-" + String(index) + ".json")
                let data=try ReadChannel.read(url, limit: readEntryPageSize * 8192 + 1_048_576, check: check)
                guard Digest.sha256(data) == digest else { throw invalidResponse() }
                guard let entries=try? Codec.decode([FileEntry].self, from: data) else { throw invalidResponse() }
                try check()
                guard entries.count == min(readEntryPageSize, count - index * readEntryPageSize) else { throw invalidResponse() }
                snapshot.entries.append(contentsOf: entries)
            }
            response.snapshot=snapshot
        } else if response.pageDigests != nil { throw invalidResponse() }
        return response
    }
}

/// Internal, read-only IPC entry point shared by the packaged CLI and test host.
/// It never opens the record store and cannot invoke cleanup or follow-up actions.
public enum NativeReadWorker {
    public static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard arguments.first == "--internal-read-worker" else { return nil }
        guard arguments.count == 2 else { return 2 }
        do {
            let channel=URL(fileURLWithPath: arguments[1], isDirectory: true)
            let requestURL=channel.appendingPathComponent("request.json", isDirectory: false)
            let progressURL=channel.appendingPathComponent("progress.json", isDirectory: false)
            let resultURL=channel.appendingPathComponent("result.json", isDirectory: false)
            var metadata=stat()
            guard lstat(channel.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else { return 2 }
            let data=try ReadChannel.read(requestURL, limit: 16_777_216)
            let request=try Codec.decode(ReadRequest.self, from: data)
            guard request.version == 1, UUID(uuidString: request.id) != nil, request.parentPid == getppid(),
                  (1...1_000_000).contains(request.budget.maxEntries), request.budget.maxSeconds.isFinite,
                  (1...600).contains(request.budget.maxSeconds), (1...128).contains(request.budget.maxDepth) else { return 2 }
            _ = try SecurePaths.components(request.path)
            let deadline=ProcessInfo.processInfo.systemUptime + request.budget.maxSeconds + 3
            let watchdog=DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            watchdog.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
            watchdog.setEventHandler {
                if getppid() != request.parentPid || ProcessInfo.processInfo.systemUptime >= deadline {
                    // A read worker has no mutations to finish on parent exit.
                    kill(getpid(), SIGKILL)
                }
            }
            watchdog.resume()
            defer { watchdog.cancel() }
            var response: ReadResponse
            do {
                let native=NativeFileSystem()
                switch request.operation {
                case .identity:
                    guard request.rules == nil else { return 2 }
                    response=ReadResponse(version: 1, id: request.id, identity: try native.rootIdentity(request.path), snapshot: nil, error: nil)
                case .inspect:
                    for rule in request.rules ?? [] { _ = try CleanupRule.parse(Codec.encode(rule)) }
                    let emit: @Sendable (ScanProgress) -> Void = { update in
                        try? ReadChannel.write(ReadProgress(id: request.id, stage: update.stage, entryCount: update.entryCount, currentPath: update.currentPath, limitReached: update.limitReached), to: progressURL)
                    }
                    let snapshot: TreeSnapshot
                    if let rules=request.rules {
                        snapshot=try native.inspectCleanup(request.path, rules: rules, budget: request.budget, cancelled: { false }, progress: emit)
                    } else {
                        snapshot=try native.inspect(request.path, budget: request.budget, cancelled: { false }, progress: emit)
                    }
                    response=ReadResponse(version: 1, id: request.id, identity: nil, snapshot: snapshot, error: nil)
                    emit(ScanProgress(stage: "transferring", entryCount: snapshot.entries.count, currentPath: request.path, limitReached: snapshot.issues.contains("resource_limit")))
                }
            } catch {
                response=ReadResponse(version: 1, id: request.id, identity: nil, snapshot: nil,
                    error: error as? ShouError ?? ShouError("io_error", "The location could not be inspected."))
            }
            if let snapshot=response.snapshot, snapshot.entries.count > readEntryPageSize {
                var digests=[String]()
                for offset in stride(from: 0, to: snapshot.entries.count, by: readEntryPageSize) {
                    let end=min(offset + readEntryPageSize, snapshot.entries.count)
                    let entries=Array(snapshot.entries[offset..<end])
                    let data=try Codec.encode(entries)
                    let url=channel.appendingPathComponent("entries-" + String(digests.count) + ".json")
                    try data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    digests.append(Digest.sha256(data))
                }
                response.entryCount=snapshot.entries.count
                response.pageDigests=digests
                var metadata=snapshot; metadata.entries=[]
                response.snapshot=metadata
            }
            try ReadChannel.write(response, to: resultURL)
            return 0
        } catch { return 5 }
    }
}
#endif
