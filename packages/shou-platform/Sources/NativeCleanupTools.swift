import Foundation
import ShouCore
#if os(macOS)
import Darwin
#endif

public struct NativeCleanupTools: CleanupToolRunning {
    private let homeDirectory: URL
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) { self.homeDirectory=homeDirectory }
    public var platform: CleanupToolPlatform {
        #if os(macOS)
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
        let output=try NativeManagedToolProcess(homeDirectory: homeDirectory).run(executable, arguments: command.arguments, timeout: timeoutSeconds)
        guard try identity(executable) == before else { throw ShouError("tool_changed", "The cleanup tool changed while running.") }
        guard let text=String(data: output, encoding: .utf8) else { throw ShouError("unsupported_schema", "The tool returned invalid UTF-8 output.") }
        return .init(text: text, executableIdentity: executable + ":" + before)
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
    #endif
}
