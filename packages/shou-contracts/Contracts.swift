import Foundation

public enum ShouContracts {
    public static func ruleSchema() throws -> Data {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("rule.schema.json"), FileManager.default.fileExists(atPath: url.path) {
            return try Data(contentsOf: url)
        }
        guard let url = Bundle.module.url(forResource: "rule.schema", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}
