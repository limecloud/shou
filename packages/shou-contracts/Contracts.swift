import Foundation

public enum ShouContracts {
    public static func ruleSchema() throws -> Data {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("rule.schema.json"), FileManager.default.fileExists(atPath: url.path) {
            return try readResource(url)
        }
        guard let url = Bundle.module.url(forResource: "rule.schema", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try readResource(url)
    }

    private static func readResource(_ url: URL) throws -> Data {
        for attempt in 0..<3 {
            do { return try Data(contentsOf: url) }
            catch {
                var cause=error as NSError
                while let underlying=cause.userInfo[NSUnderlyingErrorKey] as? NSError { cause=underlying }
                // Child-process signals may interrupt Foundation's resource read.
                // Retry only EINTR; missing or unreadable resources still fail.
                guard attempt < 2, cause.domain == NSPOSIXErrorDomain, cause.code == 4 else { throw error }
            }
        }
        throw CocoaError(.fileReadUnknown)
    }
}
