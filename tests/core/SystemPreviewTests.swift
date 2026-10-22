import Foundation
import ShouCore

private func previewEntry(_ path: String,kind: String = "file",id: String = "a") -> FileEntry {
    var value=FileEntry(path: path,kind: kind,device: 1,inode: 0,logicalBytes: kind == "file" ? 4096 : 0,allocatedBytes: 4096,
        modifiedNanoseconds: 100,changedNanoseconds: 100,mode: kind == "file" ? 32 : 16,owner: 0,links: 1)
    value.windowsIdentity = .init(volume: 1,fileId: String(repeating: id,count: 32),ownerSid: "S-1-5-21-1234")
    return value
}
private struct PreviewFilesystem: PlatformFileSystem {
    var changed=false
    var platform: String { "windows" }
    var supportsTrash: Bool { false }
    func rootIdentity(_ path: String) throws -> FileEntry { previewEntry(".",kind: "directory",id: changed ? "b" : "a") }
    func inspect(_ path: String,budget: ScanBudget,cancelled: @Sendable () -> Bool) throws -> TreeSnapshot {
        .init(entries: [try rootIdentity(path)] + ["report.pdf","notes.docx","sheet.xlsx","slides.pptx","movie.mp4","audio.flac","not-run.exe"].enumerated().map {
            previewEntry($0.element,id: String($0.offset+1))
        },complete: true,issues: [],caseSensitive: false)
    }
    func locationAvailability(_ path: String) -> LocationAvailability { .available }
    func availableBytes(_ path: String) -> Int64? { nil }
    func isTrashLocation(_ path: String) -> Bool { false }
    func moveToTrash(_ path: String,expected: [FileEntry]) throws -> TrashResult { throw ShouError("unexpected_mutation", "Preview must not mutate files.") }
    func restore(_ path: String,to destination: String,expected: [FileEntry]) throws { throw ShouError("unexpected_mutation", "Preview must not mutate files.") }
    func purge(_ path: String,expected: [FileEntry]) throws { throw ShouError("unexpected_mutation", "Preview must not mutate files.") }
}
private struct NoInlinePreviewRead: StoragePreviewReading {
    func read(_ path: String,expected: FileEntry,maximumBytes: Int,cancelled: @Sendable () -> Bool) throws -> Data {
        throw ShouError("unexpected_read", "System preview must use its own pinned native stream.")
    }
}

func systemPreviewBindsScanEvidenceWithoutCreatingMutationAuthority() async throws {
    let fixture=try Fixture(), engine=ShouEngine(store: fixture.store,filesystem: PreviewFilesystem())
    let scan=try await engine.scanStorage(path: "C:/Users/generated/preview",budget: .init())
    let before=try Digest.of(await engine.configuration())
    for name in ["report.pdf","notes.docx","sheet.xlsx","slides.pptx","movie.mp4","audio.flac"] {
        let preview=try await engine.storagePreview(scanId: scan.id,path: name,reader: NoInlinePreviewRead())
        let capability=try require(preview.systemPreview)
        try expect(preview.format == "system" && preview.notice == "system_preview" && preview.text == nil && preview.image == nil)
        try expect(capability.file.path == name && capability.absolutePath == scan.rootPath+"/"+name && capability.rootIdentity == scan.identity)
        let request=SystemPreviewRequest(parentPid: 42,hostWindow: 123,preview: capability)
        try request.validate();try Codec.decode(SystemPreviewRequest.self,from: Codec.encode(request)).validate()
    }
    try expect(try await engine.storagePreview(scanId: scan.id,path: "not-run.exe",reader: NoInlinePreviewRead()).systemPreview == nil)
    let changed=ShouEngine(store: fixture.store,filesystem: PreviewFilesystem(changed: true))
    try await expectThrows { try await changed.storagePreview(scanId: scan.id,path: "report.pdf",reader: NoInlinePreviewRead()) }
    try await expectThrows { try await engine.storagePreview(scanId: scan.id,path: "absent.pdf",reader: NoInlinePreviewRead()) }
    try expect(try Digest.of(await engine.configuration()) == before)
    try expect(try fixture.store.ids("storage-plans").isEmpty && fixture.store.ids("history").isEmpty)
}

func systemPreviewRejectsForgedHostPathsAndExecutableFormats() throws {
    let root=previewEntry(".",kind: "directory")
    for name in ["../report.pdf","folder\\..\\report.pdf","report.pdf:stream","report.exe","report.pdf.exe","script.js","shortcut.lnk","page.html","folder/\nreport.pdf"] {
        try expectThrows { try StorageSystemPreview(rootPath: "C:/Users/generated",rootIdentity: root,file: previewEntry(name)).validate() }
    }
    for path in ["relative", "//server/share", "C:/Users/../other", "C:/Users/\ngenerated"] {
        try expectThrows { try StorageSystemPreview(rootPath: path,rootIdentity: root,file: previewEntry("report.pdf")).validate() }
    }
    var noIdentity=root;noIdentity.windowsIdentity=nil
    try expectThrows { try StorageSystemPreview(rootPath: "C:/Users/generated",rootIdentity: noIdentity,file: previewEntry("report.pdf")).validate() }
    let capability=StorageSystemPreview(rootPath: "C:/Users/generated",rootIdentity: root,file: previewEntry("report.pdf"))
    for request in [SystemPreviewRequest(version: 2,parentPid: 42,hostWindow: 123,preview: capability),
                    SystemPreviewRequest(parentPid: 0,hostWindow: 123,preview: capability),
                    SystemPreviewRequest(parentPid: 42,hostWindow: 0,preview: capability)] { try expectThrows { try request.validate() } }
}
