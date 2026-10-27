import Foundation
#if os(macOS)

struct PostgreSQLConfigurationAdapter: DeveloperConfigurationAdapting {
    let toolID="postgresql"
    func homebrewPath(token: String) -> String? { "/var/" + token + "/postgresql.conf" }
    func configuration(arguments: [String]) -> String? {
        DeveloperConfigurationPaths.option("-D",in:arguments).flatMap(DeveloperConfigurationPaths.absolute).map { $0 + "/postgresql.conf" }
    }
}
#endif
