import Foundation

/// Process inspection is independent of filesystem access and never stops applications.
public protocol ApplicationActivityChecking: Sendable {
    func runningBundleIdentifiers(in identifiers: Set<String>) throws -> Set<String>
}

public struct UnavailableApplicationActivity: ApplicationActivityChecking {
    public init() {}
    public func runningBundleIdentifiers(in identifiers: Set<String>) throws -> Set<String> {
        throw ShouError("application_activity_unavailable", "Application activity could not be checked.")
    }
}

public enum ApplicationSafety {
    public static func blockedRules(_ ruleIds: [String], activity: any ApplicationActivityChecking) -> [String: String] {
        do {
            let requested=Set(ruleIds)
            let relevant=try BuiltinCatalog.templates().filter { requested.contains($0.id) && !($0.applicationBundleIdentifiers ?? []).isEmpty }
                .reduce(into: [String: Set<String>]()) { $0[$1.id]=Set($1.applicationBundleIdentifiers ?? []) }
            guard !relevant.isEmpty else { return [:] }
            let identifiers=relevant.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            let running: Set<String>
            do { running=try activity.runningBundleIdentifiers(in: identifiers) }
            catch { return Dictionary(uniqueKeysWithValues: relevant.keys.map { ($0, "application_activity_unavailable") }) }
            return relevant.reduce(into: [:]) { result, pair in
                if !pair.value.isDisjoint(with: running) { result[pair.key]="application_running" }
            }
        } catch {
            // Missing rule metadata cannot silently remove an application's gate.
            return Dictionary(uniqueKeysWithValues: Set(ruleIds.filter { $0.hasPrefix(BuiltinCatalog.prefix) }).map { ($0, "application_activity_unavailable") })
        }
    }
}
