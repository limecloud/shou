import Foundation
import ShouCore
#if os(macOS)

public struct DeveloperConfigurationTarget: Identifiable, Equatable, Sendable {
    public let path: String
    public let source: String
    public var id: String { path }
    public init(path: String, source: String) { self.path=path; self.source=source }
}
public struct DeveloperLogTarget: Identifiable, Equatable, Sendable {
    public let path: String
    public let title: String
    public var id: String { path }
    public init(path: String, title: String) { self.path=path; self.title=title }
}
/// Paths come from this software's actual instance or its documented manager
/// layout. A package installation never becomes an instance configuration.
public struct NativeDeveloperConfiguration: Sendable {
    public static var supportedTools: Set<String> { Set(adapters.map(\.toolID)) }
    private static let adapters: [any DeveloperConfigurationAdapting] = [
        NginxConfigurationAdapter(), RedisConfigurationAdapter(), PostgreSQLConfigurationAdapter(), MongoDBConfigurationAdapter(),
        ApacheConfigurationAdapter(), CaddyConfigurationAdapter(), MeilisearchConfigurationAdapter(),
        ConsulConfigurationAdapter(), EtcdConfigurationAdapter(), NumaConfigurationAdapter(), MailpitConfigurationAdapter()
    ]
    private let dataRoots: [URL]
    private let homebrewPrefixes: [String]
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, referenceDataRoots: [URL]? = nil,
                homebrewPrefixes: [String] = ["/opt/homebrew", "/usr/local"]) {
        dataRoots=referenceDataRoots ?? NativeDeveloperStorageRoots.referenceData(home:homeDirectory)
        self.homebrewPrefixes=homebrewPrefixes
    }
    public func targets(toolID: String, installations: [DeveloperToolInstallation], services: [DeveloperService]) -> [DeveloperConfigurationTarget] {
        guard let adapter=Self.adapters.first(where:{ $0.toolID == toolID }) else { return [] }
        var values=[DeveloperConfigurationTarget]()
        for service in services where service.toolID == toolID {
            if NativeDeveloperConfigurationFiles.accepts(service.configurationPath) {
                values.append(.init(path:service.configurationPath,source:service.source))
            } else if service.configurationPath.hasSuffix(".plist"),
                      let doc=try? NativeDeveloperConfigurationFiles().read(service.configurationPath),
                      let data=doc.text.data(using:.utf8),
                      let plist=try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],
                      let args=plist["ProgramArguments"] as? [String],
                      let path=adapter.configuration(arguments:args) {
                values.append(.init(path:path,source:service.source))
            }
        }
        for copy in installations where copy.toolID == toolID && copy.source == "Homebrew" {
            for prefix in homebrewPrefixes where copy.path.hasPrefix(prefix + "/Cellar/") {
                let token=copy.path.dropFirst((prefix + "/Cellar/").count).split(separator:"/").first.map(String.init) ?? ""
                if let suffix=adapter.homebrewPath(token:token) { values.append(.init(path:prefix + suffix,source:copy.source)) }
            }
        }
        // The reference can run Homebrew binaries using its own configuration.
        // A storage path is a file candidate, never proof that a service uses it.
        for copy in installations where copy.toolID == toolID {
            for root in dataRoots {
                values += adapter.storedConfigurations(root:root.appendingPathComponent("server"),installation:copy)
                    .map { .init(path:$0,source:"FlyEnv storage") }
            }
        }
        var seen=Set<String>()
        return values.filter { $0.path.hasPrefix("/") && seen.insert($0.path).inserted && FileManager.default.fileExists(atPath:$0.path) }
    }
    public func logs(toolID: String, document: DeveloperConfigurationDocument?, services: [DeveloperService], installations: [DeveloperToolInstallation] = []) -> [DeveloperLogTarget] {
        var values=[DeveloperLogTarget]()
        for row in services where row.toolID == toolID {
            if let path=row.logPath { values.append(.init(path:path,title:"Service Log")) }
            if let path=row.errorLogPath { values.append(.init(path:path,title:"Startup Output")) }
        }
        if let document, let adapter=Self.adapters.first(where:{ $0.toolID == toolID }) { values += adapter.logs(document:document) }
        if let adapter=Self.adapters.first(where:{ $0.toolID == toolID }) {
            for copy in installations where copy.toolID == toolID {
                for root in dataRoots {
                    let server=root.appendingPathComponent("server")
                    guard adapter.storedConfigurations(root:server,installation:copy).contains(where:{ FileManager.default.fileExists(atPath:$0) }) else { continue }
                    values += adapter.storedLogs(root:server,installation:copy).filter { FileManager.default.fileExists(atPath:$0.path) }
                }
            }
        }
        var seen=Set<String>()
        return values.filter { seen.insert($0.path).inserted }
    }
}

protocol DeveloperConfigurationAdapting: Sendable {
    var toolID: String { get }
    func homebrewPath(token: String) -> String?
    func configuration(arguments: [String]) -> String?
    func logs(document: DeveloperConfigurationDocument) -> [DeveloperLogTarget]
    func storedConfigurations(root: URL, installation: DeveloperToolInstallation) -> [String]
    func storedLogs(root: URL, installation: DeveloperToolInstallation) -> [DeveloperLogTarget]
}
extension DeveloperConfigurationAdapting {
    func homebrewPath(token: String) -> String? { nil }
    func logs(document: DeveloperConfigurationDocument) -> [DeveloperLogTarget] { [] }
    func storedConfigurations(root: URL, installation: DeveloperToolInstallation) -> [String] { [] }
    func storedLogs(root: URL, installation: DeveloperToolInstallation) -> [DeveloperLogTarget] { [] }
}
enum DeveloperConfigurationPaths {
    static func startupLogs(tool: String, root: URL, version: String?) -> [DeveloperLogTarget] {
        guard let version, version.range(of:"\\A[0-9]+(?:\\.[0-9]+){1,3}(?:[-+][A-Za-z0-9.-]+)?\\z",options:.regularExpression) != nil, version.utf8.count <= 64 else { return [] }
        return [DeveloperLogTarget(path:root.appendingPathComponent(tool + "/" + tool + "-" + version + "-start-out.log").path,title:"Startup Output"),
                DeveloperLogTarget(path:root.appendingPathComponent(tool + "/" + tool + "-" + version + "-start-error.log").path,title:"Error Log")]
    }
    static func option(_ key: String, in arguments: [String]) -> String? {
        var values=[String]()
        for (index,value) in arguments.enumerated() {
            if value == key {
                guard index+1 < arguments.count else { return nil }
                values.append(arguments[index+1])
            }
            else if value.hasPrefix(key + "=") { values.append(String(value.dropFirst(key.count+1))) }
        }
        return values.count == 1 ? values.first : nil
    }
    static func absolute(_ value: String) -> String? {
        value.hasPrefix("/") && !value.unicodeScalars.contains(where:{ $0.value < 32 || $0.value == 127 }) && !value.contains("$") && !value.contains("*") ? value : nil
    }
}
#endif
