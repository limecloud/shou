import Foundation
import ShouCore
#if os(macOS)
import Darwin

public struct MySQLConfigurationDocument: Sendable {
    public let path: String
    public let text: String
    public let identity: FileEntry
    public let writable: Bool
    public var options: [String:String] { MySQLConfigurationOptions.parse(text) }
}
public enum MySQLConfigurationOptions {
    /// This view is an aid, not an expansion of MySQL's include/parser semantics.
    /// Preserve all source text; includes remain visible in the source editor.
    public static func parse(_ text: String) -> [String:String] {
        var section="", result=[String:String]()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line=raw.trimmingCharacters(in:.whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") { section=String(line.dropFirst().dropLast()); continue }
            guard section == "mysqld", !line.hasPrefix("#"), !line.hasPrefix(";"), !line.hasPrefix("!") else { continue }
            let parts=line.split(separator:"=",maxSplits:1).map { $0.trimmingCharacters(in:.whitespaces) }
            if parts.count == 2 { result[parts[0].replacingOccurrences(of:"_",with:"-")]=parts[1].trimmingCharacters(in:CharacterSet(charactersIn:"\"'")) }
        }
        return result
    }
}
public struct NativeMySQLConfiguration: Sendable {
    private let recordsDirectory: URL
    public init(recordsDirectory: URL = LocalRecordStore.defaultDirectory) { self.recordsDirectory=recordsDirectory }
    public func suggestedPath(service: DeveloperService?, installationPath: String) -> String? {
        if let path=service?.configurationPath, path.hasSuffix(".cnf") { return path }
        if let path=service?.configurationPath, path.hasSuffix(".plist"),
           let document=try? read(path), let bytes=document.text.data(using:.utf8),
           let value=try? PropertyListSerialization.propertyList(from:bytes,format:nil) as? [String:Any],
           let arguments=value["ProgramArguments"] as? [String],
           let explicit=arguments.first(where: { $0.hasPrefix("--defaults-file=/") }) { return String(explicit.dropFirst("--defaults-file=".count)) }
        for prefix in ["/opt/homebrew","/usr/local"] where installationPath.hasPrefix(prefix + "/Cellar/") {
            let path=prefix + "/etc/my.cnf"
            if (try? read(path)) != nil { return path }
        }
        return nil
    }
    public func read(_ path: String) throws -> MySQLConfigurationDocument {
        let value=try files.read(path)
        return .init(path:value.path,text:value.text,identity:value.identity,writable:value.writable)
    }
    public func save(_ text: String, expected: MySQLConfigurationDocument) throws -> MySQLConfigurationDocument {
        guard expected.path.hasSuffix(".cnf") else { throw ShouError("mysql_config_changed","Reload the selected MySQL configuration before saving.") }
        let value=try files.save(text,expected:.init(path:expected.path,text:expected.text,identity:expected.identity,writable:expected.writable))
        return .init(path:value.path,text:value.text,identity:value.identity,writable:value.writable)
    }
    public func log(path: String) throws -> String { try files.log(path:path) }
    private var files: NativeDeveloperConfigurationFiles { .init(recordsDirectory:recordsDirectory) }
}
#endif
