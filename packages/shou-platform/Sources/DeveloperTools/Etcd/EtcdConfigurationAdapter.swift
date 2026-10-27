import Foundation
import ShouCore
#if os(macOS)

struct EtcdConfigurationAdapter: DeveloperConfigurationAdapting {
    let toolID="etcd"
    func configuration(arguments: [String]) -> String? {
        DeveloperConfigurationPaths.option("--config-file",in:arguments).flatMap(DeveloperConfigurationPaths.absolute)
    }
    func storedConfigurations(root: URL, installation: DeveloperToolInstallation) -> [String] { [root.appendingPathComponent("etcd/etcd.yaml").path] }
    func storedLogs(root: URL, installation: DeveloperToolInstallation) -> [DeveloperLogTarget] {
        DeveloperConfigurationPaths.startupLogs(tool:toolID,root:root,version:installation.version)
    }
}
#endif
