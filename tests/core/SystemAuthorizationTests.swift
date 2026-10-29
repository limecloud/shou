import Foundation
import ShouCore
#if DEBUG && os(macOS)
@testable import ShouPlatform
import Darwin

func nativeSystemAuthorizationProtocolFixtures() async throws {
    // This read must work as a normal user for a root-owned process, just as
    // the GUI verifies its authenticated worker. No administrator prompt opens.
    let rootPeer=try AuthorizationPeer(pid: 1)
    try expect(rootPeer.uid == 0 && rootPeer.isCurrent && rootPeer.started > 0 && rootPeer.path == "/sbin/launchd")
    let caller=try AuthorizationPeer(pid: getpid())
    var callerInfo=proc_bsdinfo()
    try expect(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &callerInfo, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size)
    try expect(caller.uid == callerInfo.pbi_uid && caller.started == callerInfo.pbi_start_tvsec && caller.microseconds == callerInfo.pbi_start_tvusec)
    func sockets() throws -> (Int32, Int32) {
        var descriptors=[Int32](repeating: -1, count: 2)
        try expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        AuthorizationChannel.configure(descriptors[0]); AuthorizationChannel.configure(descriptors[1])
        return (descriptors[0], descriptors[1])
    }
    let (client, server)=try sockets()
    let authorization=NativeSystemAuthorization(authenticatedChannel: client, peer: try AuthorizationPeer(pid: getpid()))
    let responder=Task.detached {
        defer { close(server) }
        var requests=[String]()
        for index in 0..<4 {
            let request=try AuthorizationChannel.read(AuthorizationRequest.self, from: server)
            requests.append(request.id)
            if index == 3 { break }
            try AuthorizationChannel.write(AuthorizationReply(id: request.id), to: server)
        }
        return requests
    }
    try authorization.authorizeAdministrator()
    _ = try authorization.perform(.startupToggle, path: "dev.shou.generated", action: .disable)
    _ = try authorization.perform(.applicationCatalog, path: "/Applications", budget: .init())
    _ = try authorization.perform(.inspectApplication, path: "/Applications/Generated.app", budget: .init())
    try expect(authorization.administratorState == .authorized)
    do {
        _ = try authorization.perform(.purgeApplication, path: "/Applications/Generated.app", manifest: [])
        throw CheckFailure(description: "Lost replies must not authorize replay.")
    } catch let error as ShouError { try expect(error.code == "authorization_channel_lost") }
    try expect(authorization.administratorState == .unavailable)
    let requests=try await responder.value
    try expect(requests.count == 4 && Set(requests).count == 4)
    try expect(ShouError("authorization_cancelled", "Cancelled").exitCode == 130)
    try expect(ShouError("authorization_denied", "Denied").exitCode == 3)

    let (reader, writer)=try sockets()
    defer { close(reader); close(writer) }
    var oversized=UInt32(64 * 1024 * 1024 + 1).bigEndian
    _ = withUnsafeBytes(of: &oversized) { send(writer, $0.baseAddress, $0.count, 0) }
    try expectThrows { try AuthorizationChannel.read(AuthorizationRequest.self, from: reader) }
    let (wrongClient, wrongServer)=try sockets()
    let wrong=NativeSystemAuthorization(authenticatedChannel: wrongClient, peer: try AuthorizationPeer(pid: getpid()))
    let wrongReply=Task.detached {
        defer { close(wrongServer) }
        _ = try AuthorizationChannel.read(AuthorizationRequest.self, from: wrongServer)
        try AuthorizationChannel.write(AuthorizationReply(id: "wrong-request"), to: wrongServer)
    }
    try expectThrows { try wrong.perform(.startupToggle, path: "dev.shou.generated", action: .disable) }
    try await wrongReply.value
    let malformed=await NativeSystemAuthorizationWorker.runIfRequested(["--system-authorization-worker-v0"])
    let ordinary=await NativeSystemAuthorizationWorker.runIfRequested(["applications", "list"])
    try expect(malformed == 77 && ordinary == nil)
    for path in ["/tmp/Example.app", "/Applications/../Example.app", "/Applications/Outer.app/Contents/Inner.app", "/Applications/Example.txt"] {
        try expectThrows { try NativeSystemAuthorizationWorker.validateApplicationPath(path, roots: ["/Applications"]) }
    }
    let peer=try AuthorizationPeer(pid: getpid())
    try expect(peer.isCurrent && peer.uid == getuid())
    try nativeAuthorizedTrashStagesAndRestoresOnlyGeneratedFixtures()
    try nativeAuthorizedFilesPreserveScopeAndTransferOnlyGeneratedIndexes()
}

private func nativeAuthorizedFilesPreserveScopeAndTransferOnlyGeneratedIndexes() throws {
    let fixture=try Fixture(), home=fixture.workspace.path
    let filesystem=NativeFileSystem(scanPrivacyPolicy:ScanPrivacyPolicy(status:.notRequired,home:home))
    try fixture.put("generated/data.bin","generated payload")
    let target=home + "/generated"
    let tree=try filesystem.inspectStorageTarget(target,budget:.init(),cancelled:{ false })
    try NativeAuthorizedFileSystem.validateMutation(target,manifest:tree.entries,home:home,uid:getuid())
    for path in [home,home + "/.ssh/keys",home + "/Library/CloudStorage/file","/Applications/Generated.app","/private/etc/generated.conf","/Users/another-account/private"] {
        try expectThrows { try NativeAuthorizedFileSystem.validateMutation(path,manifest:tree.entries,home:home,uid:getuid(),requireExisting:false) }
    }
    try expectThrows { try NativeAuthorizedFileSystem.validateMutation(target,manifest:[],home:home,uid:getuid()) }
    var forged=tree.entries; forged.append(tree.entries[0])
    try expectThrows { try NativeAuthorizedFileSystem.validateMutation(target,manifest:forged,home:home,uid:getuid()) }
    try FileManager.default.createDirectory(atPath:home + "/.Trash",withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    // Generic directory and regular-file moves use the same staging and rollback boundary as apps.
    for path in [target,home + "/plain.dat"] {
        if path.hasSuffix(".dat") { try Data("generated regular file".utf8).write(to:URL(fileURLWithPath:path)) }
        let before=try filesystem.inspectStorageTarget(path,budget:.init(),cancelled:{ false })
        let (destination,moved)=try NativeAuthorizedTrash.move(path,manifest:before.entries,home:home,uid:getuid(),filesystem:filesystem,applicationOnly:false)
        try NativeAuthorizedFileSystem.validateMutation(destination,manifest:moved.entries,home:home,uid:getuid(),privateTrash:true)
        try expect(FileManifestVerification.matches(moved.entries,before.entries,allowingTrashRootChanges:true))
        try filesystem.restore(destination,to:path,expected:moved.entries)
        try expect(FileManager.default.fileExists(atPath:path))
    }
    let (source,measurement)=try NativeAuthorizedFileSystem.exportStorage(target,filesystem:filesystem,uid:getuid(),progress:{ _ in })
    let output=fixture.base.appendingPathComponent("imported.sqlite")
    try NativeAuthorizedFileSystem.importStorage(source,to:output,uid:getuid())
    try expect(measurement.entryCount > 0 && FileManager.default.fileExists(atPath:output.path))
    try expect(!FileManager.default.fileExists(atPath:source))
    try expectThrows { try NativeAuthorizedFileSystem.importStorage(output.path,to:fixture.base.appendingPathComponent("forged.sqlite"),uid:getuid()) }
    let (failedSource,_)=try NativeAuthorizedFileSystem.exportStorage(target,filesystem:filesystem,uid:getuid(),progress:{ _ in })
    try expectThrows { try NativeAuthorizedFileSystem.importStorage(failedSource,to:output,uid:getuid()) }
    try expect(!FileManager.default.fileExists(atPath:failedSource))
    try expect(NativeAuthorizedConfiguration.supports(home + "/nginx.conf",configuration:true,home:home))
    try expect(!NativeAuthorizedConfiguration.supports(home + "/.ssh/key.conf",configuration:true,home:home))
    try expect(!NativeAuthorizedConfiguration.supports("/private/etc/sudoers.conf",configuration:true,home:home))
}

private func nativeAuthorizedTrashStagesAndRestoresOnlyGeneratedFixtures() throws {
    let fixture=try Fixture()
    let home=fixture.workspace.path, apps=fixture.workspace.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
    let trash=fixture.workspace.appendingPathComponent(".Trash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let app=apps.appendingPathComponent("Generated.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
    let payload=app.appendingPathComponent("generated.bin")
    try Data("generated original".utf8).write(to: payload)
    let filesystem=NativeFileSystem(applicationRoots: [apps.path], scanPrivacyPolicy: ScanPrivacyPolicy(status: .notRequired, home: home))
    let original=try filesystem.inspectTarget(app.path, budget: .init(), cancelled: { false })
    let (destination, moved)=try NativeAuthorizedTrash.move(app.path, manifest: original.entries, home: home, uid: getuid(), filesystem: filesystem)
    try expect(!FileManager.default.fileExists(atPath: app.path) && moved.complete)
    try expect(FileManifestVerification.matches(moved.entries, original.entries, allowingTrashRootChanges: true))
    try filesystem.restore(destination, to: app.path, expected: moved.entries)
    try expect(try Data(contentsOf: payload) == Data("generated original".utf8))
    let fresh=try filesystem.inspectTarget(app.path, budget: .init(), cancelled: { false })
    try Data("changed generated descendant".utf8).write(to: payload)
    try expectThrows { try NativeAuthorizedTrash.move(app.path, manifest: fresh.entries, home: home, uid: getuid(), filesystem: filesystem) }
    try expect(FileManager.default.fileExists(atPath: app.path))
    try expect(try Data(contentsOf: payload) == Data("changed generated descendant".utf8))
    try expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
    try expectThrows { try NativeAuthorizedTrash.validate(home + "/generated.app", home: home, uid: getuid()) }
}
#endif
