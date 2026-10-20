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

@main enum WindowsTests {
    static func main() throws {
        let args=Array(CommandLine.arguments.dropFirst())
        if args.count == 2, args[0] == "--lock-probe" {
            let store=try LocalRecordStore(directory: URL(fileURLWithPath: args[1]))
            do { let lease=try store.lock(); lease.release(); throw Failure(message: "A second process acquired the same lock") }
            catch let error as ShouError { try require(error.code == "store_busy", "Unexpected lock error: \(error)") }
            return
        }
        let fs=NativeFileSystem()
        let root=try fs.normalizedPath(FileManager.default.temporaryDirectory.appendingPathComponent("shou-windows-" + UUID().uuidString).path)
        try privateDirectory(root)
        // Remove only a newly generated, isolated fixture. Never enumerate or
        // modify existing user workspaces in the Windows native checks.
        defer { try? FileManager.default.removeItem(atPath: root) }
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
        junction.arguments=["/d", "/c", "mklink", "/J", workspace + "/junction", outside]
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

        if args.contains("--recycle") {
            try require(fs.supportsTrash, "Set SHOU_WINDOWS_EXPERIMENTAL_RECYCLE=1 for generated Recycle Bin fixtures")
            let result=try fs.moveToTrash(target, expected: tree.entries)
            try require(result.verified && fs.isTrashLocation(result.path), "Recycle result is not verified")
            try privateDirectory(target); try write(target + "/conflict.bin", "do not overwrite")
            do { try fs.restore(result.path, to: target, expected: result.manifest); throw Failure(message: "Restore overwrote a conflict") } catch let error as ShouError { try require(error.code == "restore_conflict", "Unexpected conflict: \(error)") }
            try FileManager.default.removeItem(atPath: target)
            try fs.restore(result.path, to: target, expected: result.manifest)
            try require(try String(contentsOfFile: target + "/fixture.bin", encoding: .utf8) == "generated Windows fixture", "Restored content mismatch")
            print("PASS actual Recycle Bin and conflict-safe restore (generated fixture)")
        } else { print("SKIP Recycle Bin: use --recycle in a native interactive test session") }
    }
}
