import Foundation
import ShouCore
#if os(macOS)

struct MailpitConfigurationAdapter: DeveloperConfigurationAdapting {
    let toolID="mailpit"
    // Mailpit takes MP_* environment values, not a --config-file argument.
    func configuration(arguments: [String]) -> String? { nil }
    func storedConfigurations(root: URL, installation: DeveloperToolInstallation) -> [String] { [root.appendingPathComponent("mailpit/mailpit.conf").path] }
    func storedLogs(root: URL, installation: DeveloperToolInstallation) -> [DeveloperLogTarget] {
        [.init(path:root.appendingPathComponent("mailpit/mailpit.log").path,title:"Service Log")]
    }
    func logs(document: DeveloperConfigurationDocument) -> [DeveloperLogTarget] {
        document.text.split(whereSeparator:\.isNewline).compactMap { line in
            let parts=line.trimmingCharacters(in:.whitespaces).split(separator:"=",maxSplits:1)
            guard parts.count == 2, parts[0].trimmingCharacters(in:.whitespaces) == "MP_LOG_FILE" else { return nil }
            var path=parts[1].trimmingCharacters(in:.whitespaces)
            if (path.hasPrefix("\"") && path.hasSuffix("\"")) || (path.hasPrefix("'") && path.hasSuffix("'")) { path=String(path.dropFirst().dropLast()) }
            guard let absolute=DeveloperConfigurationPaths.absolute(path) else { return nil }
            return .init(path:absolute,title:"Service Log")
        }
    }
}
#endif
