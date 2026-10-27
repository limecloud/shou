import Foundation
import ShouCore
#if os(macOS)

struct CaddyConfigurationAdapter: DeveloperConfigurationAdapting {
    let toolID="caddy"
    func homebrewPath(token: String) -> String? { "/etc/Caddyfile" }
    func configuration(arguments: [String]) -> String? {
        DeveloperConfigurationPaths.option("--config",in:arguments).flatMap(DeveloperConfigurationPaths.absolute)
    }
    func storedConfigurations(root: URL, installation: DeveloperToolInstallation) -> [String] { [root.appendingPathComponent("caddy/Caddyfile").path] }
    func storedLogs(root: URL, installation: DeveloperToolInstallation) -> [DeveloperLogTarget] {
        [.init(path:root.appendingPathComponent("caddy/caddy.log").path,title:"Service Log")]
    }
}
#endif
