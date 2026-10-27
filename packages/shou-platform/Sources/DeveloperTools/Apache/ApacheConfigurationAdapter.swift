import Foundation
import ShouCore
#if os(macOS)
import CryptoKit

struct ApacheConfigurationAdapter: DeveloperConfigurationAdapting {
    let toolID="apache"
    func homebrewPath(token: String) -> String? { "/etc/httpd/httpd.conf" }
    func configuration(arguments: [String]) -> String? {
        DeveloperConfigurationPaths.option("-f",in:arguments).flatMap(DeveloperConfigurationPaths.absolute)
    }
    func storedConfigurations(root: URL, installation: DeveloperToolInstallation) -> [String] {
        let paths=installation.launchPaths + [installation.path,installation.path + "/bin/httpd",installation.path + "/sbin/httpd"]
        return paths.prefix(32).map { path in
            // The reference uses MD5 only as a filename derived from bin, not as
            // integrity evidence. Preserve the original lexical launch path.
            let name=Insecure.MD5.hash(data:Data(path.utf8)).map { String(format:"%02x",$0) }.joined()
            return root.appendingPathComponent("apache/common/conf/" + name + ".conf").path
        }
    }
    func storedLogs(root: URL, installation: DeveloperToolInstallation) -> [DeveloperLogTarget] {
        [.init(path:root.appendingPathComponent("apache/common/logs/error_log").path,title:"Error Log"),
         .init(path:root.appendingPathComponent("apache/common/logs/access_log").path,title:"Access Log")]
    }
    func logs(document: DeveloperConfigurationDocument) -> [DeveloperLogTarget] {
        document.text.split(whereSeparator:\.isNewline).compactMap { line in
            let parts=line.trimmingCharacters(in:.whitespaces).split(maxSplits:1,whereSeparator:\.isWhitespace)
            guard parts.count == 2, ["ErrorLog","CustomLog","TransferLog"].contains(parts[0]) else { return nil }
            let rest=String(parts[1]), path: String
            if rest.hasPrefix("\""), let end=rest.dropFirst().firstIndex(of:"\"") { path=String(rest[rest.index(after:rest.startIndex)..<end]) }
            else { path=String(rest.split(whereSeparator:\.isWhitespace).first ?? "") }
            guard let absolute=DeveloperConfigurationPaths.absolute(path) else { return nil }
            return .init(path:absolute,title:parts[0] == "ErrorLog" ? "Error Log" : "Access Log")
        }
    }
}
#endif
