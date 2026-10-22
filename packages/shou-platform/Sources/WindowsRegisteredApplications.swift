import Foundation
import ShouCore
#if os(Windows)
import CShouWindows
#endif

public struct WindowsRegisteredApplications: Sendable {
    public typealias Read = @Sendable (ApplicationCatalogOptions) throws -> Data
    private let reader: Read?
    public init(reader: Read? = nil) { self.reader=reader }
    private struct Payload: Decodable {
        let sources: [ApplicationSourceCoverage]
        let items: [RegisteredApplication]
        let issues: [ApplicationCatalogIssue]
    }
    public func read(options: ApplicationCatalogOptions = ApplicationCatalogOptions()) throws -> RegisteredApplicationCatalog {
        try options.validate()
        if Task.isCancelled { throw ShouError("cancelled", "Application inventory stopped.") }
        let data: Data
        if let reader { data=try reader(options) }
        else {
            #if os(Windows)
            let value=try WindowsNative.string({ result in
                shou_win_application_inventory(options.includeSystem ? 1 : 0, options.maxEntries, UInt32(options.maxSeconds * 1000), { _ in Task.isCancelled ? 1 : 0 }, nil, result)
            }, path: "Windows application registrations")
            data=Data(value.utf8)
            #else
            throw ShouError("unsupported_platform", "Windows application registration inventory requires Windows.")
            #endif
        }
        if Task.isCancelled { throw ShouError("cancelled", "Application inventory stopped.") }
        guard data.count <= 8 * 1024 * 1024 else { throw ShouError("resource_limit", "Application evidence exceeds its output limit.") }
        let payload=try Codec.decode(Payload.self, from: data)
        let registry: Set<String>=["windows.user_uninstall64", "windows.user_uninstall32", "windows.machine_uninstall64", "windows.machine_uninstall32"]
        let expected=registry.union(["windows.user_packages"])
        let key="Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall"
        func sourcePath(_ id: String) -> String {
            if id == "windows.user_packages" { return "current_user:PackageManager" }
            return (id.hasPrefix("windows.machine_") ? "HKEY_LOCAL_MACHINE\\" : "HKEY_CURRENT_USER\\") + key
        }
        let counts=Dictionary(grouping: payload.items, by: \.sourceId).mapValues(\.count)
        func printable(_ text: String, maximum: Int = 32768) -> Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximum && text.rangeOfCharacter(from: .controlCharacters) == nil
        }
        func digest(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
        let totalEntries=payload.sources.reduce(0) { $0 + max(0, min(options.maxEntries + 1, $1.entryCount)) }
        guard payload.sources.count == expected.count, Set(payload.sources.map { $0.source.id }) == expected,
              payload.items.count <= options.maxEntries, totalEntries <= options.maxEntries,
              Set(payload.items.map(\.id)).count == payload.items.count, payload.issues.count <= 128,
              payload.sources.allSatisfy({ source in
                  ["complete", "missing", "partial", "unavailable", "not_scanned"].contains(source.status) &&
                  source.entryCount >= source.applicationCount && source.applicationCount >= 0 && source.entryCount <= options.maxEntries &&
                  source.applicationCount == (counts[source.source.id] ?? 0) && printable(source.source.path) &&
                  source.source.path == sourcePath(source.source.id) && source.source.systemOwned == source.source.id.hasPrefix("windows.machine_") &&
                  (!["missing", "unavailable", "not_scanned"].contains(source.status) || source.applicationCount == 0)
              }),
              payload.items.allSatisfy({ item in
                  expected.contains(item.sourceId) && printable(item.registration) && printable(item.name, maximum: 2048) &&
                  item.id == Digest.sha256(Data((item.sourceId + "\0" + item.registration).utf8)) && digest(item.evidenceDigest) &&
                  (item.version.map { printable($0, maximum: 1024) } ?? true) &&
                  (item.publisher.map { printable($0, maximum: 2048) } ?? true) &&
                  (item.installLocation.map { path in
                      printable(path) && path.range(of: "^[A-Za-z]:/", options: .regularExpression) != nil &&
                      !path.contains("\\") && !path.contains("//") && !path.dropFirst(2).contains(":") &&
                      !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
                  } ?? true) &&
                  (item.estimatedBytes.map { $0 >= 0 } ?? true) && (options.includeSystem || !item.systemComponent) &&
                  (registry.contains(item.sourceId) ? ["desktop", "msi"].contains(item.kind) && item.packageFamilyName == nil &&
                      item.registration.hasPrefix(sourcePath(item.sourceId) + "\\") &&
                      !item.registration.dropFirst(sourcePath(item.sourceId).count + 1).contains("\\") &&
                      !item.registration.dropFirst(sourcePath(item.sourceId).count + 1).isEmpty && item.uninstallAvailable != nil :
                      item.kind == "msix" && item.estimatedBytes == nil && item.uninstallAvailable == nil &&
                      item.registration.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]+$", options: .regularExpression) != nil &&
                      item.packageFamilyName.map { printable($0, maximum: 255) && $0.range(of: "^[A-Za-z0-9.-]+_[A-Za-z0-9]+$", options: .regularExpression) != nil } == true)
              }), payload.issues.allSatisfy({ printable($0.path) && printable($0.code, maximum: 128) }) else {
            throw ShouError("invalid_application_evidence", "Application registration identities or source coverage are inconsistent.")
        }
        return RegisteredApplicationCatalog(checkedAt: Date(), sources: payload.sources,
            items: payload.items.sorted { ($0.name, $0.registration, $0.sourceId) < ($1.name, $1.registration, $1.sourceId) }, issues: payload.issues)
    }
}
