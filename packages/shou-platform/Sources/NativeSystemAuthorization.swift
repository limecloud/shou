import Foundation
import ShouCore
#if os(macOS)
import Darwin
import OSLog
#endif

/// One authenticated, process-bound native session is shared by platform adapters.
/// No password, arbitrary command or reusable deletion approval crosses this API.
public final class NativeSystemAuthorization: SystemAuthorizationProviding, @unchecked Sendable {
    public static let shared=NativeSystemAuthorization()
    private let lock=NSRecursiveLock()
    private let statusLock=NSLock()
    private var storedState=SystemAuthorizationState.notRequested
    private var state: SystemAuthorizationState {
        get { statusLock.lock(); defer { statusLock.unlock() }; return storedState }
        set { statusLock.lock(); storedState=newValue; statusLock.unlock() }
    }
    #if os(macOS)
    private var channel: Int32 = -1
    private var worker: AuthorizationPeer?
    #endif
    public init() {}
    #if os(macOS)
    init(authenticatedChannel: Int32, peer: AuthorizationPeer) {
        channel=authenticatedChannel; worker=peer; state = .authorized
    }
    deinit { if channel >= 0 { close(channel) } }
    #endif
    public var administratorState: SystemAuthorizationState {
        state
    }
    public func authorizeAdministrator() throws {
        lock.lock(); defer { lock.unlock() }
        #if os(macOS)
        if channel >= 0, worker?.isCurrent == true { return }
        invalidate()
        do { try start(); state = .authorized }
        catch {
            invalidate()
            state=(error as? ShouError)?.code == "authorization_cancelled" ? .cancelled : .unavailable
            if (error as? ShouError)?.code == "authorization_channel_lost" {
                throw ShouError("authorization_unavailable", "Administrator authorization could not be completed. Try again.")
            }
            throw error
        }
        #else
        state = .unavailable
        throw ShouError("unsupported_platform", "System authorization is unavailable on this platform.")
        #endif
    }
    #if os(macOS)
    func perform(_ operation: AuthorizationOperation, path: String = "", manifest: [FileEntry]? = nil,
                 budget: ScanBudget? = nil, action: StartupControlAction? = nil, trashPath: String? = nil,
                 rules: [CleanupRule]? = nil, fullDiskAccess: Bool? = nil,
                 document: DeveloperConfigurationDocument? = nil, text: String? = nil, logInspection: DeveloperLogInspection? = nil,
                 toolID: String? = nil,
                 cancelled: () -> Bool = { Task.isCancelled },
                 progress: (AuthorizationReply) -> Void = { _ in }) throws -> AuthorizationReply {
        lock.lock(); defer { lock.unlock() }
        try authorizeAdministrator()
        if cancelled() { throw ShouError("authorization_cancelled", "The authorized operation stopped before dispatch.") }
        let request=AuthorizationRequest(id: UUID().uuidString, operation: operation, path: path, manifest: manifest, budget: budget, action: action, trashPath: trashPath, rules: rules, fullDiskAccess: fullDiskAccess, document: document, text: text, logInspection: logInspection, toolID: toolID)
        do {
            try AuthorizationChannel.write(request, to: channel)
            var sentCancellation=false
            var replyDeadline=ContinuousClock.now.advanced(by:.seconds(660))
            while true {
                guard ContinuousClock.now < replyDeadline else { throw AuthorizationChannel.failure() }
                if cancelled() && !sentCancellation {
                    try AuthorizationChannel.write(AuthorizationRequest(id: request.id, operation: .cancelOperation, path: "", manifest: nil, budget: nil, action: nil), to: channel)
                    sentCancellation=true
                }
                var ready=pollfd(fd: channel, events: Int16(POLLIN), revents: 0)
                let status=poll(&ready, 1, 100)
                if status < 0 && errno == EINTR { continue }
                guard status >= 0 else { throw AuthorizationChannel.failure() }
                if status == 0 { continue }
                let reply=try AuthorizationChannel.read(AuthorizationReply.self, from: channel)
                replyDeadline=ContinuousClock.now.advanced(by:.seconds(660))
                guard reply.id == request.id else { throw AuthorizationChannel.failure() }
                if reply.progress { progress(reply); continue }
                if let error=reply.error { throw error }
                return reply
            }
        } catch let error as ShouError where error.code != "authorization_channel_lost" { throw error }
        catch {
            invalidate(); state = .unavailable
            // A dispatched request may already have changed files. Never reconnect
            // or replay it merely because the result channel was lost.
            throw ShouError("authorization_channel_lost", "The authorized operation lost its result channel. Inspect its recorded outcome before retrying.")
        }
    }
    private func invalidate() {
        if channel >= 0 { close(channel) }; channel = -1; worker=nil
    }
    private func start() throws {
        var stage="worker-executable"
        do { try connectWorker(stage: &stage) }
        catch {
            Logger(subsystem: "dev.limecloud.shou", category: "authorization")
                .error("Administrator connection failed at \(stage, privacy: .public)")
            throw error
        }
    }
    private func connectWorker(stage: inout String) throws {
        let executable=try Self.workerExecutable()
        stage="parent-identity"
        let parent=try AuthorizationPeer(pid: getpid())
        stage="socket-directory"
        let directory="/private/tmp/shou-authorization-" + UUID().uuidString
        guard mkdir(directory, 0o700) == 0 else { throw AuthorizationChannel.failure() }
        let socketPath=directory + "/channel"
        defer { unlink(socketPath); rmdir(directory) }
        let listener=socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw AuthorizationChannel.failure() }
        defer { close(listener) }
        AuthorizationChannel.configure(listener)
        stage="socket-listen"
        try AuthorizationChannel.bind(listener, path: socketPath)
        guard chmod(socketPath, 0o600) == 0, listen(listener, 1) == 0 else { throw AuthorizationChannel.failure() }
        let nonce=UUID().uuidString + UUID().uuidString
        let process=Process(), output=Pipe(), errors=Pipe()
        process.executableURL=URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments=["-e", Self.launchScript, "--", executable, socketPath, nonce, String(parent.pid), String(parent.uid), String(parent.started), String(parent.microseconds)]
        process.standardOutput=output; process.standardError=errors; process.standardInput=FileHandle.nullDevice
        try process.run()
        stage="system-consent"
        // Native consent may take as long as the user needs. It is not a scan timeout.
        process.waitUntilExit()
        let diagnostic=String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ShouError(diagnostic.contains("(-128)") ? "authorization_cancelled" : "authorization_denied", "Administrator authorization was cancelled or denied.")
        }
        var ready=pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        stage="worker-connect"
        guard poll(&ready, 1, 10_000) > 0 else { throw AuthorizationChannel.failure() }
        let connected=accept(listener, nil, nil)
        guard connected >= 0 else { throw AuthorizationChannel.failure() }
        var accepted=false
        defer { if !accepted { close(connected) } }
        AuthorizationChannel.configure(connected)
        stage="worker-identity"
        let peer=try AuthorizationChannel.peer(connected)
        stage="worker-path"
        guard peer.uid == 0, peer.path == executable else { throw AuthorizationChannel.failure() }
        stage="worker-handshake"
        let hello=try AuthorizationChannel.read(AuthorizationHello.self, from: connected)
        guard hello.version == 1, hello.nonce == nonce else { throw AuthorizationChannel.failure() }
        channel=connected; worker=peer; accepted=true
    }
    static func workerExecutable() throws -> String {
        let executable=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shou").path
        let candidate=FileManager.default.isExecutableFile(atPath: executable) ? executable : CommandLine.arguments[0]
        let path=URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        var metadata=stat()
        guard path.hasPrefix("/"), path.rangeOfCharacter(from: .controlCharacters) == nil,
              URL(fileURLWithPath: path).lastPathComponent == "shou",
              lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid() || metadata.st_uid == 0,
              metadata.st_mode & 0o022 == 0 else { throw ShouError("authorization_unavailable", "The packaged authorization worker is unavailable.") }
        return path
    }
    static let launchScript="""
    on run argv
      set helperCommand to quoted form of item 1 of argv & " --system-authorization-worker-v1"
      repeat with index from 2 to count of argv
        set helperCommand to helperCommand & " " & quoted form of item index of argv
      end repeat
      do shell script helperCommand & " </dev/null >/dev/null 2>&1 &" with administrator privileges
    end run
    """
    #endif
}

#if os(macOS)
enum AuthorizationOperation: String, Codable, Sendable {
    case applicationCatalog, applicationMetadata, applicationParentIdentity, inspectApplication, purgeApplication, trashApplication, restoreApplication, purgeTrashedApplication, startupToggle
    case pathIdentity, inspectPath, inspectCleanupPath, measureStoragePath, purgePath, trashPath, restorePath, purgeTrashPath, cancelOperation
    case configurationRead, configurationSave, logRead, logInspect, logClear
}
struct AuthorizationRequest: Codable, Sendable {
    let id: String
    let operation: AuthorizationOperation
    let path: String
    let manifest: [FileEntry]?
    let budget: ScanBudget?
    let action: StartupControlAction?
    var trashPath: String? = nil
    var rules: [CleanupRule]? = nil
    var fullDiskAccess: Bool? = nil
    var document: DeveloperConfigurationDocument? = nil
    var text: String? = nil
    var logInspection: DeveloperLogInspection? = nil
    var toolID: String? = nil
}
struct AuthorizationHello: Codable { let version: Int; let nonce: String }
struct AuthorizationReply: Codable, Sendable {
    let id: String
    var progress=false
    var snapshot: TreeSnapshot? = nil
    var application: ApplicationDefinition? = nil
    var catalog: ApplicationCatalog? = nil
    var identity: FileEntry? = nil
    var scanProgress: ScanProgress? = nil
    var storage: StorageMeasurement? = nil
    var document: DeveloperConfigurationDocument? = nil
    var text: String? = nil
    var logInspection: DeveloperLogInspection? = nil
    var completed: Int? = nil
    var total: Int? = nil
    var path: String? = nil
    var command: StartupCommandOutput? = nil
    var error: ShouError? = nil
}
struct AuthorizationPeer: Sendable {
    let pid: Int32
    let uid: UInt32
    let started: UInt64
    let microseconds: UInt64
    let path: String
    init(pid: Int32) throws {
        // PROC_PIDTBSDINFO requires access to the target user's process. A
        // normal client cannot use it for its root worker after authentication.
        // KERN_PROC_PID exposes the same birth identity across that boundary.
        var info=kinfo_proc(), size=MemoryLayout<kinfo_proc>.stride
        var query=[CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, UInt32(query.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { throw AuthorizationChannel.failure() }
        let birth=info.kp_proc.p_un.__p_starttime
        guard birth.tv_sec > 0, birth.tv_usec >= 0, birth.tv_usec < 1_000_000 else { throw AuthorizationChannel.failure() }
        var bytes=[CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length=proc_pidpath(pid, &bytes, UInt32(bytes.count))
        guard length > 0, let path=String(bytes: bytes.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8) else { throw AuthorizationChannel.failure() }
        self.pid=pid; uid=info.kp_eproc.e_ucred.cr_uid
        started=UInt64(birth.tv_sec); microseconds=UInt64(birth.tv_usec); self.path=path
    }
    var isCurrent: Bool {
        guard let current=try? Self(pid: pid) else { return false }
        return current.uid == uid && current.started == started && current.microseconds == microseconds && current.path == path
    }
}
enum AuthorizationChannel {
    static func configure(_ descriptor: Int32) {
        var enabled: Int32=1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        // Bound broken frames and stalled peers. Native consent happens before
        // this channel is used; individual scan budgets are at most 600 seconds.
        var timeout=timeval(tv_sec: 660, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
    static func failure() -> ShouError { ShouError("authorization_channel_lost", "The authorized system channel is unavailable.") }
    static func bind(_ descriptor: Int32, path: String) throws {
        var address=try address(path)
        let result=withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw failure() }
    }
    static func connect(_ descriptor: Int32, path: String) throws {
        var address=try address(path)
        let result=withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw failure() }
    }
    private static func address(_ path: String) throws -> sockaddr_un {
        var address=sockaddr_un(); address.sun_family=sa_family_t(AF_UNIX); address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes=Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw failure() }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in for (index, byte) in bytes.enumerated() { buffer[index]=UInt8(bitPattern: byte) } }
        return address
    }
    static func peer(_ descriptor: Int32) throws -> AuthorizationPeer {
        var uid: uid_t=0, gid: gid_t=0, pid: pid_t=0, size=socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(descriptor, &uid, &gid) == 0, getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else { throw failure() }
        let peer=try AuthorizationPeer(pid: pid)
        guard peer.uid == uid else { throw failure() }; return peer
    }
    static func write<T: Encodable>(_ value: T, to descriptor: Int32) throws {
        let data=try Codec.encode(value)
        guard data.count <= 64 * 1024 * 1024 else { throw failure() }
        var length=UInt32(data.count).bigEndian
        var frame=withUnsafeBytes(of: &length) { Data($0) }; frame.append(data)
        try frame.withUnsafeBytes { buffer in
            var offset=0
            while offset < buffer.count {
                let count=send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure() }; offset += count
            }
        }
    }
    static func read<T: Decodable>(_ type: T.Type, from descriptor: Int32) throws -> T {
        func bytes(_ size: Int) throws -> Data {
            var data=Data(count: size)
            try data.withUnsafeMutableBytes { buffer in
                var offset=0
                while offset < size {
                    let count=recv(descriptor, buffer.baseAddress!.advanced(by: offset), size - offset, 0)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw failure() }; offset += count
                }
            }
            return data
        }
        let header=try bytes(4), length=header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length > 0, length <= 64 * 1024 * 1024 else { throw failure() }
        return try Codec.decode(type, from: bytes(Int(length)))
    }
}
#endif
