import Foundation
import ShouCore
#if os(Windows)
import CShouWindows
#endif

public struct WindowsCleanupTools: CleanupToolRunning {
    public let platform: CleanupToolPlatform = .windows
    private let homeDirectory: URL
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) { self.homeDirectory=homeDirectory }
    public func run(_ command: CleanupToolCommand, timeoutSeconds: Double, expectedExecutableIdentity: String? = nil) throws -> CleanupToolOutput {
        guard timeoutSeconds.isFinite, (1...300).contains(timeoutSeconds) else { throw ShouError("invalid_argument", "Invalid tool operation budget.") }
        let operation: UInt32
        var toolchain=""
        switch command {
        case .dockerContext: operation=1
        case .dockerPreview: operation=2
        case .dockerPrune: operation=3
        case .condaPreview: operation=4
        case .condaPrune: operation=5
        case .rustList: operation=6
        case .rustOverrides: operation=7
        case .rustDefault: operation=8
        case .rustRemove(let name):
            guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.+-]{1,160}$", options: .regularExpression) != nil else { throw ShouError("invalid_argument", "Invalid toolchain name.") }
            operation=9; toolchain=name
        case .brewPreview, .brewPrune: throw ShouError("capability_unavailable", "Homebrew cleanup is specific to macOS.")
        }
        guard !command.mutating || expectedExecutableIdentity != nil else { throw ShouError("confirmation_required", "Mutating tool operations require a reviewed executable identity.") }
        #if os(Windows)
        try Task.checkCancellation()
        var pathPointer: UnsafeMutablePointer<CChar>?, info=shou_win_info()
        let code=shou_win_cleanup_tool_info(homeDirectory.path, command.tool, &pathPointer, &info)
        defer { shou_win_free(pathPointer) }
        try check(code)
        guard let pathPointer, let path=String(validatingCString: pathPointer) else { throw ShouError("unsupported_schema", "The tool path is not valid UTF-8.") }
        let identity=try Digest.of(WindowsNative.entry(info, path: path))
        guard expectedExecutableIdentity == nil || expectedExecutableIdentity == identity else { throw ShouError("tool_changed", "The cleanup tool changed after review.") }
        var output: UnsafeMutablePointer<CChar>?
        let status=shou_win_cleanup_tool_run(homeDirectory.path, operation, toolchain, path, &info, UInt32(timeoutSeconds*1000), { _ in Task.isCancelled ? 1 : 0 }, nil, &output)
        defer { shou_win_free(output) }
        try check(status)
        guard let output, let text=String(validatingCString: output) else { throw ShouError("unsupported_schema", "The tool returned invalid UTF-8 output.") }
        return .init(text: text, executableIdentity: identity)
        #else
        throw ShouError("capability_unavailable", "Windows tool cleanup requires Windows.")
        #endif
    }
    #if os(Windows)
    private func check(_ code: Int32) throws {
        guard code != 0 else { return }
        let category: String
        switch code {
        case 2, 3: category="tool_not_installed"
        case 5: category="permission_denied"
        case 1006: category="tool_changed"
        case 1223: category="cancelled"
        case 1460: category="tool_timeout"
        case 234: category="resource_limit"
        case 1067: category="tool_failed"
        default: category="tool_unavailable"
        }
        throw ShouError(category, "Windows could not safely complete the tool operation.")
    }
    #endif
}
