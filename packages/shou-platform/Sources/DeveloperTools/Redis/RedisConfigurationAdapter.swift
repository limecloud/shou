import Foundation
#if os(macOS)

struct RedisConfigurationAdapter: DeveloperConfigurationAdapting {
    let toolID="redis"
    func homebrewPath(token: String) -> String? { "/etc/redis.conf" }
    func configuration(arguments: [String]) -> String? { arguments.dropFirst().first.flatMap(DeveloperConfigurationPaths.absolute) }
    func logs(document: DeveloperConfigurationDocument) -> [DeveloperLogTarget] {
        document.text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts=line.trimmingCharacters(in:.whitespaces).split(maxSplits:1,whereSeparator: \.isWhitespace)
            guard parts.count == 2, parts[0] == "logfile",
                  let path=DeveloperConfigurationPaths.absolute(String(parts[1]).trimmingCharacters(in:CharacterSet(charactersIn:"\"\'"))) else { return nil }
            return .init(path:path,title:"Service Log")
        }
    }
}
#endif
