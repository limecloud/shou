import Foundation
import ShouCore
#if os(macOS)
import Darwin
#endif

public struct StartupCommandOutput: Sendable {
    public let status: Int32
    public let output: String
    public init(status: Int32, output: String) { self.status=status; self.output=output }
}

#if os(macOS)
/// Both streams are drained while the command runs; retained output and time are bounded.
enum NativeStartupCommand {
    private final class Buffer: @unchecked Sendable {
        let lock=NSLock()
        var data=Data()
        var truncated=false
        func drain(_ handle: FileHandle) {
            while let next=try? handle.read(upToCount: 4_096), !next.isEmpty {
                lock.lock()
                if next.count > 65_536-data.count { truncated=true }
                if data.count < 65_536 { data.append(next.prefix(65_536-data.count)) }
                lock.unlock()
            }
        }
        func text() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        func complete() -> Bool { lock.lock(); defer { lock.unlock() }; return !truncated }
    }
    static func run(_ arguments: [String], executable: String = "/bin/launchctl", deadline: ContinuousClock.Instant) throws -> StartupCommandOutput {
        guard ContinuousClock.now < deadline else { throw ShouError("resource_limit", "Startup command deadline exceeded.") }
        let process=Process(), stdout=Pipe(), stderr=Pipe(), exited=DispatchSemaphore(value: 0)
        process.executableURL=URL(fileURLWithPath: executable); process.arguments=arguments
        process.standardOutput=stdout; process.standardError=stderr
        process.terminationHandler={ _ in exited.signal() }
        try process.run()
        let buffer=Buffer(), readers=DispatchGroup()
        for pipe in [stdout, stderr] {
            readers.enter()
            DispatchQueue.global().async { buffer.drain(pipe.fileHandleForReading); readers.leave() }
        }
        while exited.wait(timeout: .now() + 0.01) != .success {
            if Task.isCancelled || ContinuousClock.now >= deadline {
                process.terminate()
                if exited.wait(timeout: .now() + 0.1) != .success { kill(process.processIdentifier, SIGKILL) }
                _ = readers.wait(timeout: .now() + 0.2)
                throw ShouError(Task.isCancelled ? "cancelled" : "resource_limit", "Startup command stopped.")
            }
        }
        guard readers.wait(timeout: .now() + 0.2) == .success else { throw ShouError("resource_limit", "Startup command output did not finish.") }
        guard buffer.complete() else { throw ShouError("resource_limit", "Startup command output exceeded its limit.") }
        return StartupCommandOutput(status: process.terminationStatus, output: buffer.text())
    }
}
#endif
