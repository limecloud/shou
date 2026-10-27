import Foundation
import ShouCore
#if os(macOS)

struct MeilisearchConfigurationAdapter: DeveloperConfigurationAdapting {
    let toolID="meilisearch"
    func homebrewPath(token: String) -> String? { "/etc/meilisearch.toml" }
    func configuration(arguments: [String]) -> String? {
        DeveloperConfigurationPaths.option("--config-file-path",in:arguments).flatMap(DeveloperConfigurationPaths.absolute)
    }
    func storedConfigurations(root: URL, installation: DeveloperToolInstallation) -> [String] { [root.appendingPathComponent("meilisearch/meilisearch.toml").path] }
    func storedLogs(root: URL, installation: DeveloperToolInstallation) -> [DeveloperLogTarget] {
        DeveloperConfigurationPaths.startupLogs(tool:toolID,root:root,version:installation.version)
    }
}
#endif
