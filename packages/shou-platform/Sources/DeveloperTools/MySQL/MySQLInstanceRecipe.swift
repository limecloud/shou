import Foundation
import ShouCore
#if os(macOS)
import Darwin

struct MySQLInstanceRecipe: DeveloperInstanceRecipeAdapting {
    let toolID="mysql", executableName="mysqld"
    func explicitConfiguration(in arguments: [String]) -> String? {
        guard arguments.count > 1, arguments[1].hasPrefix("--defaults-file=/"),
              arguments.filter({ $0.hasPrefix("--defaults-file=") }).count == 1 else { return nil }
        return String(arguments[1].dropFirst("--defaults-file=".count))
    }
    func resolve(_ context: DeveloperInstanceRecipeContext) -> DeveloperInstanceConfiguration? {
        let arguments=Array(context.arguments.dropFirst())
        let paths=["--defaults-file","--basedir","--datadir","--plugin-dir","--pid-file","--log-error","--slow-query-log-file","--socket","--mysqlx-socket","--lc-messages-dir"]
        let ports=["--port","--mysqlx-port"]
        let allowed=paths + ports + ["--bind-address","--mysqlx-bind-address","--user"]
        var options=[String:String]()
        for argument in arguments {
            let pair=argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[1].isEmpty else { return nil }
            let key=String(pair[0]), value=String(pair[1])
            guard allowed.contains(key), options[key] == nil else { return nil }
            if paths.contains(key) && !value.hasPrefix("/") { return nil }
            if ports.contains(key) && !(Int(value).map { (1...65535).contains($0) } ?? false) { return nil }
            // The enclosing process check already requires the current uid.
            // Existing unprivileged mysqld_safe launches commonly retain
            // --user=mysql; no uid transition or privilege elevation is added.
            if key == "--user", value != "mysql", value != NSUserName(), value != String(getuid()) { return nil }
            options[key]=value
        }
        // defaults-file must remain first: MySQL interprets option-file switches
        // before its ordinary arguments. Never use its initialization path here.
        guard let config=options["--defaults-file"], arguments.first == "--defaults-file=" + config else { return nil }
        return .init(arguments: arguments, path: config, pidFile: options["--pid-file"], log: options["--log-error"])
    }
    /// Only closed, explicit no-defaults arguments can exclude an unrelated
    /// MySQL data instance. Unknown/abbreviated options remain ambiguous.
    static func dataDirectory(arguments: [String], requireNoDefaults: Bool, configuration: String? = nil) -> String? {
        let args=Array(arguments.dropFirst())
        if requireNoDefaults && args.first != "--no-defaults" { return nil }
        let values: Set<String> = ["--datadir","--defaults-file","--basedir","--socket","--pid-file","--log-error","--port","--mysqlx-port","--mysqlx-socket","--bind-address","--mysqlx-bind-address","--user","--mysqlx"]
        var options=[String:String](), seen=Set<String>(), index=0
        while index < args.count {
            let argument=args[index]
            if argument == "--no-defaults" || argument == "--skip-networking" {
                guard seen.insert(argument).inserted, argument != "--no-defaults" || index == 0 else { return nil }
                index += 1; continue
            }
            let pair=argument.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
            let key=String(pair[0])
            guard values.contains(key), seen.insert(key).inserted, !(requireNoDefaults && key == "--defaults-file") else { return nil }
            let value: String
            if pair.count == 2 { value=String(pair[1]) }
            else { index += 1; guard index < args.count, !args[index].hasPrefix("--") else { return nil }; value=args[index] }
            guard !value.isEmpty else { return nil }
            options[key]=value; index += 1
        }
        let configured=configuration.flatMap { try? NativeMySQLInstances.registrationOptions($0)["datadir"] }
        guard let data=options["--datadir"] ?? configured, data.hasPrefix("/"), let resolved=realpath(data,nil) else { return nil }
        defer { free(resolved) }
        return String(cString:resolved)
    }
}

#endif
