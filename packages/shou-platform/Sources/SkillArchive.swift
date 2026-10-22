import Foundation
import ShouCore

/// Small, deterministic ZIPs of the explicitly bundled files; no shell or archiver.
enum SkillArchive {
    static func encode(_ files: [String: Data]) throws -> Data {
        guard !files.isEmpty, files.count <= 64 else { throw ShouError("resource_limit", "The Skill package exceeds its file limit.") }
        var archive=Data(), central=Data()
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let name=Data(path.utf8)
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
                  path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  name.count <= 1024, data.count <= 262_144 else { throw ShouError("invalid_argument", "The Skill package contains an unsupported file.") }
            let offset=UInt32(archive.count), size=UInt32(data.count), crc=crc32(data)
            archive.le32(0x04034b50); archive.le16(20); archive.le16(0x0800); archive.le16(0)
            archive.le16(0); archive.le16(0x0021) // 1980-01-01, reproducible and valid in ZIP.
            archive.le32(crc); archive.le32(size); archive.le32(size); archive.le16(UInt16(name.count)); archive.le16(0)
            archive.append(name); archive.append(data)
            central.le32(0x02014b50); central.le16(0x0314); central.le16(20); central.le16(0x0800); central.le16(0)
            central.le16(0); central.le16(0x0021); central.le32(crc); central.le32(size); central.le32(size)
            central.le16(UInt16(name.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(0o100644 << 16); central.le32(offset); central.append(name)
        }
        let offset=UInt32(archive.count)
        archive.append(central)
        archive.le32(0x06054b50); archive.le16(0); archive.le16(0)
        archive.le16(UInt16(files.count)); archive.le16(UInt16(files.count))
        archive.le32(UInt32(central.count)); archive.le32(offset); archive.le16(0)
        return archive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value=UInt32.max
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value=(value >> 1) ^ (value & 1 == 1 ? 0xedb88320 : 0) }
        }
        return value ^ UInt32.max
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(truncatingIfNeeded: value)); le16(UInt16(truncatingIfNeeded: value >> 16)) }
}
