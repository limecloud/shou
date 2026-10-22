import Foundation
import ShouCore
#if os(macOS)
import Darwin
#endif

public struct NativeCleanupTools: CleanupToolRunning {
    private let homeDirectory: URL
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) { self.homeDirectory=homeDirectory }
    public var platform: CleanupToolPlatform {
        #if os(Windows)
        .windows
        #elseif os(macOS)
        .macOS
        #else
        .unsupported
        #endif
    }
    public func run(_ command: CleanupToolCommand, timeoutSeconds: Double, expectedExecutableIdentity: String? = nil) throws -> CleanupToolOutput {
        #if os(macOS)
        guard timeoutSeconds.isFinite, (1...300).contains(timeoutSeconds),
              command.arguments.allSatisfy({ !$0.contains("\0") }) else { throw ShouError("invalid_argument", "Invalid tool operation budget.") }
        if case .rustRemove(let name)=command {
            guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.+-]{1,160}$", options: .regularExpression) != nil else { throw ShouError("invalid_argument", "Invalid toolchain name.") }
        }
        let executable=try locate(command.tool)
        let before=try identity(executable)
        guard expectedExecutableIdentity == nil || expectedExecutableIdentity == executable + ":" + before else { throw ShouError("tool_changed", "The cleanup tool changed after review.") }
        guard !command.mutating || expectedExecutableIdentity != nil else { throw ShouError("confirmation_required", "Mutating tool operations require a reviewed executable identity.") }
        let output=try spawn(executable, arguments: command.arguments, timeout: timeoutSeconds)
        guard try identity(executable) == before else { throw ShouError("tool_changed", "The cleanup tool changed while running.") }
        guard let text=String(data: output, encoding: .utf8) else { throw ShouError("unsupported_schema", "The tool returned invalid UTF-8 output.") }
        return .init(text: text, executableIdentity: executable + ":" + before)
        #elseif os(Windows)
        return try WindowsCleanupTools(homeDirectory: homeDirectory).run(command, timeoutSeconds: timeoutSeconds, expectedExecutableIdentity: expectedExecutableIdentity)
        #else
        throw ShouError("capability_unavailable", "Tool-managed cleanup is currently available on macOS.")
        #endif
    }
    #if os(macOS)
    private func locate(_ tool: String) throws -> String {
        let home=homeDirectory.path
        var paths=["/opt/homebrew/bin/" + tool, "/usr/local/bin/" + tool, "/usr/bin/" + tool]
        if tool == "rustup" { paths.insert(home + "/.cargo/bin/rustup", at: 0) }
        if tool == "docker" { paths.append("/Applications/Docker.app/Contents/Resources/bin/docker") }
        if tool == "conda" { paths += [home + "/miniforge3/bin/conda",home + "/miniconda3/bin/conda",home + "/anaconda3/bin/conda","/opt/anaconda3/bin/conda","/opt/miniconda3/bin/conda"] }
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            let resolved=URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            _ = try identity(resolved)
            return resolved
        }
        throw ShouError("tool_not_installed", "The cleanup tool is not installed in a supported location.", details: ["tool":tool])
    }
    private func identity(_ path: String) throws -> String {
        var metadata=stat()
        guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              [0,getuid()].contains(metadata.st_uid), metadata.st_mode & 0o022 == 0 else {
            throw ShouError("permission_denied", "The cleanup tool has an unsupported owner or writable permissions.")
        }
        return "\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_size):\(metadata.st_mtimespec.tv_sec):\(metadata.st_mtimespec.tv_nsec):\(metadata.st_ctimespec.tv_sec):\(metadata.st_ctimespec.tv_nsec)"
    }
    private func spawn(_ executable: String, arguments: [String], timeout: Double) throws -> Data {
        var output=[Int32](repeating: 0, count: 2), diagnostics=output
        guard pipe(&output) == 0 else { throw ShouError("io_error", "Cannot create tool output channel.") }
        defer { output.forEach { close($0) } }
        guard pipe(&diagnostics) == 0 else { throw ShouError("io_error", "Cannot create tool diagnostic channel.") }
        defer { diagnostics.forEach { close($0) } }
        let input=open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { throw ShouError("io_error", "Cannot initialize tool input.") }
        defer { close(input) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ShouError("io_error", "Cannot initialize tool file actions.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw ShouError("io_error", "Cannot initialize tool process attributes.") }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw ShouError("io_error", "Cannot isolate the cleanup tool process group.") }
        guard posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, diagnostics[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, homeDirectory.path) == 0 else { throw ShouError("io_error", "Cannot configure cleanup tool channels.") }
        for fd in [output[0],output[1],diagnostics[0],diagnostics[1],input] where fd > 2 {
            guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw ShouError("io_error", "Cannot configure cleanup tool descriptors.") }
        }
        let original=ProcessInfo.processInfo.environment
        var environment=["HOME":homeDirectory.path,"PATH":"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin","LC_ALL":"C","HOMEBREW_NO_AUTO_UPDATE":"1","HOMEBREW_NO_ANALYTICS":"1","HOMEBREW_NO_INSTALL_CLEANUP":"1","RUSTUP_AUTO_INSTALL":"0"]
        for name in ["USER","LOGNAME","TMPDIR","RUSTUP_HOME","CARGO_HOME"] { if let value=original[name] { environment[name]=value } }
        let argv=([executable]+arguments).map { strdup($0) } + [nil]
        let envp=environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t=0
        let status=argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { env in
            posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
        } }
        guard status == 0 else { throw ShouError("tool_unavailable", "The cleanup tool could not be started.") }
        // The child has its own process group from the first instruction.
        // Cancellation and timeout stop child tools as well as their launcher.
        close(output[1]); output[1] = -1
        close(diagnostics[1]); diagnostics[1] = -1
        var reaped=false, finished=false
        defer {
            if !finished { kill(-pid, SIGKILL) }
            if !reaped { var result: Int32=0; while waitpid(pid, &result, 0) < 0 && errno == EINTR {} }
        }
        for fd in [output[0], diagnostics[0]] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw ShouError("io_error", "Cannot bound cleanup tool output.") }
        }
        let deadline=ProcessInfo.processInfo.systemUptime + timeout
        var data=Data(), diagnosticBytes=0, result: Int32=0
        var ended=Set<Int32>(), buffer=[UInt8](repeating: 0, count: 65536)
        while true {
            if Task.isCancelled { throw ShouError("cancelled", "Tool operation cancelled; inspect its recorded outcome.") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ShouError("tool_timeout", "The cleanup tool exceeded its time budget.") }
            for fd in [output[0], diagnostics[0]] where !ended.contains(fd) {
                let count=buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    if fd == output[0] { data.append(contentsOf: buffer.prefix(count)) } else { diagnosticBytes += count }
                    guard data.count <= 4 * 1024 * 1024, diagnosticBytes <= 1024 * 1024 else { throw ShouError("resource_limit", "Tool output exceeded its budget.") }
                } else if count == 0 { ended.insert(fd) }
                else if errno != EAGAIN && errno != EINTR { throw ShouError("io_error", "Cannot read cleanup tool output.") }
            }
            if !reaped {
                let done=waitpid(pid, &result, WNOHANG)
                if done == pid { reaped=true }
                else if done < 0 && errno != EINTR { throw ShouError("io_error", "Cannot verify cleanup tool exit.") }
            }
            if reaped && ended.count == 2 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard result == 0 else { throw ShouError("tool_failed", "The cleanup tool did not complete successfully.", details: ["exit_status":String(result)]) }
        finished=true
        return data
    }
    #endif
}
