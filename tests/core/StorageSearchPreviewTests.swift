import Foundation
import ShouCore
import ShouPlatform

func storageNameSearchReadsEveryImmediateChildAndBindsContinuation() async throws {
    for indexed in [false, true] {
        let fixture=try Fixture()
        for index in 0..<203 { try fixture.put("search/entry-\(index).txt") }
        try fixture.put("search/zz-中文_100%_ÉCOLE.txt", "literal query fixture")
        try fixture.put("search/nested/not-immediate.txt")
        let engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
        let scan=try await engine.scanStorage(path: fixture.workspace.path, budget: indexed ? nil : ScanBudget())
        let before=try Digest.of(await engine.configuration())
        let first=try await engine.storageBrowsePage(scanId: scan.id, path: "search", nameFilter: " ENTRY- ")
        try expect(first.query == "ENTRY-" && first.directory.totalCount == 203 && first.directory.children.count == 200)
        let tail=try await engine.storageBrowsePage(scanId: scan.id, path: "search", offset: 200, nameFilter: "ENTRY-", expectedQueryDigest: first.queryDigest)
        try expect(tail.directory.children.count == 3 && tail.directory.nextOffset == nil)
        try expect(Set(first.directory.children.map(\.node.path)).isDisjoint(with: Set(tail.directory.children.map(\.node.path))))
        for query in ["中文", "100%", "_ÉCOLE", "école"] {
            let found=try await engine.storageBrowsePage(scanId: scan.id, path: "search", nameFilter: query)
            try expect(found.directory.totalCount == 1 && found.directory.children[0].node.path == "search/zz-中文_100%_ÉCOLE.txt")
        }
        for query in ["' OR 1=1 --", "not-immediate", "search/"] {
            try expect(try await engine.storageBrowsePage(scanId: scan.id, path: "search", nameFilter: query).directory.totalCount == 0)
        }
        try await expectThrows { try await engine.storageBrowsePage(scanId: scan.id, path: "search", offset: 200, nameFilter: "entry-") }
        try await expectThrows { try await engine.storageBrowsePage(scanId: scan.id, path: "search", offset: 200, nameFilter: "different", expectedQueryDigest: first.queryDigest) }
        try await expectThrows { try await engine.storageBrowsePage(scanId: scan.id, path: "search/nested", nameFilter: "ENTRY-", expectedQueryDigest: first.queryDigest) }
        try await expectThrows { try await engine.storageBrowsePage(scanId: scan.id, path: "search", nameFilter: "bad\0query") }
        try await expectThrows { try await engine.storageBrowsePage(scanId: scan.id, path: "search", nameFilter: String(repeating: "x", count: 1025)) }
        let cancelled=Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.storageBrowsePage(scanId: scan.id, path: "search", nameFilter: "entry")
        }
        do { _ = try await cancelled.value; throw CheckFailure(description: "Cancelled name search returned results.") }
        catch is CancellationError { }
        catch let error as ShouError { try expect(error.code == "cancelled") }
        try expect(try Digest.of(await engine.configuration()) == before)
        try expect(try fixture.store.ids("storage-plans").isEmpty && fixture.store.ids("history").isEmpty)
    }
}

func storagePreviewIsBoundedReadOnlyAndRejectsChangedObjects() async throws {
    let fixture=try Fixture(), engine=ShouEngine(store: fixture.store, filesystem: fixture.fs)
    let text="中文 fixture\n<script>literal text</script>\tretained"
    try fixture.put("preview/text.html", text)
    try fixture.put("preview/large.log", String(repeating: "中", count: 100_000))
    try fixture.put("preview/data.bin", "\0binary\u{1}")
    try fixture.put("preview/not-executed.exe", "MZ generated fixture")
    let utf16=Data([0xff,0xfe]) + (try require("UTF16 中文".data(using: .utf16LittleEndian)))
    try utf16.write(to: fixture.workspace.appendingPathComponent("preview/unicode.txt"))
    let image=try require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNQaDjwHwAEhAJgikCezQAAAABJRU5ErkJggg=="))
    try image.write(to: fixture.workspace.appendingPathComponent("preview/image.png"))
    let scan=try await engine.scanStorage(path: fixture.workspace.path)
    let reader=NativeStoragePreview(), before=try Digest.of(await engine.configuration())
    let preview=try await engine.storagePreview(scanId: scan.id, path: "preview/text.html", reader: reader)
    try expect(preview.format == "text" && preview.text == text && preview.image == nil && !preview.truncated)
    let prefix=try await engine.storagePreview(scanId: scan.id, path: "preview/large.log", reader: reader)
    try expect(prefix.format == "text" && prefix.truncated && prefix.notice == "text_prefix" && (prefix.text?.utf8.count ?? 0) <= 262_144)
    try expect(prefix.text?.allSatisfy { $0 == "中" } == true)
    try expect(try await engine.storagePreview(scanId: scan.id, path: "preview/unicode.txt", reader: reader).text == "UTF16 中文")
    try expect(try await engine.storagePreview(scanId: scan.id, path: "preview/image.png", reader: reader).image == image)
    for path in ["preview/data.bin", "preview/not-executed.exe", "preview"] {
        try expect(try await engine.storagePreview(scanId: scan.id, path: path, reader: reader).format == "metadata")
    }
    for path in [".", "../outside", "preview/absent"] {
        try await expectThrows { try await engine.storagePreview(scanId: scan.id, path: path, reader: reader) }
    }
    try fixture.put("preview/text.html", "changed")
    try await expectThrows { try await engine.storagePreview(scanId: scan.id, path: "preview/text.html", reader: reader) }
    try FileManager.default.removeItem(at: fixture.workspace.appendingPathComponent("preview/unicode.txt"))
    try FileManager.default.createSymbolicLink(atPath: fixture.workspace.appendingPathComponent("preview/unicode.txt").path, withDestinationPath: fixture.workspace.appendingPathComponent("preview/large.log").path)
    try await expectThrows { try await engine.storagePreview(scanId: scan.id, path: "preview/unicode.txt", reader: reader) }
    let cancelled=Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await engine.storagePreview(scanId: scan.id, path: "preview/large.log", reader: reader)
    }
    do { _ = try await cancelled.value; throw CheckFailure(description: "Cancelled preview returned content.") }
    catch is CancellationError { }
    catch let error as ShouError { try expect(error.code == "cancelled") }
    try expect(try Digest.of(await engine.configuration()) == before)
    try expect(try fixture.store.ids("storage-plans").isEmpty && fixture.store.ids("history").isEmpty)
    try expect(try String(contentsOf: fixture.workspace.appendingPathComponent("preview/not-executed.exe"), encoding: .utf8) == "MZ generated fixture")
}
