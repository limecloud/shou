import Foundation
import ShouCore
#if os(macOS)
import Darwin
#endif

public struct NativeApplicationCatalog: ApplicationCatalogReading {
    private let sources: [ApplicationSource]
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, sources: [ApplicationSource]? = nil) {
        self.sources=sources ?? [
            ApplicationSource(id: "macos.user_applications", path: homeDirectory.appendingPathComponent("Applications").path),
            ApplicationSource(id: "macos.local_applications", path: "/Applications"),
            ApplicationSource(id: "macos.system_applications", path: "/System/Applications", systemOwned: true)
        ]
    }

    public func read(options: ApplicationCatalogOptions) throws -> ApplicationCatalog {
        try options.validate()
        #if os(macOS)
        let deadline=ContinuousClock.now.advanced(by: .seconds(options.maxSeconds))
        var visited=0, items: [ApplicationDefinition]=[], issues: [ApplicationCatalogIssue]=[], coverage: [ApplicationSourceCoverage]=[]
        for source in sources where options.includeSystem || !source.systemOwned {
            try checkCancellation()
            let entryStart=visited, itemStart=items.count, issueStart=issues.count
            if visited >= options.maxEntries || ContinuousClock.now >= deadline {
                issues.append(ApplicationCatalogIssue(path: source.path, code: "resource_limit"))
                coverage.append(ApplicationSourceCoverage(source: source, status: "not_scanned", entryCount: 0, applicationCount: 0))
                continue
            }
            let descriptor: Int32
            do { descriptor=try SecurePaths.directory(source.path) }
            catch let error as ShouError {
                if error.code == "cancelled" { throw error }
                let (parent, name) = (try? SecurePaths.parent(source.path)) ?? (-1, "")
                var metadata=stat()
                let missing=parent >= 0 && fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
                if parent >= 0 { close(parent) }
                if !missing { issues.append(ApplicationCatalogIssue(path: source.path, code: error.code)) }
                coverage.append(ApplicationSourceCoverage(source: source, status: missing ? "missing" : "unavailable", entryCount: 0, applicationCount: 0))
                continue
            }
            defer { close(descriptor) }
            func walk(_ descriptor: Int32, path: String, depth: Int) throws {
                try checkCancellation()
                var before=stat()
                guard fstat(descriptor, &before) == 0 else { throw SecurePaths.failure("Read application directory", path: path) }
                let listing=try NativeDefinitionFiles.names(descriptor, limit: max(0, options.maxEntries - visited), deadline: deadline)
                visited += listing.names.count
                if listing.truncated { issues.append(ApplicationCatalogIssue(path: path, code: "resource_limit")) }
                for name in listing.names where !name.hasPrefix(".") {
                    try checkCancellation()
                    guard ContinuousClock.now < deadline else { issues.append(ApplicationCatalogIssue(path: path, code: "resource_limit")); break }
                    let child=path + "/" + name
                    var metadata=stat()
                    guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                        issues.append(ApplicationCatalogIssue(path: child, code: "unreadable_entry")); continue
                    }
                    guard name.rangeOfCharacter(from: .controlCharacters) == nil else {
                        if metadata.st_mode & S_IFMT == S_IFDIR || name.lowercased().hasSuffix(".app") {
                            issues.append(ApplicationCatalogIssue(path: child, code: "invalid_filename"))
                        }
                        continue
                    }
                    if metadata.st_mode & S_IFMT == S_IFLNK {
                        if name.lowercased().hasSuffix(".app") { issues.append(ApplicationCatalogIssue(path: child, code: "linked_application")) }
                        continue
                    }
                    guard metadata.st_mode & S_IFMT == S_IFDIR else { continue }
                    guard metadata.st_dev == before.st_dev else { issues.append(ApplicationCatalogIssue(path: child, code: "cross_filesystem")); continue }
                    if name.lowercased().hasSuffix(".app") {
                        do {
                            let (application, issue)=try definition(at: child, source: source, deadline: deadline)
                            items.append(application)
                            if let issue { issues.append(ApplicationCatalogIssue(path: child, code: issue)) }
                        } catch let error as ShouError {
                            if error.code == "cancelled" { throw error }
                            issues.append(ApplicationCatalogIssue(path: child, code: error.code))
                        }
                    } else if depth < 2 {
                        do {
                            let nested=try SecurePaths.directory(child)
                            defer { close(nested) }
                            try walk(nested, path: child, depth: depth + 1)
                        } catch let error as ShouError {
                            if error.code == "cancelled" { throw error }
                            issues.append(ApplicationCatalogIssue(path: child, code: error.code))
                        }
                    } else { issues.append(ApplicationCatalogIssue(path: child, code: "depth_limit")) }
                }
                var after=stat()
                let (parent, name)=try SecurePaths.parent(path)
                defer { close(parent) }
                guard fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
                      SecurePaths.entry(before, path: ".") == SecurePaths.entry(after, path: ".") else {
                    issues.append(ApplicationCatalogIssue(path: path, code: "source_changed")); return
                }
            }
            do { try walk(descriptor, path: source.path, depth: 0) }
            catch let error as ShouError {
                if error.code == "cancelled" { throw error }
                issues.append(ApplicationCatalogIssue(path: source.path, code: error.code))
            }
            coverage.append(ApplicationSourceCoverage(source: source, status: issues.count == issueStart ? "complete" : "partial",
                entryCount: visited - entryStart, applicationCount: items.count - itemStart))
        }
        try checkCancellation()
        return ApplicationCatalog(checkedAt: Date(), sources: coverage, items: items.sorted { ($0.name, $0.path) < ($1.name, $1.path) }, issues: issues)
        #else
        throw ShouError("unsupported_platform", "Application discovery is currently available only on macOS.")
        #endif
    }

    public func application(at path: String) throws -> ApplicationDefinition {
        #if os(macOS)
        try checkCancellation()
        let components=try SecurePaths.components(path)
        guard "/" + components.joined(separator: "/") == path,
              path.rangeOfCharacter(from: .controlCharacters) == nil,
              components.last?.lowercased().hasSuffix(".app") == true,
              let source=sources.first(where: { source in
                  guard path.hasPrefix(source.path + "/") else { return false }
                  let relative=String(path.dropFirst(source.path.count + 1)).split(separator: "/")
                  return (1...3).contains(relative.count) && !relative.dropLast().contains { $0.lowercased().hasSuffix(".app") }
              }) else { throw ShouError("invalid_argument", "Application path is outside supported application directories.") }
        return try definition(at: path, source: source, deadline: ContinuousClock.now.advanced(by: .seconds(5))).0
        #else
        throw ShouError("unsupported_platform", "Application discovery is currently available only on macOS.")
        #endif
    }

    #if os(macOS)
    private func checkCancellation() throws {
        if Task.isCancelled { throw ShouError("cancelled", "Application discovery stopped.") }
    }

    private func definition(at path: String, source: ApplicationSource, deadline: ContinuousClock.Instant) throws -> (ApplicationDefinition, String?) {
        let directory=try SecurePaths.directory(path)
        defer { close(directory) }
        var before=stat()
        guard fstat(directory, &before) == 0 else { throw SecurePaths.failure("Inspect application", path: path) }
        var name=URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var identifier: String?, version: String?, executable: String?, infoDigest: String?, issue: String?
        do {
            let contents=openat(directory, "Contents", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard contents >= 0 else { throw ShouError("unsupported_bundle", "Application metadata uses an unsupported bundle layout.") }
            defer { close(contents) }
            let data=try NativeDefinitionFiles.bytes(directory: contents, name: "Info.plist", path: path + "/Contents/Info.plist", deadline: deadline)
            guard let values=try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  values["CFBundlePackageType"] == nil || values["CFBundlePackageType"] as? String == "APPL" else {
                throw ShouError("invalid_application_metadata", "Application metadata could not be interpreted.")
            }
            let bundleId=values["CFBundleIdentifier"] as? String
            guard let bundleId, bundleId.utf8.count <= 255,
                  bundleId.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else {
                throw ShouError("invalid_bundle_identifier", "Application bundle identifier is unavailable or unsupported.")
            }
            identifier=bundleId; infoDigest=Digest.sha256(data)
            if let value=(values["CFBundleDisplayName"] ?? values["CFBundleName"]) as? String, printable(value, limit: 512) { name=value }
            if let value=(values["CFBundleShortVersionString"] ?? values["CFBundleVersion"]) as? String, printable(value, limit: 128) { version=value }
            if let value=values["CFBundleExecutable"] as? String, printable(value, limit: 255), !value.contains("/"), ![".", ".."].contains(value) { executable=value }
        } catch let error as ShouError {
            if error.code == "cancelled" { throw error }
            issue=error.code
        } catch { issue="invalid_application_metadata" }
        var after=stat()
        let (parent, leaf)=try SecurePaths.parent(path)
        defer { close(parent) }
        guard fstatat(parent, leaf, &after, AT_SYMLINK_NOFOLLOW) == 0,
              SecurePaths.entry(before, path: ".") == SecurePaths.entry(after, path: ".") else {
            throw ShouError("application_changed", "Application changed while reading its metadata.")
        }
        return (ApplicationDefinition(path: path, source: source, identity: SecurePaths.entry(before, path: "."),
            name: name, bundleIdentifier: identifier, version: version, executableName: executable, infoDigest: infoDigest), issue)
    }

    private func printable(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= limit && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
    #endif
}
