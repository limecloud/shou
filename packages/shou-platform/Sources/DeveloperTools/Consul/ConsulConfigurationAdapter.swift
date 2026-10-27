import Foundation
import ShouCore
#if os(macOS)

struct ConsulConfigurationAdapter: DeveloperConfigurationAdapting {
    let toolID="consul"
    func configuration(arguments: [String]) -> String? {
        DeveloperConfigurationPaths.option("-config-file",in:arguments).flatMap(DeveloperConfigurationPaths.absolute)
    }
    func storedConfigurations(root: URL, installation: DeveloperToolInstallation) -> [String] {
        guard let version=installation.version, version.range(of:"\\A[0-9]+(?:\\.[0-9]+){1,3}\\z",options:.regularExpression) != nil,
              let major=version.split(separator:".").first else { return [] }
        return [root.appendingPathComponent("consul/consul-" + major + ".json").path]
    }
    func storedLogs(root: URL, installation: DeveloperToolInstallation) -> [DeveloperLogTarget] {
        [.init(path:root.appendingPathComponent("consul/consul.log").path,title:"Service Log")]
    }
}
#endif
