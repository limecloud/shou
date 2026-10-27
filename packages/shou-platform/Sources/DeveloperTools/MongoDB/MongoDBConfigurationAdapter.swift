import Foundation
#if os(macOS)

struct MongoDBConfigurationAdapter: DeveloperConfigurationAdapting {
    let toolID="mongodb"
    func homebrewPath(token: String) -> String? { "/etc/mongod.conf" }
    func configuration(arguments: [String]) -> String? {
        (DeveloperConfigurationPaths.option("--config",in:arguments) ?? DeveloperConfigurationPaths.option("-f",in:arguments)).flatMap(DeveloperConfigurationPaths.absolute)
    }
}
#endif
