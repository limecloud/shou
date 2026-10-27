import Foundation
import ShouCore
#if os(macOS)
import Darwin

// Shared process boundary; callers supply only closed, platform-owned commands.
struct NativeManagedToolProcess {
    let homeDirectory: URL
    var additionalEnvironment: [String:String] = [:]
    func run(_ executable: String, arguments: [String], timeout: Double, observeCancellation: Bool = true, standardInput: Data? = nil, outputFileDescriptor: Int32? = nil) throws -> Data {
        var output=[Int32](repeating: 0, count: 2), diagnostics=output
        guard pipe(&output) == 0 else { throw ShouError("io_error", "Cannot create tool output channel.") }
        defer { output.forEach { close($0) } }
        guard pipe(&diagnostics) == 0 else { throw ShouError("io_error", "Cannot create tool diagnostic channel.") }
        defer { diagnostics.forEach { close($0) } }
        let input: Int32
        if let standardInput {
            guard standardInput.count <= 262_144 else { throw ShouError("resource_limit", "Managed tool input exceeded its budget.") }
            var pattern=Array("/private/var/tmp/shou-tool-input-XXXXXX".utf8CString)
            input=pattern.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
            guard input >= 0 else { throw ShouError("io_error", "Cannot create private tool input.") }
            pattern.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
            do {
                let handle=FileHandle(fileDescriptor: input, closeOnDealloc: false)
                try handle.write(contentsOf: standardInput)
                guard lseek(input, 0, SEEK_SET) == 0 else { throw ShouError("io_error", "Cannot initialize private tool input.") }
            } catch { close(input); throw error }
        } else { input=open("/dev/null", O_RDONLY | O_CLOEXEC) }
        guard input >= 0 else { throw ShouError("io_error", "Cannot initialize tool input.") }
        defer { close(input) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ShouError("io_error", "Cannot initialize tool file actions.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw ShouError("io_error", "Cannot initialize tool process attributes.") }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw ShouError("io_error", "Cannot isolate the managed tool process group.") }
        guard posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, outputFileDescriptor ?? output[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, diagnostics[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, homeDirectory.path) == 0 else { throw ShouError("io_error", "Cannot configure managed tool channels.") }
        for fd in Set([output[0],output[1],diagnostics[0],diagnostics[1],input] + (outputFileDescriptor.map { [$0] } ?? [])) where fd > 2 {
            guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw ShouError("io_error", "Cannot configure managed tool descriptors.") }
        }
        let original=ProcessInfo.processInfo.environment
        var environment=["HOME":homeDirectory.path,"PATH":"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin","LC_ALL":"C","HOMEBREW_NO_AUTO_UPDATE":"1","HOMEBREW_NO_ANALYTICS":"1","HOMEBREW_NO_INSTALL_CLEANUP":"1","RUSTUP_AUTO_INSTALL":"0"]
        for name in ["USER","LOGNAME","TMPDIR","RUSTUP_HOME","CARGO_HOME"] { if let value=original[name] { environment[name]=value } }
        environment.merge(additionalEnvironment) { _, new in new }
        let argv=([executable]+arguments).map { strdup($0) } + [nil]
        let envp=environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t=0
        let status=argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { env in
            posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
        } }
        guard status == 0 else { throw ShouError("tool_unavailable", "The managed tool could not be started.") }
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
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw ShouError("io_error", "Cannot bound managed tool output.") }
        }
        let deadline=ProcessInfo.processInfo.systemUptime + timeout
        var data=Data(), diagnosticBytes=0, result: Int32=0
        var ended=Set<Int32>(), buffer=[UInt8](repeating: 0, count: 65536)
        while true {
            if observeCancellation && Task.isCancelled { throw ShouError("cancelled", "Tool operation cancelled; inspect its recorded outcome.") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ShouError("tool_timeout", "The managed tool exceeded its time budget.") }
            for fd in [output[0], diagnostics[0]] where !ended.contains(fd) {
                let count=buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    if fd == output[0] { data.append(contentsOf: buffer.prefix(count)) } else { diagnosticBytes += count }
                    guard data.count <= 4 * 1024 * 1024, diagnosticBytes <= 1024 * 1024 else { throw ShouError("resource_limit", "Tool output exceeded its budget.") }
                } else if count == 0 { ended.insert(fd) }
                else if errno != EAGAIN && errno != EINTR { throw ShouError("io_error", "Cannot read managed tool output.") }
            }
            if !reaped {
                let done=waitpid(pid, &result, WNOHANG)
                if done == pid { reaped=true }
                else if done < 0 && errno != EINTR { throw ShouError("io_error", "Cannot verify managed tool exit.") }
            }
            if reaped && ended.count == 2 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard result == 0 else { throw ShouError("tool_failed", "The managed tool did not complete successfully.", details: ["exit_status":String(result)]) }
        finished=true
        return data
    }
}
#endif
