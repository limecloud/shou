import Foundation
import ShouCore
import ShouPlatform

func applicationShortcutsRemoveOnlyVerifiedBrokenLinks() async throws {
    #if os(macOS)
    let fixture=try Fixture(), apps=fixture.workspace.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
    let link=apps.appendingPathComponent("Generated Shortcut.app"), target=fixture.workspace.appendingPathComponent("Absent.app")
    let sentinel=fixture.workspace.appendingPathComponent("keep.txt")
    try Data("unrelated generated data".utf8).write(to: sentinel)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let filesystem=NativeFileSystem(applicationRoots: [apps.path])
    let catalog=NativeApplicationCatalog(sources: [.init(id: "fixture.apps", path: apps.path)])
    // Unknown application activity cannot turn a missing link target into an app.
    let engine=ShouEngine(store: fixture.store, filesystem: filesystem, applicationCatalog: catalog, homeDirectory: fixture.workspace)
    let summaries=try await engine.applicationSummaries()
    try expect(summaries.items.first?.status == "shortcut")
    let review=try await engine.reviewApplication(path: link.path)
    try expect(review.components.count == 1 && review.components[0].kind == .shortcut && review.components[0].eligible)
    try expect(review.keepsAssociatedData && !review.components[0].requiresUserDataConsent)
    do {
        _ = try await engine.createUninstallPlan(reviewId: review.id, componentIds: review.components.map(\.id), action: "trash")
        throw CheckFailure(description: "A shortcut must not enter the application Trash flow.")
    } catch let error as ShouError { try expect(error.code == "permission_denied") }
    let plan=try await engine.createUninstallBatchPlan(selections: [.init(reviewId: review.id, componentIds: review.components.map(\.id))])
    let receipt=try await engine.executeUninstallBatch(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "generated-shortcut-test")
    try expect(receipt.state == "completed" && receipt.items.count == 1 && receipt.items[0].state == "purged")
    try expect(receipt.items[0].uninstallOrigin?.kind == .shortcut && !FileManager.default.fileExists(atPath: target.path))
    try expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
    try expect(try Data(contentsOf: sentinel) == Data("unrelated generated data".utf8))
    _ = try await engine.inspectHistory(executionId: receipt.id)
    do {
        _ = try await engine.executeUninstallBatch(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "generated-shortcut-replay")
        throw CheckFailure(description: "Shortcut confirmation must not replay.")
    } catch let error as ShouError { try expect(error.code == "already_executed") }
    #endif
}

func applicationShortcutsRejectReappearingTargetsAndReplacements() async throws {
    #if os(macOS)
    for change in ["target", "link", "directory"] {
        let fixture=try Fixture(), apps=fixture.workspace.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let link=apps.appendingPathComponent("Generated.app"), target=fixture.workspace.appendingPathComponent("Missing.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let filesystem=NativeFileSystem(applicationRoots: [apps.path])
        let catalog=NativeApplicationCatalog(sources: [.init(id: "fixture.apps", path: apps.path)])
        let engine=ShouEngine(store: fixture.store, filesystem: filesystem, applicationCatalog: catalog, homeDirectory: fixture.workspace)
        let review=try await engine.reviewApplication(path: link.path)
        let plan=try await engine.createUninstallPlan(reviewId: review.id, componentIds: review.components.map(\.id), action: "permanent")
        if change == "target" {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("newly installed generated app".utf8).write(to: target.appendingPathComponent("keep.txt"))
        } else {
            try FileManager.default.removeItem(at: link)
            if change == "link" { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.workspace.appendingPathComponent("OtherMissing.app")) }
            else { try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true) }
        }
        let receipt=try await engine.executeUninstall(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "generated-shortcut-race")
        try expect(receipt.items.allSatisfy { $0.state == "failed" } && receipt.state != "completed")
        try expect((try? FileManager.default.attributesOfItem(atPath: link.path)) != nil)
        if change == "target" {
            try expect(try Data(contentsOf: target.appendingPathComponent("keep.txt")) == Data("newly installed generated app".utf8))
            try expectThrows { try filesystem.applicationShortcut(link.path) }
        }
    }
    #endif
}

func nativeApplicationShortcutsRejectExpandedScopeAndForgedManifests() throws {
    #if os(macOS)
    let fixture=try Fixture(), apps=fixture.workspace.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
    let link=apps.appendingPathComponent("Generated.app"), target=fixture.workspace.appendingPathComponent("Absent.app")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let filesystem=NativeFileSystem(applicationRoots: [apps.path]), snapshot=try filesystem.applicationShortcut(link.path)
    var forged=snapshot.identity; forged.contentDigest=String(repeating: "0", count: 64)
    try expectThrows { try filesystem.purge(link.path, expected: [forged]) }
    try expectThrows { try filesystem.purge(link.path, expected: [snapshot.identity, snapshot.identity]) }
    let outside=fixture.workspace.appendingPathComponent("Outside.app")
    try FileManager.default.createSymbolicLink(at: outside, withDestinationURL: target)
    try expectThrows { try filesystem.applicationShortcut(outside.path) }
    try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("LinkedParent"), withDestinationURL: apps)
    try expectThrows { try filesystem.applicationShortcut(apps.appendingPathComponent("LinkedParent/Generated.app").path) }
    try expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    #endif
}
