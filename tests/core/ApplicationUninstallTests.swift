import Foundation
import ShouCore
import ShouPlatform
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private final class UninstallFixtureEvidence: ApplicationUninstallChecking, @unchecked Sendable {
    private let lock=NSLock()
    private let currentUser: UInt32
    private var active=false
    private var activityUnavailable=false
    private var verifiedGroupPaths: [String]=[]
    init(currentUser: UInt32 = getuid()) { self.currentUser=currentUser }
    func setRunning(_ value: Bool) { lock.lock(); defer { lock.unlock() }; active=value }
    func setUnavailable(_ value: Bool) { lock.lock(); defer { lock.unlock() }; activityUnavailable=value }
    func setVerifiedGroupPaths(_ paths: [String]) { lock.lock(); defer { lock.unlock() }; verifiedGroupPaths=paths }
    func facts(for application: ApplicationDefinition) throws -> ApplicationUninstallFacts {
        lock.lock(); defer { lock.unlock() }
        if activityUnavailable { throw ShouError("application_activity_unavailable", "Generated activity is unavailable.") }
        return ApplicationUninstallFacts(currentUser: currentUser, running: active, currentApplication: false)
    }
    func containerIdentifier(at path: String) throws -> String { "dev.shou.fixture.uninstall" }
    func groupContainerPaths(for bundleIdentifier: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return bundleIdentifier == "dev.shou.fixture.uninstall" ? verifiedGroupPaths : []
    }
}

private struct UninstallFixture {
    let fixture: Fixture
    let engine: ShouEngine
    let app: URL
    let evidence: UninstallFixtureEvidence
    let catalog: NativeApplicationCatalog
    init(nativeTrash: Bool = false, includeGroupContainer: Bool = false) throws {
        fixture=try Fixture(); evidence=UninstallFixtureEvidence()
        let applications=fixture.workspace.appendingPathComponent("Applications")
        app=applications.appendingPathComponent("Shou Generated Uninstall " + UUID().uuidString + ".app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.shou.fixture.uninstall", "CFBundleName": "Generated Uninstall Fixture", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"], format: .binary, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("generated inert application payload".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Fixture"))
        for path in ["Library/Caches/dev.shou.fixture.uninstall/cache.bin", "Library/Logs/dev.shou.fixture.uninstall/log.txt", "Library/Preferences/dev.shou.fixture.uninstall.plist", "Library/Application Support/dev.shou.fixture.uninstall/database.bin"] {
            try fixture.put(path, "generated component " + path)
        }
        try fixture.put("Library/Group Containers/dev.shou.fixture.uninstall/shared.bin", "Shared data must survive.")
        if includeGroupContainer { evidence.setVerifiedGroupPaths([fixture.workspace.appendingPathComponent("Library/Group Containers/dev.shou.fixture.uninstall").path]) }
        try fixture.put("Library/Application Support/Unrelated/personal.bin", "Unrelated personal data must survive.")
        catalog=NativeApplicationCatalog(sources: [ApplicationSource(id: "fixture.apps", path: applications.path)])
        let filesystem=NativeFileSystem(applicationRoots: [applications.path])
        engine=ShouEngine(store: fixture.store, filesystem: nativeTrash ? filesystem : FixtureFileSystem(native: filesystem, trash: fixture.trash),
            applicationCatalog: catalog, uninstallEvidence: evidence, homeDirectory: fixture.workspace)
    }
    func hashes() throws -> [String: String] {
        var result: [String: String]=[:]
        let iterator=try require(FileManager.default.enumerator(at: fixture.workspace, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in iterator where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(file.path.dropFirst(fixture.workspace.path.count + 1))]=Digest.sha256(try Data(contentsOf: file))
        }
        return result
    }
    func addApplication(name: String = "Second", identifier: String = "dev.shou.fixture.second") throws -> URL {
        let second=app.deletingLastPathComponent().appendingPathComponent(name + ".app")
        try FileManager.default.createDirectory(at: second.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleName": name,
            "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"], format: .binary, options: 0).write(to: second.appendingPathComponent("Contents/Info.plist"))
        try Data("generated second inert application".utf8).write(to: second.appendingPathComponent("Contents/MacOS/Fixture"))
        try fixture.put("Library/Caches/" + identifier + "/cache.bin", "second generated cache")
        try fixture.put("Library/Preferences/" + identifier + ".plist", "second generated preference")
        return second
    }
}

func uninstallActivityFailuresKeepTheirCauseAndAllowRetryWithoutMutation() async throws {
    for code in ["application_running", "application_activity_unavailable"] {
        let fixture=try UninstallFixture(), before=try fixture.hashes()
        let review=try await fixture.engine.reviewApplication(path: fixture.app.path)
        let ids=review.components.filter { $0.eligible && !$0.requiresUserDataConsent }.map(\.id)
        let plan=try await fixture.engine.createUninstallBatchPlan(selections: [ApplicationUninstallSelection(reviewId: review.id, componentIds: ids)], action: "trash")
        fixture.evidence.setRunning(code == "application_running")
        fixture.evidence.setUnavailable(code == "application_activity_unavailable")
        do {
            _ = try await fixture.engine.executeUninstallBatch(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "generated-activity-failure")
            throw CheckFailure(description: "Application activity failure was not rejected.")
        } catch let error as ShouError { try expect(error.code == code) }
        let history=try await fixture.engine.history()
        try expect(try fixture.hashes() == before && history.isEmpty)
        try expect(try await fixture.engine.uninstallBatchPlan(plan.id).executionId == nil)
        fixture.evidence.setRunning(false); fixture.evidence.setUnavailable(false)
        let receipt=try await fixture.engine.executeUninstallBatch(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "generated-activity-retry")
        try expect(receipt.state == "completed" && receipt.items.allSatisfy { $0.state == "trashed" })
        let itemIds=receipt.items.map(\.id)
        let digest=try await fixture.engine.followUpDigest(executionId: receipt.id, itemIds: itemIds, action: "restore")
        _ = try await fixture.engine.followUp(executionId: receipt.id, itemIds: itemIds, action: "restore", confirmedDigest: digest)
        try expect(try fixture.hashes() == before)
    }
}

func uninstallBatchUsesOneReceiptAndRestoresTwoApplications() async throws {
    let fixture=try UninstallFixture(), second=try fixture.addApplication(), before=try fixture.hashes()
    var selections=[ApplicationUninstallSelection]()
    for path in [fixture.app.path, second.path] {
        let review=try await fixture.engine.reviewApplication(path: path)
        selections.append(ApplicationUninstallSelection(reviewId: review.id, componentIds: review.components.filter(\.eligible).map(\.id), includeUserData: true))
    }
    let plan=try await fixture.engine.createUninstallBatchPlan(selections: selections, action: "trash")
    try expect(plan.plans.count == 2 && plan.action == "trash" && plan.allocatedBytesEstimate > 0)
    try expect(try await fixture.engine.uninstallBatchPlan(plan.id).digest == plan.digest)
    try await expectThrows { try await fixture.engine.executeUninstallBatch(planId: plan.id, confirmedDigest: "wrong", entryPoint: "test") }
    let receipt=try await fixture.engine.executeUninstallBatch(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "batch-generated-fixture")
    try expect(receipt.state == "completed" && receipt.operation == "application_batch_uninstall")
    try expect(receipt.items.count == plan.plans.reduce(0) { $0 + $1.components.count })
    try expect(receipt.items.allSatisfy { $0.state == "trashed" && $0.uninstallOrigin != nil })
    try expect(try await fixture.engine.history().count == 1)
    try await expectThrows { try await fixture.engine.executeUninstallBatch(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
    let inspection=try await fixture.engine.inspectHistory(executionId: receipt.id)
    try expect(inspection.items.allSatisfy { $0.state == "verified_trash" })
    let ids=receipt.items.map(\.id)
    try await expectThrows { try await fixture.engine.followUpDigest(executionId: receipt.id, itemIds: ids, action: "purge") }
    let digest=try await fixture.engine.followUpDigest(executionId: receipt.id, itemIds: ids, action: "restore")
    let restored=try await fixture.engine.followUp(executionId: receipt.id, itemIds: ids, action: "restore", confirmedDigest: digest)
    try expect(restored.allSatisfy { $0.state == "completed" } && restored.count == ids.count)
    try expect(try fixture.hashes() == before)
}

func uninstallBatchDefaultPermanentCannotRestoreAndSingleTrashRemainsCompatible() async throws {
    let fixture=try UninstallFixture(), second=try fixture.addApplication()
    var selections=[ApplicationUninstallSelection]()
    for path in [fixture.app.path, second.path] {
        let review=try await fixture.engine.reviewApplication(path: path)
        selections.append(ApplicationUninstallSelection(reviewId: review.id,
            componentIds: review.components.filter { $0.eligible && !$0.requiresUserDataConsent }.map(\.id)))
    }
    let plan=try await fixture.engine.createUninstallBatchPlan(selections: selections)
    try expect(plan.action == "permanent" && plan.plans.allSatisfy { $0.effectiveAction == "permanent" })
    let receipt=try await fixture.engine.executeUninstallBatch(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "permanent-generated-fixture")
    try expect(receipt.state == "completed" && receipt.operation == "application_batch_permanent_uninstall")
    try expect(receipt.items.allSatisfy { $0.state == "purged" && $0.trashPath == nil && !FileManager.default.fileExists(atPath: $0.originalPath) })
    let inspected=try await fixture.engine.inspectHistory(executionId: receipt.id)
    try expect(inspected.items.allSatisfy { $0.state == "purged" })
    try await expectThrows { try await fixture.engine.followUpDigest(executionId: receipt.id, itemIds: receipt.items.map(\.id), action: "restore") }
    try expect(FileManager.default.fileExists(atPath: fixture.fixture.workspace.appendingPathComponent("Library/Preferences/dev.shou.fixture.uninstall.plist").path))
    let legacy=try UninstallFixture()
    let review=try await legacy.engine.reviewApplication(path: legacy.app.path)
    let single=try await legacy.engine.createUninstallPlan(reviewId: review.id, componentIds: review.components.filter { $0.eligible && !$0.requiresUserDataConsent }.map(\.id))
    try expect(single.action == nil && single.effectiveAction == "trash")
    try expect(!String(decoding: Codec.encode(single), as: UTF8.self).contains("\"action\""))
    let loaded=try Codec.decode(ApplicationUninstallPlan.self, from: Codec.encode(single))
    try expect(loaded.effectiveAction == "trash" && loaded.digest == loaded.calculatedDigest())
}

func uninstallBatchPreflightsAllAppsAndRejectsConsentRunningStaleAndOverlaps() async throws {
    for change in ["consent", "running", "stale", "duplicate", "overlap", "forged-consent"] {
        let fixture=try UninstallFixture(), second=try fixture.addApplication(), before=try fixture.hashes()
        var selections=[ApplicationUninstallSelection]()
        for path in [fixture.app.path, second.path] {
            let review=try await fixture.engine.reviewApplication(path: path)
            selections.append(ApplicationUninstallSelection(reviewId: review.id, componentIds: review.components.filter(\.eligible).map(\.id), includeUserData: change != "consent"))
        }
        if change == "consent" || change == "duplicate" {
            try await expectThrows { try await fixture.engine.createUninstallBatchPlan(selections: change == "duplicate" ? [selections[0], selections[0]] : selections) }
        } else {
            var plan=try await fixture.engine.createUninstallBatchPlan(selections: selections)
            if change == "running" { fixture.evidence.setRunning(true) }
            if change == "stale" { try Data("changed second app before batch".utf8).write(to: second.appendingPathComponent("Contents/MacOS/Fixture")) }
            if ["overlap", "forged-consent"].contains(change) {
                var object=try require(JSONSerialization.jsonObject(with: Codec.encode(plan)) as? [String: Any])
                var nested=try require(object["plans"] as? [[String: Any]])
                if change == "overlap" {
                    var secondComponents=try require(nested[1]["components"] as? [[String: Any]])
                    secondComponents[0]["path"]=plan.plans[0].components[0].path
                    nested[1]["components"]=secondComponents
                } else { nested[1]["includes_user_data"]=false }
                object["plans"]=nested
                plan=try Codec.decode(ApplicationUninstallBatchPlan.self, from: JSONSerialization.data(withJSONObject: object))
                plan.digest=try plan.calculatedDigest()
                try fixture.fixture.store.write("uninstall-batch-plans", id: plan.id, data: Codec.encode(plan))
            }
            try await expectThrows { try await fixture.engine.executeUninstallBatch(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
        }
        try expect(FileManager.default.fileExists(atPath: fixture.app.path) && FileManager.default.fileExists(atPath: second.path))
        try expect(try await fixture.engine.history().isEmpty)
        if change != "stale" { try expect(try fixture.hashes() == before) }
    }
}

func uninstallPermanentRechecksActivityAtJournalBoundary() async throws {
    let fixture=try UninstallFixture(), before=try fixture.hashes()
    let review=try await fixture.engine.reviewApplication(path: fixture.app.path)
    let selected=review.components.filter { $0.eligible && !$0.requiresUserDataConsent }
    let plan=try await fixture.engine.createUninstallPlan(reviewId: review.id, componentIds: selected.map(\.id), action: "permanent")
    let evidence=fixture.evidence
    let receipt=try await fixture.engine.executeUninstall(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test", progress: { update in
        if update.stage == "checking", update.processedCount == 0 { evidence.setRunning(true) }
    })
    try expect(receipt.operation == "application_permanent_uninstall" && receipt.state == "partial" && receipt.items.first?.state == "failed")
    try expect(try fixture.hashes() == before)
}

func uninstallReviewIncludesOnlyVerifiedGroupContainers() async throws {
    let fixture=try UninstallFixture(includeGroupContainer: true), before=try fixture.hashes()
    let review=try await fixture.engine.reviewApplication(path: fixture.app.path)
    let group=try require(review.components.first { $0.kind == .groupContainer })
    try expect(group.eligible && group.requiresUserDataConsent && group.path.hasSuffix("Library/Group Containers/dev.shou.fixture.uninstall"))
    let selected=review.components.filter(\.eligible)
    let plan=try await fixture.engine.createUninstallPlan(reviewId: review.id, componentIds: selected.map(\.id), includeUserData: true)
    try expect(plan.components.contains { $0.kind == .groupContainer })
    let receipt=try await fixture.engine.executeUninstall(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "group-container-fixture")
    try expect(receipt.state == "completed" && receipt.items.contains { $0.uninstallOrigin?.kind == .groupContainer })
    let digest=try await fixture.engine.followUpDigest(executionId: receipt.id, itemIds: receipt.items.map(\.id), action: "restore")
    _=try await fixture.engine.followUp(executionId: receipt.id, itemIds: receipt.items.map(\.id), action: "restore", confirmedDigest: digest)
    try expect(try fixture.hashes() == before)
}

func uninstallReviewSeparatesPersonalDataAndDoesNotModifyFiles() async throws {
    let fixture=try UninstallFixture(), before=try fixture.hashes()
    try expect(try Digest.of(await fixture.engine.configuration()) == Digest.of(await fixture.engine.configuration()))
    let review=try await fixture.engine.reviewApplication(path: fixture.app.path)
    try expect(review.components.count == 9)
    try expect(review.components.filter(\.eligible).count == 5)
    try expect(review.components.first { $0.kind == .preferences }?.manifest.first?.contentDigest != nil)
    try expect(review.components.first { $0.kind == .caches }?.requiresUserDataConsent == false)
    try expect(review.components.first { $0.kind == .applicationSupport }?.requiresUserDataConsent == true)
    let ids=review.components.filter(\.eligible).map(\.id)
    try await expectThrows { try await fixture.engine.createUninstallPlan(reviewId: review.id, componentIds: ids) }
    let plan=try await fixture.engine.createUninstallPlan(reviewId: review.id, componentIds: ids, includeUserData: true)
    try expect(plan.includesUserData && plan.components.last?.kind == .application)
    try expect(plan.components.count == 5 && plan.allocatedBytesEstimate > 0)
    try expect(try fixture.hashes() == before)
    try expect(try await fixture.engine.history().isEmpty)
    try expect(try FileManager.default.contentsOfDirectory(atPath: fixture.fixture.trash.path).isEmpty)
}

func uninstallCompleteLoopRestoresIndependentComponentOrigins(nativeTrash: Bool = false) async throws {
    let fixture=try UninstallFixture(nativeTrash: nativeTrash), before=try fixture.hashes()
    let review=try await fixture.engine.reviewApplication(path: fixture.app.path)
    let selected=review.components.filter(\.eligible)
    let plan=try await fixture.engine.createUninstallPlan(reviewId: review.id, componentIds: selected.map(\.id), includeUserData: true)
    try await expectThrows { try await fixture.engine.executeUninstall(planId: plan.id, confirmedDigest: "wrong", entryPoint: "test") }
    let receipt=try await fixture.engine.executeUninstall(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "uninstall-fixture")
    try expect(receipt.operation == "application_uninstall" && receipt.state == "completed" && receipt.items.count == 5)
    try expect(receipt.items.allSatisfy { $0.state == "trashed" && $0.uninstallOrigin != nil && !FileManager.default.fileExists(atPath: $0.originalPath) })
    try await expectThrows { try await fixture.engine.executeUninstall(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
    let inspection=try await fixture.engine.inspectHistory(executionId: receipt.id)
    try expect(inspection.status == "complete" && inspection.items.allSatisfy { $0.state == "verified_trash" })
    try await expectThrows { try await fixture.engine.followUpDigest(executionId: receipt.id, itemIds: receipt.items.map(\.id), action: "purge") }
    // Use a fresh engine instance to exercise persisted receipt origins.
    let filesystem=NativeFileSystem(applicationRoots: [fixture.app.deletingLastPathComponent().path])
    let independent=ShouEngine(store: try LocalRecordStore(directory: fixture.fixture.store.directory), filesystem: nativeTrash ? filesystem : FixtureFileSystem(native: filesystem, trash: fixture.fixture.trash), homeDirectory: fixture.fixture.workspace)
    let digest=try await independent.followUpDigest(executionId: receipt.id, itemIds: receipt.items.map(\.id), action: "restore")
    let restored=try await independent.followUp(executionId: receipt.id, itemIds: receipt.items.map(\.id), action: "restore", confirmedDigest: digest)
    try expect(restored.count == 5 && restored.allSatisfy { $0.state == "completed" })
    try expect(try fixture.hashes() == before)
    let final=try await independent.inspectHistory(executionId: receipt.id)
    try expect(final.status == "complete" && final.items.allSatisfy { $0.state == "restored" })
}

func uninstallRefusesChangedEvidenceRunningApplicationsAndExcludedData() async throws {
    for change in ["contents", "running", "duplicate", "configuration", "tampered-plan"] {
        let fixture=try UninstallFixture()
        let review=try await fixture.engine.reviewApplication(path: fixture.app.path)
        let selected=review.components.filter { $0.eligible && !$0.requiresUserDataConsent }
        var plan=try await fixture.engine.createUninstallPlan(reviewId: review.id, componentIds: selected.map(\.id))
        switch change {
        case "contents": try fixture.fixture.put("Library/Caches/dev.shou.fixture.uninstall/cache.bin", "changed evidence")
        case "running": fixture.evidence.setRunning(true)
        case "duplicate": try FileManager.default.copyItem(at: fixture.app, to: fixture.app.deletingLastPathComponent().appendingPathComponent("Duplicate.app"))
        case "configuration": _ = try await fixture.engine.setGlobalExclusion(pattern: "**/dev.shou.fixture.uninstall/**", remove: false)
        default:
            var object=try require(JSONSerialization.jsonObject(with: Codec.encode(plan)) as? [String: Any])
            var components=try require(object["components"] as? [[String: Any]])
            components[0]["path"]=fixture.fixture.workspace.appendingPathComponent("project").path
            object["components"]=components
            plan=try Codec.decode(ApplicationUninstallPlan.self, from: JSONSerialization.data(withJSONObject: object))
            plan.digest=try plan.calculatedDigest()
            try fixture.fixture.store.write("uninstall-plans", id: plan.id, data: Codec.encode(plan))
        }
        try await expectThrows { try await fixture.engine.executeUninstall(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
        try expect(FileManager.default.fileExists(atPath: fixture.app.path))
        try expect(try await fixture.engine.history().isEmpty)
        try expect(try FileManager.default.contentsOfDirectory(atPath: fixture.fixture.trash.path).isEmpty)
    }
    let fixture=try UninstallFixture()
    _ = try await fixture.engine.setGlobalExclusion(pattern: "**/dev.shou.fixture.uninstall/**", remove: false)
    let protected=try await fixture.engine.reviewApplication(path: fixture.app.path)
    try expect(protected.components.first { $0.kind == .caches }?.reasons.contains("excluded_descendant") == true)
    try expect(protected.components.first { $0.kind == .caches }?.eligible == false)
}

func uninstallRechecksActivityAtTheJournalBoundary() async throws {
    let fixture=try UninstallFixture()
    let review=try await fixture.engine.reviewApplication(path: fixture.app.path)
    let plan=try await fixture.engine.createUninstallPlan(reviewId: review.id, componentIds: review.components.filter { $0.eligible && !$0.requiresUserDataConsent }.map(\.id))
    let evidence=fixture.evidence
    let receipt=try await fixture.engine.executeUninstall(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test", progress: { update in
        if update.stage == "moving" && update.processedCount == 0 { evidence.setRunning(true) }
    })
    try expect(receipt.state == "partial" && receipt.items.first?.state == "failed")
    try expect(receipt.items.allSatisfy { $0.trashPath == nil && FileManager.default.fileExists(atPath: $0.originalPath) })
}

func uninstallCoverageGapsRequireExplicitChoicesAndConsentCannotBeForged() async throws {
    let fixture=try UninstallFixture()
    try FileManager.default.createDirectory(at: fixture.app.deletingLastPathComponent().appendingPathComponent("Unsupported.app"), withIntermediateDirectories: true)
    let review=try await fixture.engine.reviewApplication(path: fixture.app.path)
    let cache=try require(review.components.first { $0.kind == .caches })
    try expect(cache.eligible && cache.warnings == ["ownership_coverage_incomplete"])
    let selected=review.components.filter(\.eligible)
    var plan=try await fixture.engine.createUninstallPlan(reviewId: review.id, componentIds: selected.map(\.id), includeUserData: true)
    var object=try require(JSONSerialization.jsonObject(with: Codec.encode(plan)) as? [String: Any])
    var components=try require(object["components"] as? [[String: Any]])
    object["includes_user_data"]=false
    for index in components.indices { components[index]["requires_user_data_consent"]=false }
    object["components"]=components
    plan=try Codec.decode(ApplicationUninstallPlan.self, from: JSONSerialization.data(withJSONObject: object))
    plan.digest=try plan.calculatedDigest()
    try fixture.fixture.store.write("uninstall-plans", id: plan.id, data: Codec.encode(plan))
    try await expectThrows { try await fixture.engine.executeUninstall(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test") }
    try expect(try await fixture.engine.history().isEmpty)
    try expect(FileManager.default.fileExists(atPath: fixture.app.path))
}

func uninstallParentSiblingChangesPreservePlansButNotTargetChanges() async throws {
    let fixture=try UninstallFixture()
    let review=try await fixture.engine.reviewApplication(path: fixture.app.path)
    // Other applications and language preferences routinely update these shared
    // parent directories. Their inode identity remains the restoration boundary.
    try fixture.fixture.put("Library/Caches/unrelated-generated-cache/item.bin", "retain sibling")
    try fixture.fixture.put("Library/Preferences/unrelated-generated-preferences.plist", "retain sibling preference")
    let before=try fixture.hashes()
    let plan=try await fixture.engine.createUninstallPlan(reviewId: review.id, componentIds: review.components.filter(\.eligible).map(\.id), includeUserData: true)
    let receipt=try await fixture.engine.executeUninstall(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "test")
    try expect(receipt.state == "completed")
    let ids=receipt.items.map(\.id)
    let digest=try await fixture.engine.followUpDigest(executionId: receipt.id, itemIds: ids, action: "restore")
    let restored=try await fixture.engine.followUp(executionId: receipt.id, itemIds: ids, action: "restore", confirmedDigest: digest)
    try expect(restored.allSatisfy { $0.state == "completed" } && restored.count == 5)
    try expect(try fixture.hashes() == before)
}

func nativeUninstallEvidenceReadsOnlyExplicitContainerMetadata() throws {
    #if os(macOS)
    let fixture=try UninstallFixture(), evidence=NativeApplicationUninstallEvidence()
    let app=try fixture.catalog.application(at: fixture.app.path)
    let facts=try evidence.facts(for: app)
    try expect(facts.currentUser == getuid() && !facts.running && !facts.currentApplication)
    let container=fixture.fixture.workspace.appendingPathComponent("Library/Containers/dev.shou.fixture.uninstall")
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    let metadata=container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
    try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": "dev.shou.fixture.uninstall", "secret": "never-return"], format: .binary, options: 0).write(to: metadata)
    try expect(try evidence.containerIdentifier(at: container.path) == "dev.shou.fixture.uninstall")
    try FileManager.default.moveItem(at: metadata, to: container.appendingPathComponent("retained.plist"))
    try FileManager.default.createSymbolicLink(atPath: metadata.path, withDestinationPath: "retained.plist")
    try expectThrows { try evidence.containerIdentifier(at: container.path) }

    let groupRoot=fixture.fixture.workspace.appendingPathComponent("Library/Group Containers")
    let group=groupRoot.appendingPathComponent("group.dev.shou.fixture.uninstall")
    try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
    let groupMetadata=group.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
    try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": "group.dev.shou.fixture.uninstall", "secret": "never-return"], format: .binary, options: 0).write(to: groupMetadata)
    let groupEvidence=NativeApplicationUninstallEvidence(homeDirectory: fixture.fixture.workspace)
    try expect(try groupEvidence.groupContainerPaths(for: "dev.shou.fixture.uninstall") == [group.path])
    try Data("invalid".utf8).write(to: groupMetadata)
    try expect(try groupEvidence.groupContainerPaths(for: "dev.shou.fixture.uninstall").isEmpty)
    #endif
}

/// Simulates ownership metadata without changing filesystem permissions.
private struct AuthorizedUninstallFixtureFileSystem: PlatformFileSystem {
    let wrapped: FixtureFileSystem
    let applicationPath: String
    let simulatedOwner: UInt32
    let supportsAuthorizedApplicationTrash: Bool
    var platform: String { wrapped.platform }
    var supportsTrash: Bool { true }
    func rootIdentity(_ path: String) throws -> FileEntry { try wrapped.rootIdentity(path) }
    func applicationParentIdentity(_ path: String) throws -> FileEntry { try wrapped.applicationParentIdentity(path) }
    func targetAvailability(_ path: String) -> LocationAvailability { wrapped.targetAvailability(path) }
    func locationAvailability(_ path: String) -> LocationAvailability { wrapped.locationAvailability(path) }
    func inspect(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        try inspectTarget(path, budget: budget, cancelled: cancelled)
    }
    func inspectTarget(_ path: String, budget: ScanBudget, cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        var result=try wrapped.inspectTarget(path, budget: budget, cancelled: cancelled)
        if path == applicationPath { result.entries=result.entries.map { var entry=$0; entry.owner=simulatedOwner; return entry } }
        return result
    }
    func availableBytes(_ path: String) -> Int64? { wrapped.availableBytes(path) }
    func isTrashLocation(_ path: String) -> Bool { wrapped.isTrashLocation(path) }
    func moveToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult {
        throw CheckFailure(description: "Authorized application removal must use its dedicated native boundary.")
    }
    func moveApplicationToTrash(_ path: String, expected: [FileEntry]) throws -> TrashResult {
        throw CocoaError(.userCancelled)
    }
    func restore(_ path: String, to destination: String, expected: [FileEntry]) throws { try wrapped.restore(path, to: destination, expected: expected) }
    func purge(_ path: String, expected: [FileEntry]) throws { throw CheckFailure(description: "Authorized applications must never be permanently removed.") }
}

func administratorUninstallRequiresNativeTrashAndKeepsDataOnCancellation() async throws {
    let fixture=try UninstallFixture(), before=try fixture.hashes()
    let user: UInt32=getuid() == 0 ? 501 : getuid()
    for (owner, capability) in [(UInt32(0), true), (UInt32(0), false), (user + 1000, true)] {
        let filesystem=AuthorizedUninstallFixtureFileSystem(
            wrapped: FixtureFileSystem(native: NativeFileSystem(applicationRoots: [fixture.app.deletingLastPathComponent().path]), trash: fixture.fixture.trash),
            applicationPath: fixture.app.path, simulatedOwner: owner, supportsAuthorizedApplicationTrash: capability)
        let engine=ShouEngine(store: fixture.fixture.store, filesystem: filesystem, applicationCatalog: fixture.catalog,
            uninstallEvidence: UninstallFixtureEvidence(currentUser: user), homeDirectory: fixture.fixture.workspace)
        let review=try await engine.reviewApplication(path: fixture.app.path)
        let bundle=try require(review.components.first { $0.kind == .application })
        if owner != 0 || !capability {
            try expect(!bundle.eligible && !review.requiresAdministrator)
            continue
        }
        try expect(bundle.eligible && bundle.requiresAdministrator && review.requiresAdministrator)
        try await expectThrows { try await engine.createUninstallPlan(reviewId: review.id, componentIds: [bundle.id], action: "permanent") }
        if let cache=review.components.first(where: { $0.kind == .caches && $0.eligible }) {
            try await expectThrows { try await engine.createUninstallPlan(reviewId: review.id, componentIds: [bundle.id, cache.id], action: "trash") }
        }
        let plan=try await engine.createUninstallPlan(reviewId: review.id, componentIds: [bundle.id], action: "trash")
        let receipt=try await engine.executeUninstall(planId: plan.id, confirmedDigest: plan.digest, entryPoint: "generated-authorization-cancel")
        try expect(receipt.state == "cancelled" && receipt.items.count == 1 && receipt.items[0].state == "skipped")
        try expect(try fixture.hashes() == before)
    }
    try expect(try fixture.hashes() == before)
}
