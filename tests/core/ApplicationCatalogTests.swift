import Foundation
import ShouCore
import ShouPlatform
#if os(macOS)
import Darwin
#endif

private final class ApplicationReadCounter: @unchecked Sendable {
    private let lock=NSLock()
    private var count=0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
private struct ApplicationFixtureReader: ApplicationCatalogReading {
    let calls: ApplicationReadCounter
    func read(options: ApplicationCatalogOptions) throws -> ApplicationCatalog {
        calls.increment()
        return ApplicationCatalog(checkedAt: Date(), sources: [], items: [], issues: [])
    }
    func application(at path: String) throws -> ApplicationDefinition { throw ShouError("invalid_argument", "No application.") }
}

func applicationCatalogValidatesBeforeReadAndHonorsCancellation() async throws {
    let calls=ApplicationReadCounter(), service=ApplicationCatalogService(source: ApplicationFixtureReader(calls: calls))
    for options in [ApplicationCatalogOptions(maxEntries: 0), ApplicationCatalogOptions(maxEntries: 20_001), ApplicationCatalogOptions(maxSeconds: .nan), ApplicationCatalogOptions(maxSeconds: 31)] {
        try await expectThrows { try await service.scan(options: options) }
    }
    let cancelled=Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await service.scan()
    }
    do { _ = try await cancelled.value; throw CheckFailure(description: "Cancelled application discovery must not read.") }
    catch let error as ShouError { try expect(error.code == "cancelled") }
    try expect(calls.value == 0)
    let result=try await service.scan()
    try expect(calls.value == 1 && result.scope == "application_directories")
}

func nativeApplicationCatalogPreservesDistinctPathsAndBoundsItsScope() throws {
    #if os(macOS)
    let fixture=try Fixture()
    let user=fixture.workspace.appendingPathComponent("Applications"), system=fixture.workspace.appendingPathComponent("SystemApplications")
    let sources=[ApplicationSource(id: "fixture.user", path: user.path), ApplicationSource(id: "fixture.system", path: system.path, systemOwned: true)]
    func put(_ path: URL, binary: Bool = false) throws {
        try FileManager.default.createDirectory(at: path.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let values: [String: Any] = ["CFBundleIdentifier": "dev.shou.fixture", "CFBundleDisplayName": "收拾一下", "CFBundleShortVersionString": "1.2", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL", "Secret": "never-output-this-application-secret"]
        try PropertyListSerialization.data(fromPropertyList: values, format: binary ? .binary : .xml, options: 0).write(to: path.appendingPathComponent("Contents/Info.plist"))
    }
    let first=user.appendingPathComponent("First.app"), second=user.appendingPathComponent("Tools/Deep/Second.app"), apple=system.appendingPathComponent("System.app")
    try put(first); try put(second, binary: true); try put(apple)
    try put(first.appendingPathComponent("Contents/Helpers/Embedded.app"))
    let bytes=try Data(contentsOf: first.appendingPathComponent("Contents/Info.plist"))
    let reader=NativeApplicationCatalog(sources: sources)
    let report=try reader.read(options: ApplicationCatalogOptions())
    try expect(report.status == "complete" && report.items.count == 2 && report.sources.count == 1)
    try expect(Set(report.items.map(\.id)).count == 2 && Set(report.items.compactMap(\.bundleIdentifier)) == ["dev.shou.fixture"])
    try expect(report.items.allSatisfy { $0.name == "收拾一下" && $0.version == "1.2" && $0.infoDigest != nil })
    try expect(!String(decoding: Codec.encode(report), as: UTF8.self).contains("never-output-this-application-secret"))
    try expect(try reader.application(at: second.path) == report.items.first { $0.path == second.path })
    try expectThrows { try reader.application(at: first.appendingPathComponent("Contents/Helpers/Embedded.app").path) }
    try expectThrows { try reader.application(at: user.path + "/../Applications/First.app") }
    try expectThrows { try reader.application(at: fixture.workspace.appendingPathComponent("Outside.app").path) }
    let all=try reader.read(options: ApplicationCatalogOptions(includeSystem: true))
    try expect(all.items.count == 3 && all.sources.count == 2)
    let limited=try reader.read(options: ApplicationCatalogOptions(includeSystem: true, maxEntries: 1))
    try expect(limited.status == "partial" && limited.issues.contains { $0.code == "resource_limit" })
    try expect(limited.sources.last?.status == "not_scanned")
    try expect(try Data(contentsOf: first.appendingPathComponent("Contents/Info.plist")) == bytes)
    #else
    try expectThrows { try NativeApplicationCatalog().read(options: ApplicationCatalogOptions()) }
    #endif
}

func nativeApplicationCatalogRejectsUnsafeMetadataWithoutHidingCoverageGaps() throws {
    #if os(macOS)
    let fixture=try Fixture(), root=fixture.workspace.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let external=fixture.workspace.appendingPathComponent("external.plist")
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.shou.external"], format: .xml, options: 0).write(to: external)
    let original=try Data(contentsOf: external)
    for name in ["LinkedInfo", "FIFO", "Large", "Invalid", "BadIdentifier", "LinkedContents", "Unknown"] {
        let app=root.appendingPathComponent(name + ".app")
        if name == "Unknown" { try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true); continue }
        if name == "LinkedContents" {
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Contents"), withDestinationURL: fixture.workspace)
            continue
        }
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info=app.appendingPathComponent("Contents/Info.plist")
        switch name {
        case "LinkedInfo": try FileManager.default.createSymbolicLink(at: info, withDestinationURL: external)
        case "FIFO": try expect(mkfifo(info.path, 0o600) == 0)
        case "Large": try Data(repeating: 0, count: 262_145).write(to: info)
        case "Invalid": try Data("invalid".utf8).write(to: info)
        default: try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "../escape"], format: .binary, options: 0).write(to: info)
        }
    }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked.app"), withDestinationURL: root.appendingPathComponent("Unknown.app"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b/c/TooDeep.app"), withIntermediateDirectories: true)
    let reader=NativeApplicationCatalog(sources: [ApplicationSource(id: "fixture.apps", path: root.path)])
    let report=try reader.read(options: ApplicationCatalogOptions())
    try expect(report.status == "partial" && report.items.count == 7 && report.issues.count == 9)
    try expect(report.items.allSatisfy { $0.bundleIdentifier == nil && $0.infoDigest == nil })
    try expect(Set(report.issues.map(\.code)).isSuperset(of: ["linked_definition", "unsupported_definition", "definition_too_large", "invalid_application_metadata", "invalid_bundle_identifier", "unsupported_bundle", "linked_application", "depth_limit"]))
    try expect(try Data(contentsOf: external) == original)
    #endif
}
