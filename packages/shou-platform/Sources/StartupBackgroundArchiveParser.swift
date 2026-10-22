import Foundation
import ShouCore

public struct StartupBackgroundRecord: Sendable, Equatable {
    public let identifier: String
    public let bundleIdentifier: String
    public let name: String
    public let publisher: String?
    public let path: String
    public let enabled: Bool
    public init(identifier: String, bundleIdentifier: String, name: String, publisher: String? = nil, path: String, enabled: Bool) {
        self.identifier=identifier; self.bundleIdentifier=bundleIdentifier; self.name=name; self.publisher=publisher; self.path=path; self.enabled=enabled
    }
}

/// Reads the supported BTM schema as inert binary plist values. It never invokes
/// NSKeyedUnarchiver, Objective-C archive classes, bookmark resolution or URLs.
public enum StartupBackgroundArchiveParser {
    public static let maximumBytes=8 * 1_024 * 1_024
    public static func parse(_ data: Data, limit: Int = 2_000, deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))) throws -> [StartupBackgroundRecord] {
        func check() throws {
            if Task.isCancelled { throw ShouError("cancelled", "Startup scan stopped.") }
            guard ContinuousClock.now < deadline else { throw ShouError("resource_limit", "Background archive deadline reached.") }
        }
        try check()
        let plist=try BinaryPlist(data)
        let root=try plist.dictionary(plist.root)
        guard try plist.string(root["$archiver"]) == "NSKeyedArchiver",
              let top=root["$top"], let objectsIndex=root["$objects"] else { throw invalid() }
        let topValues=try plist.dictionary(top)
        guard try plist.integer(topValues["version"]) == 13 else { throw ShouError("unsupported_schema", "Unsupported background-item archive version.") }
        let objects=try plist.array(objectsIndex)
        var classes=Set<Int>()
        for (index, object) in objects.enumerated() where plist.isDictionary(object) {
            try check()
            if try plist.string(plist.dictionary(object)["$classname"]) == "ItemRecord" { classes.insert(index) }
        }
        guard !classes.isEmpty else { throw invalid() }
        var records: [StartupBackgroundRecord]=[], seen=Set<String>()
        for object in objects where plist.isDictionary(object) {
            try check()
            let record=try plist.dictionary(object)
            guard let classIndex=try plist.uid(record["$class"]), classes.contains(classIndex), try plist.integer(record["type"]) == 2 else { continue }
            func referenced(_ key: String, in dictionary: [String: Int]) throws -> Int? {
                guard let index=try plist.uid(dictionary[key]), index > 0, index < objects.count else { return nil }
                return objects[index]
            }
            func string(_ key: String) throws -> String? { try plist.string(referenced(key, in: record)) }
            guard let identifier=try string("identifier"), let bundle=try string("bundleIdentifier"), let name=try string("name"),
                  let urlIndex=try referenced("url", in: record), plist.isDictionary(urlIndex),
                  let rawURL=try plist.string(referenced("NS.relative", in: plist.dictionary(urlIndex))),
                  let url=URL(string: rawURL), url.isFileURL, url.host == nil || url.host == "", url.query == nil, url.fragment == nil,
                  url.path.hasPrefix("/"), url.path.lowercased().hasSuffix(".app"), url.path.rangeOfCharacter(from: .controlCharacters) == nil,
                  let disposition=try plist.integer(record["disposition"]) else { continue }
            guard seen.insert(identifier).inserted else { throw invalid() }
            do {
                guard records.count < max(0, limit) else { throw ShouError("resource_limit", "Background item entry limit reached.") }
                records.append(StartupBackgroundRecord(identifier: identifier, bundleIdentifier: bundle, name: name,
                    publisher: try string("developerName"), path: url.path, enabled: disposition & 1 != 0))
            }
        }
        return records
    }
    private static func invalid() -> ShouError { ShouError("invalid_definition", "Invalid background-item archive.") }

    private struct BinaryPlist {
        let data: Data
        let offsets: [Int]
        let root: Int
        let referenceBytes: Int
        let table: Int
        init(_ data: Data) throws {
            guard data.count >= 40, data.count <= maximumBytes, data.prefix(8) == Data("bplist00".utf8) else { throw invalid() }
            self.data=data
            let trailer=data.count-32, offsetBytes=Int(data[trailer+6]), referenceBytes=Int(data[trailer+7])
            guard (1...8).contains(offsetBytes), (1...8).contains(referenceBytes) else { throw invalid() }
            func uint(_ position: Int, _ count: Int) throws -> Int {
                guard position >= 0, count > 0, count <= 8, position <= data.count-count else { throw invalid() }
                var value: UInt64=0
                for byte in data[position..<position+count] { value=(value << 8) | UInt64(byte) }
                guard value <= UInt64(Int.max) else { throw invalid() }; return Int(value)
            }
            let count=try uint(trailer+8,8), root=try uint(trailer+16,8), table=try uint(trailer+24,8)
            guard (1...200_000).contains(count), root < count, table >= 8, table <= trailer,
                  count <= (trailer-table)/offsetBytes else { throw invalid() }
            var offsets: [Int]=[]
            for index in 0..<count {
                let offset=try uint(table+index*offsetBytes,offsetBytes)
                guard offset >= 8, offset < table else { throw invalid() }; offsets.append(offset)
            }
            self.offsets=offsets; self.root=root; self.referenceBytes=referenceBytes; self.table=table
        }
        func uint(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 8, count > 0, count <= 8, offset <= table-count else { throw invalid() }
            var value: UInt64=0
            for byte in data[offset..<offset+count] { value=(value << 8) | UInt64(byte) }
            guard value <= UInt64(Int.max) else { throw invalid() }; return Int(value)
        }
        func position(_ index: Int) throws -> Int { guard offsets.indices.contains(index) else { throw invalid() }; return offsets[index] }
        func header(_ index: Int, type: Int) throws -> (offset: Int, count: Int) {
            let offset=try position(index), byte=Int(data[offset])
            guard byte >> 4 == type else { throw invalid() }
            if byte & 15 != 15 { return (offset+1, byte & 15) }
            let marker=try uint(offset+1,1)
            guard marker >> 4 == 1, marker & 15 <= 3 else { throw invalid() }
            let width=1 << (marker & 15)
            return (offset+2+width, try uint(offset+2,width))
        }
        func isDictionary(_ index: Int) -> Bool { offsets.indices.contains(index) && data[offsets[index]] >> 4 == 13 }
        func array(_ index: Int) throws -> [Int] {
            let (offset,count)=try header(index,type:10)
            guard count <= 200_000, offset <= table, count <= (table-offset)/referenceBytes else { throw invalid() }
            return try (0..<count).map { try uint(offset+$0*referenceBytes,referenceBytes) }
        }
        func dictionary(_ index: Int) throws -> [String: Int] {
            let (offset,count)=try header(index,type:13)
            guard count <= 4_096, offset <= table, count <= (table-offset)/(referenceBytes*2) else { throw invalid() }
            var result: [String: Int]=[:]
            for item in 0..<count {
                guard let key=try string(uint(offset+item*referenceBytes,referenceBytes)), result[key] == nil else { throw invalid() }
                result[key]=try uint(offset+(item+count)*referenceBytes,referenceBytes)
            }
            return result
        }
        func string(_ index: Int?) throws -> String? {
            guard let index else { return nil }
            let offset=try position(index), type=Int(data[offset] >> 4)
            guard type == 5 || type == 6 else { return nil }
            let (start,count)=try header(index,type:type), width=type == 6 ? 2 : 1
            guard count <= 8_192, start <= table, count <= (table-start)/width else { throw invalid() }
            guard let value=String(data: data[start..<start+count*width], encoding: type == 6 ? .utf16BigEndian : .ascii),
                  !value.isEmpty, value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return value
        }
        func integer(_ index: Int?) throws -> Int? {
            guard let index else { return nil }
            let offset=try position(index), marker=Int(data[offset])
            guard marker >> 4 == 1, marker & 15 <= 3 else { return nil }
            return try uint(offset+1,1 << (marker & 15))
        }
        func uid(_ index: Int?) throws -> Int? {
            guard let index else { return nil }
            let offset=try position(index), marker=Int(data[offset])
            guard marker >> 4 == 8, marker & 15 < 8 else { return nil }
            return try uint(offset+1,(marker & 15)+1)
        }
    }
}
