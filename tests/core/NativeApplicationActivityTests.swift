import Foundation
import ShouCore
import ShouPlatform
#if os(macOS)
import Darwin

private struct NativeActivityFixture {
    let fixture: Fixture
    let application: ApplicationDefinition
    let catalog: NativeApplicationCatalog
    let helper: URL
    init() throws {
        fixture=try Fixture()
        let applications=fixture.workspace.appendingPathComponent("Applications")
        let app=applications.appendingPathComponent("Activity " + UUID().uuidString + ".app")
        helper=app.appendingPathComponent("Contents/Helpers/FixtureHelper")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/cat"), to: helper)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.shou.activity." + UUID().uuidString,
            "CFBundleName": "Generated Activity Fixture", "CFBundlePackageType": "APPL"], format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        catalog=NativeApplicationCatalog(sources: [ApplicationSource(id: "fixture.activity", path: applications.path)])
        application=try catalog.application(at: app.path)
    }
}

private func nativeActivityKernelStatus(_ pid: pid_t) throws -> Int {
    var info=kinfo_proc(), size=MemoryLayout<kinfo_proc>.stride
    var query=[Int32(CTL_KERN), Int32(KERN_PROC), Int32(KERN_PROC_PID), pid]
    let result=query.withUnsafeMutableBufferPointer {
        sysctl($0.baseAddress, UInt32($0.count), &info, &size, nil, 0)
    }
    try expect(result == 0 && size == MemoryLayout<kinfo_proc>.stride && info.kp_proc.p_pid == pid)
    return Int(info.kp_proc.p_stat)
}
#endif

func nativeApplicationActivitySkipsOnlyKernelVerifiedZombies() throws {
    #if os(macOS)
    let fixture=try NativeActivityFixture()
    let executable=try require(strdup("/usr/bin/true"))
    defer { free(executable) }
    var child: pid_t=0
    var arguments: [UnsafeMutablePointer<CChar>?]=[executable, nil]
    var environment: [UnsafeMutablePointer<CChar>?]=[nil]
    // Spawn directly so Foundation does not reap the child before inspection.
    let spawned=arguments.withUnsafeMutableBufferPointer { arguments in
        environment.withUnsafeMutableBufferPointer { environment in
            posix_spawn(&child, executable, nil, nil, arguments.baseAddress!, environment.baseAddress!)
        }
    }
    try expect(spawned == 0 && child > 0)
    defer {
        var status: Int32=0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
    }
    let deadline=ContinuousClock.now.advanced(by: .seconds(2))
    while try nativeActivityKernelStatus(child) != Int(SZOMB), ContinuousClock.now < deadline { usleep(1_000) }
    try expect(try nativeActivityKernelStatus(child) == Int(SZOMB))
    var buffer=[CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    errno=0
    let count=buffer.withUnsafeMutableBytes { proc_pidpath(child, $0.baseAddress, UInt32($0.count)) }
    try expect(count == 0 && errno == ESRCH && kill(child, 0) == 0)
    let facts=try NativeApplicationUninstallEvidence(homeDirectory: fixture.fixture.workspace).facts(for: fixture.application)
    try expect(!facts.running && !facts.currentApplication)
    try expect(try nativeActivityKernelStatus(child) == Int(SZOMB))
    #endif
}

func nativeApplicationActivityKeepsLiveHelpersBlocked() async throws {
    #if os(macOS)
    let fixture=try NativeActivityFixture(), input=Pipe(), process=Process()
    process.executableURL=fixture.helper
    process.standardInput=input
    process.standardOutput=FileHandle.nullDevice
    process.standardError=FileHandle.nullDevice
    try process.run()
    defer {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }
    try expect(process.isRunning)
    // Process.run may return before exec has installed the helper's image.
    // Establish that prerequisite before testing executable-path protection.
    let deadline=ContinuousClock.now.advanced(by: .seconds(3))
    var helperReady=false
    repeat {
        var path=[CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count=path.withUnsafeMutableBytes { proc_pidpath(process.processIdentifier, $0.baseAddress, UInt32($0.count)) }
        if count > 0 {
            let observed=String(decoding: path.prefix(Int(count)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            helperReady=URL(fileURLWithPath: observed).resolvingSymlinksInPath() == fixture.helper.resolvingSymlinksInPath()
        }
        if helperReady { break }
        try await Task.sleep(for: .milliseconds(10))
    } while process.isRunning && ContinuousClock.now < deadline
    try expect(helperReady && process.isRunning)
    let evidence=NativeApplicationUninstallEvidence(homeDirectory: fixture.fixture.workspace)
    try expect(try evidence.facts(for: fixture.application).running)
    let filesystem=NativeFileSystem(applicationRoots: [fixture.application.source.path])
    let engine=ShouEngine(store: fixture.fixture.store, filesystem: filesystem, applicationCatalog: fixture.catalog,
        uninstallEvidence: evidence, homeDirectory: fixture.fixture.workspace)
    let review=try await engine.reviewApplication(path: fixture.application.path)
    let component=try require(review.components.first { $0.kind == .application })
    try expect(!component.eligible && component.reasons.contains("application_running"))
    try await expectThrows { try await engine.createUninstallPlan(reviewId: review.id, componentIds: [component.id]) }
    try expect(try await engine.history().isEmpty)
    #endif
}
