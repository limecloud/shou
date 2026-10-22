import Foundation

public protocol StoragePreviewReading: Sendable {
    func read(_ path: String, expected: FileEntry, maximumBytes: Int, cancelled: @Sendable () -> Bool) throws -> Data
}

public struct StorageFilePreview: Codable, Sendable {
    public let path: String
    public let absolutePath: String
    public let format: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let measuredAt: Date
    public let truncated: Bool
    public let text: String?
    public let image: Data?
    public let notice: String?
}

extension ShouEngine {
    /// Preview is a bounded local read, independent of removal eligibility.
    /// A platform reader must reject links and bind its handle to this identity.
    public func storagePreview(scanId: String, path: String, reader: any StoragePreviewReading) throws -> StorageFilePreview {
        try Task.checkCancellation()
        guard StorageRemovalPolicy.validRelative(path) else { throw ShouError("invalid_argument", "Choose one exact analysis item to preview.") }
        let scan=try storageScan(scanId)
        guard let entry=try storageEntry(scan: scan, path: path) else { throw ShouError("invalid_argument", "Item is absent from this analysis.") }
        let node: StorageNode
        if let catalog=try catalog(for: scan), let item=try catalog.entry(at: path) { node=item.node }
        else if let item=StorageIndex(tree: scan.tree).nodes[path] { node=item }
        else { throw ShouError("invalid_argument", "Item is absent from this analysis.") }
        let absolute=StorageRemovalPolicy.absolute(root: scan.rootPath, relative: path)
        func result(_ format: String, text: String? = nil, image: Data? = nil, truncated: Bool = false, notice: String? = nil) -> StorageFilePreview {
            StorageFilePreview(path: path, absolutePath: absolute, format: format, logicalBytes: node.logicalBytes, allocatedBytes: node.allocatedBytes,
                measuredAt: scan.createdAt, truncated: truncated, text: text, image: image, notice: notice)
        }
        guard entry.kind == "file" else { return result("metadata", notice: "snapshot_metadata") }
        let suffix=StorageExtensionStat.suffix(node.name)
        if ["exe", "dll", "com", "msi", "lnk", "url", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx"].contains(suffix) {
            return result("metadata", notice: "format_unavailable")
        }
        let imageType=["png", "jpg", "jpeg", "gif", "bmp"].contains(suffix)
        let limit=imageType ? 4 * 1024 * 1024 : 256 * 1024
        func verifyRoot() throws {
            let current=try filesystem.analysisRootIdentity(scan.rootPath)
            guard current.sameObject(as: scan.identity), current.hasSameOwner(as: scan.identity) else { throw ShouError("plan_stale", "Analysis root changed.") }
        }
        try Task.checkCancellation(); try verifyRoot()
        let bytes=try reader.read(absolute, expected: entry, maximumBytes: limit, cancelled: { Task.isCancelled })
        try Task.checkCancellation(); try verifyRoot()
        guard bytes.count <= limit, Int64(bytes.count) <= entry.logicalBytes else { throw ShouError("invalid_preview", "Preview reader exceeded its verified scope.") }
        let truncated=Int64(bytes.count) < entry.logicalBytes
        if imageType {
            let signature=Array(bytes.prefix(8))
            let supported=signature.starts(with: [0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) || signature.starts(with: [0xff,0xd8,0xff]) ||
                signature.starts(with: Array("GIF87a".utf8)) || signature.starts(with: Array("GIF89a".utf8)) || signature.starts(with: [0x42,0x4d])
            guard supported, !truncated else { return result("metadata", notice: truncated ? "image_too_large" : "format_unavailable") }
            return result("image", image: bytes)
        }
        let encoding: String.Encoding, content: Data
        if bytes.starts(with: [0xff,0xfe]) { encoding = .utf16LittleEndian; content=bytes.dropFirst(2) }
        else if bytes.starts(with: [0xfe,0xff]) { encoding = .utf16BigEndian; content=bytes.dropFirst(2) }
        else { encoding = .utf8; content=bytes.starts(with: [0xef,0xbb,0xbf]) ? bytes.dropFirst(3) : bytes }
        var text=String(data: content, encoding: encoding)
        if text == nil, truncated {
            for tail in 1...3 where content.count >= tail {
                if let value=String(data: content.dropLast(tail), encoding: encoding) { text=value; break }
            }
        }
        guard let text, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && ![9,10,13].contains($0.value) }) else {
            return result("metadata", notice: "format_unavailable")
        }
        return result("text", text: text, truncated: truncated, notice: truncated ? "text_prefix" : nil)
    }
}
