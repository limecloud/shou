import Foundation
import ShouCore
#if os(macOS)
import Darwin
#endif

/// Controls only current-user launch agents. System daemons, Apple definitions,
/// Login Items and embedded helpers remain read-only and are handled by System Settings.
public struct NativeStartupControl: StartupControlling {
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory=homeDirectory
    }

    public func apply(definition: StartupDefinition, action: StartupControlAction) throws -> StartupControlResult {
        #if os(macOS)
        guard definition.controlCapability == "launchctl_user_agent",
              definition.sourceId == "macos.user_agents",
              definition.path.hasSuffix(".plist") else {
            throw ShouError("capability_unavailable", "Only current-user LaunchAgents can be managed here.")
        }
        let launchAgents=homeDirectory.appendingPathComponent("Library/LaunchAgents").standardizedFileURL.path
        let parent=URL(fileURLWithPath: definition.path).deletingLastPathComponent().standardizedFileURL.path
        guard parent == launchAgents else {
            throw ShouError("permission_denied", "Startup control is limited to the current user's LaunchAgents directory.")
        }
        guard definition.label.range(of: "^[A-Za-z0-9._-]{1,255}$", options: .regularExpression) != nil else {
            throw ShouError("invalid_argument", "The startup label is invalid.")
        }
        let (parentFD, name)=try SecurePaths.parent(definition.path)
        defer { close(parentFD) }
        var metadata=stat()
        guard fstatat(parentFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw SecurePaths.failure("Inspect startup definition", path: definition.path)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw ShouError("permission_denied", "Linked and non-regular startup definitions cannot be changed.")
        }
        guard metadata.st_uid == getuid() else {
            throw ShouError("permission_denied", "The startup definition is not owned by the current user.")
        }
        let bytes=try NativeDefinitionFiles.bytes(directory: parentFD, name: name, path: definition.path, maximumBytes: NativeStartupInventory.maximumDefinitionBytes,
            deadline: ContinuousClock.now.advanced(by: .seconds(2)), cancelled: { false })
        guard let dictionary=try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any],
              dictionary["Label"] as? String == definition.label else {
            throw ShouError("plan_stale", "The startup definition changed; check it again before changing its state.")
        }
        // LaunchAgents are associated with the logged-in user's GUI domain.
        // `gui/<uid>` is the user-login form accepted by launchctl for this source.
        let domain="gui/\(getuid())/\(definition.label)"
        let process=Process()
        process.executableURL=URL(fileURLWithPath: "/bin/launchctl")
        process.arguments=[action.rawValue, domain]
        let output=Pipe(), errors=Pipe()
        process.standardOutput=output; process.standardError=errors
        do { try process.run() } catch { throw ShouError("startup_control_failed", "launchctl could not be started.", details: ["error": error.localizedDescription]) }
        process.waitUntilExit()
        let stdoutData=output.fileHandleForReading.readDataToEndOfFile()
        let stderrData=errors.fileHandleForReading.readDataToEndOfFile()
        let stdout=String(data: stdoutData.prefix(8_192), encoding: .utf8) ?? ""
        let stderr=String(data: stderrData.prefix(8_192), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail=(stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShouError("startup_control_failed", "launchctl could not change the startup definition.", details: ["status": String(process.terminationStatus), "output": detail])
        }
        let state=action == .enable ? "enabled" : "disabled"
        return StartupControlResult(definitionId: definition.id, label: definition.label, action: action,
            configuredState: state, runtimeState: "unknown", controlCapability: definition.controlCapability,
            message: action == .enable ? "Startup definition enabled for the current user." : "Startup definition disabled for the current user.")
        #else
        throw ShouError("unsupported_platform", "Direct startup control is currently available only on macOS.")
        #endif
    }
}
