import Foundation
import ShouCore
#if os(macOS)

struct NginxConfigurationAdapter: DeveloperConfigurationAdapting {
    let toolID="nginx"
    func homebrewPath(token: String) -> String? { "/etc/nginx/nginx.conf" }
    func storedConfigurations(root: URL, installation: DeveloperToolInstallation) -> [String] { [root.appendingPathComponent("nginx/common/conf/nginx.conf").path] }
    func storedLogs(root: URL, installation: DeveloperToolInstallation) -> [DeveloperLogTarget] {
        [.init(path:root.appendingPathComponent("nginx/common/logs/error.log").path,title:"Error Log"),
         .init(path:root.appendingPathComponent("nginx/common/logs/access.log").path,title:"Access Log")]
    }
    func configuration(arguments: [String]) -> String? {
        DeveloperConfigurationPaths.option("-c",in:arguments).flatMap(DeveloperConfigurationPaths.absolute)
    }
    func logs(document: DeveloperConfigurationDocument) -> [DeveloperLogTarget] {
        var values=[DeveloperLogTarget]()
        for line in document.text.split(whereSeparator: \.isNewline) {
            let parts=line.trimmingCharacters(in:.whitespaces).split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, ["error_log","access_log"].contains(parts[0]),
                  let path=DeveloperConfigurationPaths.absolute(String(parts[1]).trimmingCharacters(in:CharacterSet(charactersIn:";\"\'"))) else { continue }
            values.append(.init(path:path,title:parts[0] == "error_log" ? "Error Log" : "Access Log"))
        }
        return values
    }
}
#endif
