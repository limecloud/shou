import Foundation
import ShouCore
#if os(macOS)
import Darwin

struct RedisInstanceRecipe: DeveloperInstanceRecipeAdapting {
    let toolID="redis", executableName="redis-server"
    func resolve(_ context: DeveloperInstanceRecipeContext) -> DeveloperInstanceConfiguration? {
        var arguments=Array(context.arguments.dropFirst())
        if arguments.count != 1 || !arguments[0].hasPrefix("/") {
            guard let recovered=recoverConfiguration(context) else { return nil }
            arguments=[recovered]
        }
        guard let directives=directives(arguments[0], context: context) else { return nil }
        return .init(arguments: arguments, path: arguments[0], pidFile: directives["pidfile"], log: directives["logfile"].flatMap { $0.hasPrefix("/") ? $0 : nil })
    }
    private func directives(_ path: String, context: DeveloperInstanceRecipeContext) -> [String:String]? {
        guard let bytes=try? context.read(path), let text=String(data: bytes, encoding: .utf8) else { return nil }
        var values=[String:String]()
        for line in text.split(whereSeparator: \.isNewline) {
            let pair=line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard pair.count == 2, ["pidfile","logfile","dir"].contains(String(pair[0])) else { continue }
            let key=String(pair[0]), value=String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard values[key] == nil else { return nil }
            values[key]=value
        }
        return values
    }
    private func recoverConfiguration(_ context: DeveloperInstanceRecipeContext) -> String? {
        let keg=URL(fileURLWithPath: context.executable).deletingLastPathComponent().deletingLastPathComponent()
        let version=context.version ?? (keg.path.contains("/Cellar/") ? keg.lastPathComponent : nil)
        let major=version?.split(separator: ".").first.map(String.init)
        var candidates=[String]()
        if let major, major.range(of: "^[0-9]{1,3}$", options: .regularExpression) != nil {
            for root in ["Library/PhpWebStudy/server/redis", "Library/FlyEnv/server/redis", "Library/Application Support/FlyEnv/server/redis"] {
                candidates.append(context.home.appendingPathComponent(root + "/redis-" + major + ".conf").path)
            }
        }
        for prefix in ["/opt/homebrew", "/usr/local"] where context.executable.hasPrefix(prefix + "/Cellar/") { candidates.append(prefix + "/etc/redis.conf") }
        let matches=candidates.filter { candidate in
            guard let values=directives(candidate, context: context), let directory=values["dir"], directory.hasPrefix("/"),
                  NativeDeveloperInstancePaths.physical(directory) == NativeDeveloperInstancePaths.physical(context.directory),
                  let pidPath=values["pidfile"], pidPath.hasPrefix("/"), let bytes=try? context.read(pidPath), let pid=String(data: bytes, encoding: .utf8) else { return false }
            return Int32(pid.trimmingCharacters(in: .whitespacesAndNewlines)) == context.pid
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
#endif
