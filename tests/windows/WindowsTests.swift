import Foundation
import ShouCore
import ShouPlatform
import CShouWindows

struct Failure: Error { let message: String }
func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
func native(_ code: Int32) throws { try require(code == 0, "Win32 error \(code)") }
func privateDirectory(_ path: String) throws { try native(shou_win_private_directory(path)) }
func write(_ path: String, _ text: String) throws {
    try Data(text.utf8).withUnsafeBytes { try native(shou_win_write(path, $0.baseAddress, $0.count)) }
}
func savedManifest(_ path: String, _ tree: TreeSnapshot) throws -> [shou_win_info] {
    try tree.entries.map { entry in
        var raw=shou_win_info()
        try native(shou_win_stat(entry.path == "." ? path : path + "/" + entry.path, &raw))
        return raw
    }
}
func rawPurge(_ path: String, _ tree: TreeSnapshot, _ saved: [shou_win_info], cancelled: shou_win_cancelled? = nil) -> (code: Int32, removed: Int) {
    var names=[CChar](), offsets=[Int](), digests=[CChar](), digestOffsets=[Int](), removed=0
    for entry in tree.entries { offsets.append(names.count); names.append(contentsOf: entry.path.utf8CString); digestOffsets.append(digests.count); digests.append(contentsOf: (entry.contentDigest ?? "").utf8CString) }
    let code=names.withUnsafeBufferPointer { bytes in
        let pointers=offsets.map { bytes.baseAddress?.advanced(by: $0) }
        return digests.withUnsafeBufferPointer { digestBytes in
            let digestPointers=digestOffsets.map { digestBytes.baseAddress?.advanced(by: $0) }
            return saved.withUnsafeBufferPointer { shou_win_purge(path, pointers, digestPointers, $0.baseAddress, $0.count, cancelled, &removed) }
        }
    }
    return (code,removed)
}

@main enum WindowsTests {
    nonisolated(unsafe) static var cancellationRemaining=0
    static func main() throws {
        let args=Array(CommandLine.arguments.dropFirst())
        if args == ["--evidence-child"] {
            FileHandle.standardOutput.write(Data([1]))
            Thread.sleep(forTimeInterval: 45)
            return
        }
        if args.count == 2, args[0] == "--lock-probe" {
            let store=try LocalRecordStore(directory: URL(fileURLWithPath: args[1]))
            do { let lease=try store.lock(); lease.release(); throw Failure(message: "A second process acquired the same lock") }
            catch let error as ShouError { try require(error.code == "store_busy", "Unexpected lock error: \(error)") }
            return
        }
        let fs=NativeFileSystem()
        try require(args.contains("--recycle") ? fs.supportsTrash : (!fs.supportsTrash && fs.trashUnavailableReason?.contains("disabled by default") == true), "Recycle Bin default policy or validation switch is incorrect")
        let root=try fs.normalizedPath(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("shou-windows-validation-" + UUID().uuidString).path)
        try privateDirectory(root)
        // Remove only a newly generated, isolated fixture. Never enumerate or
        // modify existing user workspaces in the Windows native checks.
        defer { try? FileManager.default.removeItem(atPath: root) }
        try windowsCanonicalSpellingRetainsProtectedRoots(root: root)
        try windowsArtifactEvidenceChecksNativeGitAndProjectProcesses(root: root)
        try windowsStorageMeasurementPreservesIdentitiesAndNativeCursors(root: root)
        try windowsPrivacySourcesPinDatabasePathsAndRejectHardlinks(root: root)
        let workspace=root + "/中文 空格 & fixture"
        try privateDirectory(workspace)
        let target=workspace + "/generated"
        try privateDirectory(target)
        try write(target + "/fixture.bin", "generated Windows fixture")
        let identity=try fs.rootIdentity(workspace)
        try require(identity.windowsIdentity?.fileId.count == 32 && identity.windowsIdentity?.ownerSid.hasPrefix("S-1-") == true, "Full File ID and owner SID required")
        let tree=try fs.inspect(target, budget: ScanBudget(), cancelled: { false })
        try require(tree.complete && tree.entries.count == 2 && !tree.caseSensitive, "Complete Unicode tree required")
        print("PASS native Unicode paths, 128-bit IDs, SID and bounded traversal")

        let partial=try fs.inspect(workspace, budget: ScanBudget(maxEntries: 1), cancelled: { false })
        try require(!partial.complete, "Budget exhaustion must be partial")
        do { _=try fs.normalizedPath("\\\\server\\share"); throw Failure(message: "UNC accepted") } catch is ShouError { }
        do { _=try fs.normalizedPath(workspace + "/file:stream"); throw Failure(message: "ADS accepted") } catch is ShouError { }
        do { _=try fs.normalizedPath(workspace + "/CON.txt"); throw Failure(message: "Device name accepted") } catch is ShouError { }
        let outside=root + "/outside"; try privateDirectory(outside); try write(outside + "/keep.bin", "keep")
        let junction=Process(); junction.executableURL=URL(fileURLWithPath: ProcessInfo.processInfo.environment["ComSpec"] ?? "C:/Windows/System32/cmd.exe")
        // mklink parses forward slashes as switches even in absolute paths.
        junction.arguments=["/d", "/c", "mklink", "/J",
            (workspace + "/junction").replacingOccurrences(of: "/", with: "\\"),
            outside.replacingOccurrences(of: "/", with: "\\")]
        try junction.run(); junction.waitUntilExit()
        try require(junction.terminationStatus == 0, "Junction fixture creation failed")
        let linked=try fs.inspect(workspace, budget: ScanBudget(), cancelled: { false })
        try require(!linked.complete && !linked.entries.contains { $0.path.contains("keep.bin") }, "Junctions must stay opaque and partial")
        try FileManager.default.removeItem(atPath: workspace + "/junction")
        try require(FileManager.default.fileExists(atPath: outside + "/keep.bin"), "Junction target changed")
        print("PASS partial scans, UNC/ADS/device refusal and no junction traversal")

        let store=try LocalRecordStore(directory: URL(fileURLWithPath: root + "/records"))
        try store.write("fixtures", id: "unicode", data: Data("中文记录".utf8))
        try require(try store.read("fixtures", id: "unicode") == Data("中文记录".utf8), "Atomic record round trip")
        let lease=try store.lock()
        let probe=Process(); probe.executableURL=URL(fileURLWithPath: CommandLine.arguments[0]); probe.arguments=["--lock-probe", store.directory.path]
        try probe.run(); probe.waitUntilExit(); lease.release()
        try require(probe.terminationStatus == 0, "Cross-process lock exclusion failed")
        let next=try store.lock(); next.release()
        print("PASS private ACL, atomic records and cross-process LockFileEx")

        let permanent=workspace + "/permanent"
        try privateDirectory(permanent); try privateDirectory(permanent + "/nested"); try privateDirectory(permanent + "/empty")
        try write(permanent + "/nested/中文.bin", "permanent fixture")
        let before=try fs.inspect(permanent, budget: ScanBudget(), cancelled: { false })
        let saved=try savedManifest(permanent, before)
        let handle=try FileHandle(forWritingTo: URL(fileURLWithPath: permanent + "/nested/中文.bin"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data(" changed".utf8)); try handle.close()
        let stale=rawPurge(permanent, before, saved)
        try require(stale.code != 0 && stale.removed == 0 && FileManager.default.fileExists(atPath: permanent + "/empty"), "A changed file must stop native preflight before any deletion")
        let current=try fs.inspect(permanent, budget: ScanBudget(), cancelled: { false })
        try write(permanent + "/unreviewed.bin", "keep unreviewed")
        do { try fs.purge(permanent, expected: current.entries); throw Failure(message: "Unreviewed child accepted") }
        catch let error as ShouError { try require(error.code == "plan_stale", "Unexpected manifest error: \(error)") }
        try require(FileManager.default.fileExists(atPath: permanent + "/unreviewed.bin"), "An unreviewed member was removed")
        let complete=try fs.inspect(permanent, budget: ScanBudget(), cancelled: { false })
        try fs.purge(permanent, expected: complete.entries)
        try require(!FileManager.default.fileExists(atPath: permanent), "Nested permanent removal did not finish")
        try require(FileManager.default.fileExists(atPath: outside + "/keep.bin"), "Permanent removal escaped its scope")
        print("PASS native metadata preflight, unreviewed-child refusal and nested permanent removal")

        let single=workspace + "/single.bin"; try write(single, "bounded file digest")
        let file=try fs.inspectTarget(single, budget: ScanBudget(), cancelled: { false })
        try require(file.entries[0].contentDigest != nil, "Permanent file targets need a content digest")
        try fs.purge(single, expected: file.entries)
        try require(!FileManager.default.fileExists(atPath: single), "Permanent file removal failed")

        let replaced=workspace + "/replaced"; try privateDirectory(replaced); try write(replaced + "/keep.bin", "old identity")
        let old=try fs.inspect(replaced, budget: ScanBudget(), cancelled: { false })
        try FileManager.default.moveItem(atPath: replaced, toPath: replaced + "-original")
        try privateDirectory(replaced); try write(replaced + "/keep.bin", "replacement identity")
        do { try fs.purge(replaced, expected: old.entries); throw Failure(message: "Replacement identity accepted") }
        catch let error as ShouError { try require(error.code == "plan_stale", "Unexpected replacement error: \(error)") }
        try require(FileManager.default.fileExists(atPath: replaced + "/keep.bin") && FileManager.default.fileExists(atPath: replaced + "-original/keep.bin"), "Replacement refusal changed files")
        print("PASS permanent file digest and replaced-directory refusal")

        let partialRoot=workspace + "/partial"; try privateDirectory(partialRoot); try privateDirectory(partialRoot + "/nested")
        try write(partialRoot + "/nested/fixture.bin", "partial fixture")
        let partialTree=try fs.inspect(partialRoot, budget: ScanBudget(), cancelled: { false })
        cancellationRemaining=partialTree.entries.count + 2
        let stopped=rawPurge(partialRoot, partialTree, try savedManifest(partialRoot, partialTree), cancelled: {
            cancellationRemaining -= 1; return cancellationRemaining <= 0 ? 1 : 0
        })
        try require(stopped.code == 1223 && stopped.removed == 1 && FileManager.default.fileExists(atPath: partialRoot) && !FileManager.default.fileExists(atPath: partialRoot + "/nested/fixture.bin"), "Cancellation must report the partial removal count")
        print("PASS native permanent cancellation reports partially removed manifest")

        if args.contains("--recycle") {
            let result=try fs.moveToTrash(target, expected: tree.entries)
            try require(result.verified && fs.isTrashLocation(result.path), "Recycle result is not verified")
            try privateDirectory(target); try write(target + "/conflict.bin", "do not overwrite")
            do { try fs.restore(result.path, to: target, expected: result.manifest); throw Failure(message: "Restore overwrote a conflict") } catch let error as ShouError { try require(error.code == "restore_conflict", "Unexpected conflict: \(error)") }
            try FileManager.default.removeItem(atPath: target)
            try fs.restore(result.path, to: target, expected: result.manifest)
            try require(try String(contentsOfFile: target + "/fixture.bin", encoding: .utf8) == "generated Windows fixture", "Restored content mismatch")
            print("PASS actual Recycle Bin and conflict-safe restore (generated fixture)")
            let restoredTree=try fs.inspectTarget(target, budget: ScanBudget(), cancelled: { false })
            let recycled=try fs.moveToTrash(target, expected: restoredTree.entries)
            try require(recycled.verified, "Purge fixture recycle result is not verified")
            let recycleURL=URL(fileURLWithPath: recycled.path)
            let metadataPath=recycleURL.deletingLastPathComponent().appendingPathComponent("$I" + recycleURL.lastPathComponent.dropFirst(2)).path
            try fs.purge(recycled.path, expected: recycled.manifest)
            try require(!FileManager.default.fileExists(atPath: recycled.path) && !FileManager.default.fileExists(atPath: metadataPath), "Recorded Recycle Bin item or its paired metadata was not permanently removed")
            print("PASS permanent removal of the exact generated Recycle Bin receipt target")
        } else { print("SKIP Recycle Bin: use --recycle in a native interactive test session") }
    }
}
