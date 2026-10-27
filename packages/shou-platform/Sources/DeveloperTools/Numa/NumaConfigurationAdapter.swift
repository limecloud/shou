import Foundation
import ShouCore
#if os(macOS)

struct NumaConfigurationAdapter: DeveloperConfigurationAdapting {
    let toolID="numa"
    func configuration(arguments: [String]) -> String? { arguments.dropFirst().first.flatMap(DeveloperConfigurationPaths.absolute) }
    func storedConfigurations(root: URL, installation: DeveloperToolInstallation) -> [String] { [root.appendingPathComponent("numa/numa.toml").path] }
    func storedLogs(root: URL, installation: DeveloperToolInstallation) -> [DeveloperLogTarget] {
        DeveloperConfigurationPaths.startupLogs(tool:toolID,root:root,version:installation.version)
    }
}
#endif
