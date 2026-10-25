import Foundation

public struct ApplicationUpdateSource: Codable, Sendable, Equatable {
    public let provider: String
    public let token: String
    public let metadataURL: String
    public let officialURL: String

    public static func homebrewCask(token: String) throws -> Self {
        guard token.utf8.count <= 100, token.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else {
            throw ShouError("invalid_argument", "Invalid application catalog identifier.")
        }
        return Self(provider: "homebrew_cask", token: token,
            metadataURL: "https://formulae.brew.sh/api/cask/" + token + ".json",
            officialURL: "https://formulae.brew.sh/cask/" + token)
    }
}

public enum ApplicationUpdateState: String, Codable, Sendable {
    case newerCatalogVersion = "newer_catalog_version"
    case sameCatalogVersion = "same_catalog_version"
    case installedVersionNewer = "installed_version_newer"
    case unsupported, unknown
}

public struct ApplicationUpdateObservation: Codable, Sendable {
    public let formatVersion: Int
    public let application: ApplicationDefinition
    public let observedAt: Date
    public let source: ApplicationUpdateSource?
    public let installedVersion: String?
    public let catalogVersion: String?
    public let state: ApplicationUpdateState
    public let issues: [String]
    public let status: String
}

/// The single supported remote source receives a catalog token, never an app
/// inventory, local path or user identity. Installation is outside this API.
public protocol HomebrewCaskReading: Sendable {
    func metadata(token: String) async throws -> Data
}

public struct ApplicationUpdateEnvironment: Sendable {
    public let architecture: String
    public let systemVersion: String
    public init(architecture: String, systemVersion: String) {
        self.architecture=architecture; self.systemVersion=systemVersion
    }
}

public struct ApplicationUpdateChecker: Sendable {
    public static let maximumMetadataBytes = 1_048_576
    private let catalog: any ApplicationCatalogReading
    private let remote: any HomebrewCaskReading
    private let environment: ApplicationUpdateEnvironment

    public init(catalog: any ApplicationCatalogReading, remote: any HomebrewCaskReading, environment: ApplicationUpdateEnvironment) {
        self.catalog=catalog; self.remote=remote; self.environment=environment
    }

    public static func source(for application: ApplicationDefinition) throws -> ApplicationUpdateSource? {
        struct Mapping: Decodable { let bundleIdentifier: String; let bundleName: String; let token: String }
        guard !application.source.systemOwned, let identifier=application.bundleIdentifier, application.infoDigest != nil else { return nil }
        guard let url=CoreResources.bundle.url(forResource: "application-update-sources", withExtension: "json") else {
            throw ShouError("io_error", "Application update sources are unavailable.")
        }
        let mappings=try JSONDecoder().decode([Mapping].self, from: Data(contentsOf: url))
        guard let match=mappings.first(where: { $0.bundleIdentifier == identifier && $0.bundleName == URL(fileURLWithPath: application.path).lastPathComponent }) else { return nil }
        return try .homebrewCask(token: match.token)
    }

    @concurrent public func check(path: String, expectedApplication: ApplicationDefinition? = nil) async throws -> ApplicationUpdateObservation {
        try Task.checkCancellation()
        let application=try catalog.application(at: path)
        if let expectedApplication, expectedApplication != application {
            throw ShouError("application_changed", "Application changed. Scan applications again before checking its catalog version.")
        }
        let source=try Self.source(for: application)
        guard let source else { return Self.observation(application, source: nil, state: .unsupported, issue: "update_source_unsupported") }
        guard Self.numericVersion(application.version) != nil else {
            return Self.observation(application, source: source, state: .unknown, issue: "update_version_ambiguous")
        }
        let data: Data
        do { data=try await remote.metadata(token: source.token) }
        catch {
            try Task.checkCancellation()
            guard try catalog.application(at: path) == application else {
                throw ShouError("application_changed", "Application changed while checking its catalog version. Scan applications again.")
            }
            let allowed=["update_network_unavailable", "update_response_invalid", "update_response_too_large", "update_redirect_refused", "update_authentication_refused"]
            let code=(error as? ShouError)?.code ?? "update_network_unavailable"
            return Self.observation(application, source: source, state: .unknown, issue: allowed.contains(code) ? code : "update_network_unavailable")
        }
        try Task.checkCancellation()
        guard try catalog.application(at: path) == application else {
            throw ShouError("application_changed", "Application changed while checking its catalog version. Scan applications again.")
        }
        return Self.evaluate(application: application, source: source, data: data, environment: environment)
    }

    public static func evaluate(application: ApplicationDefinition, source: ApplicationUpdateSource, data: Data,
                                environment: ApplicationUpdateEnvironment) -> ApplicationUpdateObservation {
        func unknown(_ issue: String) -> ApplicationUpdateObservation {
            observation(application, source: source, state: .unknown, issue: issue)
        }
        guard data.count <= maximumMetadataBytes else { return unknown("update_response_too_large") }
        guard let expected=try? Self.source(for: application), expected == source,
              let value=try? JSONDecoder().decode(JSONValue.self, from: data), let base=value.object,
              base["token"]?.string == source.token else { return unknown("update_source_mismatch") }
        guard ["arm64", "x86_64"].contains(environment.architecture), let os=numericVersion(environment.systemVersion), let major=os.first else {
            return unknown("update_platform_unknown")
        }
        let names=[11: "big_sur", 12: "monterey", 13: "ventura", 14: "sonoma", 15: "sequoia", 26: "tahoe"]
        guard let osName=names[major] else { return unknown("update_platform_unknown") }
        var metadata=base
        if let variations=base["variations"]?.object {
            let specific=environment.architecture == "arm64" ? "arm64_" + osName : osName
            if let value=variations[specific] {
                guard let variation=value.object else { return unknown("update_response_invalid") }
                metadata.merge(variation) { _, new in new }
            } else if environment.architecture == "arm64", let otherVersion=variations[osName]?["version"], otherVersion != base["version"] {
                return unknown("update_platform_unknown")
            }
        } else if base["variations"] != nil { return unknown("update_response_invalid") }
        guard let artifacts=metadata["artifacts"]?.array,
              artifacts.contains(where: { $0["app"]?.array?.first?.string == URL(fileURLWithPath: application.path).lastPathComponent }) else {
            return unknown("update_source_mismatch")
        }
        if metadata["disabled"] == .bool(true) { return unknown("update_catalog_disabled") }
        if let architecture=metadata["arch"], architecture != .null { return unknown("update_platform_unknown") }
        if let constraints=metadata["depends_on"]?["macos"]?.object {
            for (operation, values) in constraints {
                guard let versions=values.array, !versions.isEmpty,
                      let parsed=try? versions.map({ item -> [Int] in
                          guard let version=numericVersion(item.string) else { throw ShouError("invalid_version", "Unknown version") }
                          return version
                      }) else { return unknown("update_platform_unknown") }
                let matches=parsed.contains { required in
                    let order=compare(os, required)
                    switch operation {
                    case ">=": return order != .orderedAscending
                    case ">": return order == .orderedDescending
                    case "<=": return order != .orderedDescending
                    case "<": return order == .orderedAscending
                    case "==": return order == .orderedSame
                    default: return false
                    }
                }
                guard matches else { return unknown("update_system_unsupported") }
            }
        } else if let macOS=metadata["depends_on"]?["macos"], macOS != .null { return unknown("update_platform_unknown") }
        guard let version=metadata["version"]?.string, let available=numericVersion(version), let current=numericVersion(application.version) else {
            return unknown("update_version_ambiguous")
        }
        let order=compare(available, current)
        return observation(application, source: source, catalogVersion: version,
            state: order == .orderedDescending ? .newerCatalogVersion : order == .orderedAscending ? .installedVersionNewer : .sameCatalogVersion)
    }

    /// Only unambiguous dotted numeric marketing versions are comparable. A
    /// cask build suffix, prerelease or rolling version remains unknown.
    private static func numericVersion(_ value: String?) -> [Int]? {
        guard let value, value.utf8.count <= 96 else { return nil }
        let parts=value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...8).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        return parts.compactMap { Int($0) }
    }
    private static func compare(_ left: [Int], _ right: [Int]) -> ComparisonResult {
        for index in 0..<max(left.count, right.count) {
            let a=index < left.count ? left[index] : 0, b=index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
    private static func observation(_ application: ApplicationDefinition, source: ApplicationUpdateSource?, catalogVersion: String? = nil,
                                    state: ApplicationUpdateState, issue: String? = nil) -> ApplicationUpdateObservation {
        ApplicationUpdateObservation(formatVersion: 1, application: application, observedAt: Date(), source: source, installedVersion: application.version,
            catalogVersion: catalogVersion, state: state, issues: issue.map { [$0] } ?? [], status: state == .unknown ? "partial" : "complete")
    }
}
