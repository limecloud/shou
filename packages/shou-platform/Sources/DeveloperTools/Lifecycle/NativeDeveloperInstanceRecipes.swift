import Foundation
import ShouCore
#if os(macOS)
import Darwin

enum NativeDeveloperInstancePaths {
    static func physical(_ path: String) -> String {
        guard let resolved=realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

struct DeveloperInstanceRecipeContext {
    let home: URL
    let pid: Int32
    let executable: String
    let arguments: [String]
    let directory: String
    let version: String?
    let read: (String) throws -> Data
}
struct DeveloperInstanceConfiguration {
    let arguments: [String]
    let path: String
    let pidFile: String?
    let log: String?
}
/// Closed, software-specific strategies. Discovery never loads executable plugins
/// or turns arbitrary process arguments into a generic command runner.
protocol DeveloperInstanceRecipeAdapting: Sendable {
    var toolID: String { get }
    var executableName: String { get }
    func resolve(_ context: DeveloperInstanceRecipeContext) -> DeveloperInstanceConfiguration?
    func explicitConfiguration(in arguments: [String]) -> String?
}
extension DeveloperInstanceRecipeAdapting {
    func explicitConfiguration(in arguments: [String]) -> String? { nil }
}
enum NativeDeveloperInstanceRecipes {
    static let adapters: [any DeveloperInstanceRecipeAdapting] = [NginxInstanceRecipe(), MySQLInstanceRecipe(), RedisInstanceRecipe(), PostgreSQLInstanceRecipe()]
    static func adapter(tool: String) -> (any DeveloperInstanceRecipeAdapting)? { adapters.first { $0.toolID == tool } }
    static func tool(executable: String) -> String? { adapters.first { $0.executableName == URL(fileURLWithPath: executable).lastPathComponent }?.toolID }
}
#endif
