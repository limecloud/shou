import Foundation
import ShouCore
#if os(macOS)
import Darwin
#endif

/// Agent toggles apply only to the current GUI domain. Removal is restricted to
/// an owned ordinary definition directly inside the user's LaunchAgents folder.
public struct NativeStartupControl: StartupControlling {
    public typealias Command = @Sendable ([String], Double) throws -> StartupCommandOutput
    public typealias Trash = @Sendable (String, [FileEntry]) throws -> TrashResult
    private let homeDirectory: URL
    private let command: Command?
    private let administrator: Command?
    private let trash: Trash?
    private let loginItems: (any StartupLoginItemManaging)?
    private let backgroundRecords: (@Sendable () throws -> [StartupBackgroundRecord])?

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, command: Command? = nil, administrator: Command? = nil, trash: Trash? = nil,
                loginItems: (any StartupLoginItemManaging)? = nil, backgroundRecords: (@Sendable () throws -> [StartupBackgroundRecord])? = nil) {
        self.homeDirectory=homeDirectory; self.command=command; self.administrator=administrator; self.trash=trash
        self.loginItems=loginItems; self.backgroundRecords=backgroundRecords
    }

    public func apply(definition: StartupDefinition, action: StartupControlAction) throws -> StartupControlResult {
        #if os(macOS)
        if definition.controlCapability == "login_item" {
            return try NativeStartupLoginControl.apply(definition:definition,action:action,manager:loginItems ?? NativeStartupLoginItems(),backgroundRecords:{
                if let backgroundRecords { return try backgroundRecords() }
                return try NativeStartupRegistrations.backgroundRecords(limit:10_000,deadline:ContinuousClock.now.advanced(by:.seconds(5)))
            })
        }
        let user=definition.sourceId == "macos.user_agents"
        let daemon=definition.sourceId == "macos.local_daemons"
        guard user || (["macos.local_agents","macos.local_daemons"].contains(definition.sourceId) && action != .remove),
              action == .remove ? definition.removable : definition.controlCapability == (daemon ? "launchctl_system_daemon" : "launchctl_user_agent") else {
            throw ShouError("capability_unavailable", "This startup source must be managed in System Settings.")
        }
        let expectedParent=user ? homeDirectory.appendingPathComponent("Library/LaunchAgents").path : daemon ? "/Library/LaunchDaemons" : "/Library/LaunchAgents"
        let checked=try Self.preflight(path: definition.path, label: definition.label, expectedParent: expectedParent, userOwned: user)
        let actualProgram=(checked.dictionary["Program"] as? String) ?? (checked.dictionary["ProgramArguments"] as? [String])?.first
        let absoluteProgram=actualProgram.flatMap { $0.hasPrefix("/") ? $0 : nil }
        guard absoluteProgram == definition.programPath else { throw ShouError("plan_stale", "The startup target changed; scan again.") }
        if daemon {
            let state=try StartupSystemDaemonAuthorization.apply(label:definition.label,action:action,command:{ arguments,_ in try run(arguments) },administrator:{ arguments,_ in
                if let administrator { return try administrator(arguments,120) }
                if geteuid() == 0 { return try run(arguments) }
                let script=try StartupSystemDaemonAuthorization.script(action:action,label:definition.label)
                return try NativeStartupCommand.run(["-e",script],executable:"/usr/bin/osascript",deadline:ContinuousClock.now.advanced(by:.seconds(120)))
            })
            return StartupControlResult(definitionId:definition.id,label:definition.label,action:action,configuredState:state,runtimeState:"unknown",controlCapability:definition.controlCapability,message:"System startup definition updated and verified.")
        }
        if action == .remove {
            let filesystem=NativeFileSystem()
            let tree=try filesystem.inspectTarget(definition.path, budget: ScanBudget(maxEntries: 1, maxSeconds: 2), cancelled: { false })
            guard tree.complete, tree.entries.count == 1, let file=tree.entries.first,
                  file.kind == "file", file.contentDigest == Digest.sha256(checked.bytes), file.metadata == checked.metadata else {
                throw ShouError("plan_stale", "The startup definition changed before removal.")
            }
            let result=try trash?(definition.path, tree.entries) ?? filesystem.moveToTrash(definition.path, expected: tree.entries)
            guard result.verified else { throw ShouError("trash_outcome_unknown", "The startup definition was moved but its Trash destination could not be verified.") }
            return StartupControlResult(definitionId: definition.id, label: definition.label, action: action,
                configuredState: "not_applicable", runtimeState: "unknown", controlCapability: "system_settings",
                message: "Startup definition moved to Trash. An already running service may continue until logout.")
        }
        let domain="gui/\(getuid())"
        let changed=try run([action.rawValue, domain + "/" + definition.label])
        guard changed.status == 0 else { throw ShouError("startup_control_failed", "launchctl could not change the startup definition.", details: ["status": String(changed.status)]) }
        let observed=try run(["print-disabled", domain])
        let expected=action == .enable ? "enabled" : "disabled"
        guard observed.status == 0,
              LaunchctlStateParser.disabledOverrides(observed.output)?[definition.label] == expected else {
            throw ShouError("startup_verification_failed", "Startup state may have changed, but launchctl readback could not verify it. Scan again before retrying.")
        }
        return StartupControlResult(definitionId: definition.id, label: definition.label, action: action,
            configuredState: expected, runtimeState: "unknown", controlCapability: definition.controlCapability,
            message: action == .enable ? "Startup definition enabled for the current user." : "Startup definition disabled for the current user.")
        #else
        throw ShouError("unsupported_platform", "Direct startup control is currently available only on macOS.")
        #endif
    }

    #if os(macOS)
    private func run(_ arguments: [String]) throws -> StartupCommandOutput {
        if let command { return try command(arguments, 2) }
        return try NativeStartupCommand.run(arguments, deadline: ContinuousClock.now.advanced(by: .seconds(2)))
    }
    static func capability(path: String, label: String, sourceId: String, homeDirectory: URL, deadline: ContinuousClock.Instant) -> String {
        let user=sourceId == "macos.user_agents"
        guard user || ["macos.local_agents","macos.local_daemons"].contains(sourceId), ContinuousClock.now < deadline else { return "system_settings" }
        let parent=user ? homeDirectory.appendingPathComponent("Library/LaunchAgents").path : sourceId == "macos.local_daemons" ? "/Library/LaunchDaemons" : "/Library/LaunchAgents"
        guard (try? preflight(path:path,label:label,expectedParent:parent,userOwned:user,deadline:deadline)) != nil else { return "system_settings" }
        return sourceId == "macos.local_daemons" ? "launchctl_system_daemon" : "launchctl_user_agent"
    }
    private static func preflight(path: String, label: String, expectedParent: String, userOwned: Bool, deadline: ContinuousClock.Instant = .now.advanced(by:.seconds(2))) throws -> (bytes: Data, dictionary: [String: Any], metadata: FileEntry) {
        let parts=try SecurePaths.components(path)
        guard "/" + parts.joined(separator: "/") == path, path.hasSuffix(".plist"),
              path.rangeOfCharacter(from: .controlCharacters) == nil,
              URL(fileURLWithPath: path).deletingLastPathComponent().path == expectedParent,
              !URL(fileURLWithPath:path).lastPathComponent.hasPrefix("com.apple."),
              !label.hasPrefix("com.apple."), label.range(of: "^[A-Za-z0-9._@-]{1,255}$", options: .regularExpression) != nil else {
            throw ShouError("permission_denied", "Startup control is limited to ordinary third-party LaunchAgents in the expected directory.")
        }
        let (parent, name)=try SecurePaths.parent(path)
        defer { close(parent) }
        var metadata=stat(), directory=stat()
        guard fstat(parent, &directory) == 0, fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
              metadata.st_mode & 0o022 == 0, directory.st_mode & 0o022 == 0,
              metadata.st_uid == (userOwned ? getuid() : 0), directory.st_uid == (userOwned ? getuid() : 0) else {
            throw ShouError("permission_denied", "Linked, writable-by-others, or unowned startup definitions cannot be changed.")
        }
        let bytes=try NativeDefinitionFiles.bytes(directory: parent, name: name, path: path,
            deadline: deadline, cancelled: { false })
        guard let dictionary=try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any], dictionary["Label"] as? String == label else {
            throw ShouError("plan_stale", "The startup definition changed; scan again.")
        }
        return (bytes, dictionary, SecurePaths.entry(metadata, path: "."))
    }
    #endif
}
