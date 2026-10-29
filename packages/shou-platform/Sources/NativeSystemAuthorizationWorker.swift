import Foundation
import ShouCore
#if os(macOS)
import Darwin
import OSLog
#endif

/// A finite platform protocol, authenticated to the original caller process.
/// The worker owns no business store and cannot accept shell commands or roots.
public enum NativeSystemAuthorizationWorker {
    public static func runIfRequested(_ arguments: [String]) async -> Int32? {
        guard arguments.first?.hasPrefix("--system-authorization-worker") == true else { return nil }
        #if os(macOS)
        guard arguments.count == 7, arguments[0] == "--system-authorization-worker-v2", geteuid() == 0,
              arguments[1].hasPrefix("/private/tmp/shou-authorization-"), arguments[1].hasSuffix("/channel"),
              arguments[2].count == 72, let pid=Int32(arguments[3]), let uid=UInt32(arguments[4]), uid != 0,
              let started=UInt64(arguments[5]), let microseconds=UInt64(arguments[6]),
              let parent=try? AuthorizationPeer(pid: pid), parent.uid == uid,
              parent.started == started, parent.microseconds == microseconds else {
            Logger(subsystem: "dev.limecloud.shou", category: "authorization").error("Administrator worker rejected invocation identity")
            return 77
        }
        let descriptor=socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return 77 }
        defer { close(descriptor) }
        AuthorizationChannel.configure(descriptor)
        var stage="socket-connect"
        do {
            try AuthorizationChannel.connect(descriptor, path: arguments[1])
            stage="parent-peer"
            let peer=try AuthorizationChannel.peer(descriptor)
            guard peer.pid == parent.pid, peer.uid == parent.uid, parent.isCurrent else {
                Logger(subsystem: "dev.limecloud.shou", category: "authorization").error("Administrator worker rejected socket peer")
                return 77
            }
            let executable=try AuthorizationPeer(pid: getpid()).path
            let appParent=URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent()
            let expectedDesktop=appParent.appendingPathComponent("MacOS/Shou").path
            guard parent.path == executable || (executable.hasSuffix("/Contents/Helpers/shou") && parent.path == expectedDesktop) else {
                Logger(subsystem: "dev.limecloud.shou", category: "authorization").error("Administrator worker rejected parent executable")
                return 77
            }
            guard let account=getpwuid(uid), let home=String(validatingCString: account.pointee.pw_dir) else { return 77 }
            let roots=["/Applications", home + "/Applications"]
            var transfers=[String]()
            defer { for path in transfers { NativeAuthorizedFileSystem.discardStorage(path,uid:uid) } }
            try AuthorizationChannel.write(AuthorizationHello(version: 2, nonce: arguments[2]), to: descriptor)
            stage="requests"
            var order=AuthorizationRequestOrder()
            var completedRequest: String?
            while parent.isCurrent {
                var ready=pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let status=poll(&ready, 1, 1000)
                if status < 0 && errno == EINTR { continue }
                guard status >= 0 else { return 77 }
                if status == 0 { continue }
                let request=try AuthorizationChannel.read(AuthorizationRequest.self, from: descriptor)
                // A cancellation sent while the final reply was in flight is
                // consumed without dispatching or replaying the completed item.
                if request.operation == .cancelOperation, request.id == completedRequest, order.matchesCancellation(request) { continue }
                guard parent.isCurrent else { return 77 }
                try order.accept(request)
                let operation=Task.detached {
                    do { return try perform(request, descriptor: descriptor, roots: roots, home: home, uid: uid, executable: executable) }
                    catch {
                        let failure=(error as? ShouError) ?? ShouError("io_error", "The authorized system operation failed.")
                        Logger(subsystem: "dev.limecloud.shou", category: "authorization")
                            .error("Authorized \(request.operation.rawValue, privacy: .public) failed: \(failure.code, privacy: .public), stage \(failure.details["stage"] ?? "native-operation", privacy: .public), pid \(failure.details["pid"] ?? "unknown", privacy: .public), errno \(failure.details["native_error"] ?? "unknown", privacy: .public), sqlite \(failure.details["sqlite_code"] ?? "none", privacy: .public)/\(failure.details["sqlite_extended_code"] ?? "none", privacy: .public)")
                        return AuthorizationReply(id: request.id, error: failure)
                    }
                }
                let lifetime=Task.detached {
                    while !Task.isCancelled {
                        if !parent.isCurrent { operation.cancel(); return false }
                        var incoming=pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                        if poll(&incoming, 1, 100) > 0 {
                            guard let cancel=try? AuthorizationChannel.read(AuthorizationRequest.self, from: descriptor),
                                  cancel.id == request.id, cancel.sequence == request.sequence, cancel.operation == .cancelOperation, cancel.path.isEmpty,
                                  cancel.manifest == nil, cancel.budget == nil, cancel.action == nil, cancel.trashPath == nil,
                                  cancel.rules == nil, cancel.fullDiskAccess == nil, cancel.document == nil, cancel.text == nil,
                                  cancel.logInspection == nil, cancel.toolID == nil else { operation.cancel(); return false }
                            operation.cancel()
                        }
                    }
                    return true
                }
                let result=await operation.value
                if result.storage != nil, let path=result.path { transfers.append(path) }
                lifetime.cancel()
                guard await lifetime.value, parent.isCurrent else { return 0 }
                try AuthorizationChannel.write(result, to: descriptor)
                completedRequest=request.id
            }
            return 0
        } catch {
            Logger(subsystem: "dev.limecloud.shou", category: "authorization").error("Administrator worker failed at \(stage, privacy: .public)")
            return 77
        }
        #else
        return 77
        #endif
    }

    #if os(macOS)
    static func validateApplicationPath(_ path: String, roots: [String], requireExisting: Bool = true, verifyFilesystem: Bool = true) throws {
        let components=try SecurePaths.components(path)
        guard path == "/" + components.joined(separator: "/"), path.rangeOfCharacter(from: .controlCharacters) == nil,
              components.last?.lowercased().hasSuffix(".app") == true,
              roots.contains(where: { root in
                  guard path.hasPrefix(root + "/") else { return false }
                  let relative=path.dropFirst(root.count + 1).split(separator: "/")
                  return relative.count <= ApplicationCatalogOptions.maxContainerDepth + 1 && !relative.dropLast().contains { $0.lowercased().hasSuffix(".app") }
              }) else { throw ShouError("permission_denied", "The authorized application operation is outside supported installation directories.") }
        // Clients may check lexical scope without the privilege required to
        // traverse it. The worker always checks the actual no-follow path.
        if !verifyFilesystem { return }
        let inspected=requireExisting ? path : URL(fileURLWithPath: path).deletingLastPathComponent().path
        let descriptor=try SecurePaths.directory(inspected, readFinalDirectory: false)
        close(descriptor)
    }
    private static func perform(_ request: AuthorizationRequest, descriptor: Int32, roots: [String], home: String, uid: UInt32, executable: String) throws -> AuthorizationReply {
        if Task.isCancelled { throw ShouError("cancelled", "The authorized system operation stopped.") }
        if [.configurationRead, .configurationSave, .logRead, .logInspect, .logClear].contains(request.operation) {
            return try NativeAuthorizedConfiguration.perform(request, home: home, uid: uid)
        }
        guard request.document == nil, request.text == nil, request.logInspection == nil, request.toolID == nil else { throw AuthorizationChannel.failure() }
        if [.pathIdentity, .inspectPath, .inspectCleanupPath, .measureStoragePath, .purgePath, .trashPath, .restorePath, .purgeTrashPath].contains(request.operation) {
            return try NativeAuthorizedFileSystem.perform(request, descriptor: descriptor, home: home, uid: uid)
        }
        guard request.rules == nil, request.fullDiskAccess == nil else { throw AuthorizationChannel.failure() }
        if request.operation == .startupToggle {
            guard let action=request.action, request.manifest == nil, request.budget == nil, request.trashPath == nil else { throw AuthorizationChannel.failure() }
            _ = try StartupSystemDaemonAuthorization.script(action: action, label: request.path)
            let output=try NativeStartupCommand.run([action.rawValue, "system/" + request.path], deadline: .now.advanced(by: .seconds(5)))
            return AuthorizationReply(id: request.id, command: output)
        }
        if request.operation == .applicationCatalog {
            guard roots.contains(request.path), let budget=request.budget, request.manifest == nil,
                  request.action == nil, request.trashPath == nil else { throw AuthorizationChannel.failure() }
            let options=ApplicationCatalogOptions(maxEntries: budget.maxEntries, maxSeconds: budget.maxSeconds)
            try options.validate()
            let source=ApplicationSource(id: "authorized", path: request.path)
            let catalog=try NativeApplicationCatalog(sources: [source]).read(options: options)
            return AuthorizationReply(id: request.id, catalog: catalog)
        }
        let filesystem=NativeFileSystem(applicationRoots: roots, scanPrivacyPolicy: ScanPrivacyPolicy(status: .notRequired, home: home))
        if [.inspectApplicationShortcut, .purgeApplicationShortcut].contains(request.operation) {
            guard request.action == nil, request.budget == nil, request.trashPath == nil,
                  !executable.hasPrefix(request.path + "/") else { throw AuthorizationChannel.failure() }
            if request.operation == .inspectApplicationShortcut {
                guard request.manifest == nil else { throw AuthorizationChannel.failure() }
                return AuthorizationReply(id: request.id, applicationShortcut: try NativeApplicationShortcut.snapshot(request.path, roots: roots, uid: uid))
            }
            guard let manifest=request.manifest else { throw AuthorizationChannel.failure() }
            try NativeApplicationShortcut.remove(request.path, expected: manifest, roots: roots, uid: uid)
            return AuthorizationReply(id: request.id)
        }
        if request.operation == .applicationParentIdentity {
            guard request.manifest == nil, request.budget == nil, request.action == nil, request.trashPath == nil else { throw AuthorizationChannel.failure() }
            return AuthorizationReply(id: request.id, identity: try filesystem.applicationParentIdentity(request.path))
        }
        if request.operation == .purgeTrashedApplication {
            try NativeAuthorizedTrash.validate(request.path, home: home, uid: uid)
        } else { try validateApplicationPath(request.path, roots: roots, requireExisting: request.operation != .restoreApplication) }
        guard !executable.hasPrefix(request.path + "/"), request.action == nil else { throw ShouError("protected_content", "Shou cannot remove its running application.") }
        if request.operation == .applicationMetadata {
            guard request.manifest == nil, request.budget == nil, request.trashPath == nil else { throw AuthorizationChannel.failure() }
            let catalog=NativeApplicationCatalog(sources: roots.enumerated().map { ApplicationSource(id: "authorized.\($0.offset)", path: $0.element) })
            return AuthorizationReply(id: request.id, application: try catalog.application(at: request.path))
        }
        if request.operation == .applicationActivity {
            guard request.manifest == nil, request.budget == nil, request.trashPath == nil else { throw AuthorizationChannel.failure() }
            let catalog=NativeApplicationCatalog(sources: roots.enumerated().map { ApplicationSource(id: "authorized.\($0.offset)", path: $0.element) })
            let application=try catalog.application(at: request.path)
            return AuthorizationReply(id: request.id, applicationFacts: try NativeApplicationUninstallEvidence(currentUser: uid).facts(for: application))
        }
        if request.operation == .inspectApplication {
            guard request.manifest == nil, let budget=request.budget, request.trashPath == nil else { throw AuthorizationChannel.failure() }
            guard (1...1_000_000).contains(budget.maxEntries), budget.maxSeconds.isFinite,
                  (1...600).contains(budget.maxSeconds), (1...128).contains(budget.maxDepth) else { throw AuthorizationChannel.failure() }
            let snapshot=try filesystem.inspectTarget(request.path, budget: budget, cancelled: { Task.isCancelled })
            return AuthorizationReply(id: request.id, snapshot: snapshot)
        }
        guard let manifest=request.manifest, !manifest.isEmpty, manifest.count <= 1_000_000, request.budget == nil,
              manifest.first?.path == ".", manifest.first?.kind == "directory",
              Set(manifest.map(\.path)).count == manifest.count,
              manifest.allSatisfy({ entry in
                  (entry.owner == uid || entry.owner == 0) && entry.kind != "special" &&
                  (request.operation == .trashApplication || request.operation == .restoreApplication || entry.kind != "file" || entry.links == 1) &&
                  (entry.path == "." || (!entry.path.hasPrefix("/") && !entry.path.split(separator: "/").contains { $0 == "." || $0 == ".." }))
              }) else { throw ShouError("permission_denied", "The authorized removal requires an exact application manifest without foreign or shared content.") }
        if request.operation == .restoreApplication {
            guard let trashPath=request.trashPath else { throw AuthorizationChannel.failure() }
            try NativeAuthorizedTrash.validate(trashPath, home: home, uid: uid)
            try filesystem.restore(trashPath, to: request.path, expected: manifest)
            return AuthorizationReply(id: request.id)
        }
        guard request.trashPath == nil else { throw AuthorizationChannel.failure() }
        if request.operation != .purgeTrashedApplication {
            let catalog=NativeApplicationCatalog(sources: roots.enumerated().map { ApplicationSource(id: "authorized.\($0.offset)", path: $0.element) })
            let application=try catalog.application(at: request.path)
            let facts=try NativeApplicationUninstallEvidence(currentUser: uid).facts(for: application)
            guard !facts.running, !facts.currentApplication else { throw ShouError("application_running", "Quit the application and its helpers before uninstalling.") }
        }
        if request.operation == .trashApplication {
            let (path, snapshot)=try NativeAuthorizedTrash.move(request.path, manifest: manifest, home: home, uid: uid, filesystem: filesystem)
            return AuthorizationReply(id: request.id, snapshot: snapshot, path: path)
        }
        try filesystem.purge(request.path, expected: manifest, progress: { completed, total, path in
            try? AuthorizationChannel.write(AuthorizationReply(id: request.id, progress: true, completed: completed, total: total, path: path), to: descriptor)
        })
        return AuthorizationReply(id: request.id)
    }
    #endif
}
