import Foundation
import ShouCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(Windows) || canImport(Darwin) || canImport(Glibc)
private struct CleanupDirectory {
    let entry: FileEntry
    let depth: Int
}

extension NativeFileSystem {
    /// Find targets before measuring their contents. A large first project may
    /// be incomplete, but cannot consume the quota reserved for later targets.
    func inspectCleanupTree(_ path: String, rules: [CleanupRule], budget: ScanBudget, cancelled: @Sendable () -> Bool,
                            progress: @Sendable (ScanProgress) -> Void) throws -> TreeSnapshot {
        #if !os(Windows)
        let privacy=scanPrivacyPolicy
        try privacy.checkRoot(path)
        #endif
        let root=try CleanupDirectoryAccess(path, cancelled: cancelled)
        defer { withExtendedLifetime(root) {} }
        let rootEntry=try root.entry(relative: ".")
        #if os(Windows)
        let caseSensitive=false
        #else
        let values=try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let caseSensitive=values?.volumeSupportsCaseSensitiveNames ?? true
        #endif
        let prepared=rules.map { rule in (rule, rule.match.relativePatterns.map { PathPattern.Compiled($0, caseSensitive: caseSensitive) }) }
        let markerNames=Set(rules.flatMap { $0.match.projectMarkers?.allOf ?? [] } +
            ["Package.swift", "workspace-state.json", "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile"])
        let exactPatterns=rules.flatMap(\.match.relativePatterns)
        let exactPaths=exactPatterns.allSatisfy { !$0.contains("*") && !$0.contains("?") }
            ? exactPatterns.map { $0.split(separator: "/").map(String.init) } : nil
        let prunedNames: Set<String>=[".git", ".hg", ".svn", ".ssh", ".gnupg", ".shou"]
        let deadline=ContinuousClock.now.advanced(by: .seconds(budget.maxSeconds))
        let discoveryDeadline=ContinuousClock.now.advanced(by: .seconds(budget.maxSeconds / 2))
        let discoveryLimit=max(1, budget.maxEntries / 2)
        var entries=[".": rootEntry], directories=[".": rootEntry]
        var markers=[String: FileEntry]()
        var queue=[CleanupDirectory(entry: rootEntry, depth: 0)], next=0
        var targets=[CleanupDirectory](), issues=[String](), completed=[String]()
        var visited=1
        var limited=false
        func absolute(_ relative: String) -> String { relative == "." ? path : path + "/" + relative }
        func relativeChild(_ parent: String, _ name: String) -> String { parent == "." ? name : parent + "/" + name }
        func remainingSeconds() -> Double {
            let parts=ContinuousClock.now.duration(to: deadline).components
            return max(0, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        }
        func discoverySeconds() -> Double {
            let parts=ContinuousClock.now.duration(to: discoveryDeadline).components
            return max(0, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        }
        func checkpoint() throws {
            if cancelled() || Task.isCancelled { throw ShouError("cancelled", "Scan cancelled.") }
        }
        func limit(_ relative: String) {
            if !limited { issues.append("resource_limit"); limited=true }
            issues.append("resource_limit: " + relative)
        }
        func identity(_ entry: FileEntry) throws -> Bool {
            try checkpoint()
            if ContinuousClock.now >= deadline { limit(entry.path); return false }
            return try CleanupDirectoryAccess.metadata(absolute(entry.path), relative: entry.path, cancelled: cancelled) == entry
        }
        func sameBindings(for target: String) throws -> Bool {
            var ancestor=target
            while true {
                if let expected=directories[ancestor], try !identity(expected) { return false }
                for marker in markerNames {
                    if let expected=markers[relativeChild(ancestor, marker)], try !identity(expected) { return false }
                }
                if ancestor == "." { return true }
                ancestor=StorageIndex.parent(ancestor)
            }
        }

        progress(ScanProgress(stage: "scanning", entryCount: 0, currentPath: path))
        while next < queue.count {
            try checkpoint()
            let item=queue[next]
            next += 1
            if visited >= discoveryLimit || ContinuousClock.now >= discoveryDeadline { limit(item.entry.path); break }
            if item.depth > budget.maxDepth { limit(item.entry.path); continue }
            let pending=queue.count - next + 1
            let quota=max(1, (discoveryLimit - visited) / pending)
            do {
                let directory=try CleanupDirectoryAccess(absolute(item.entry.path), cancelled: cancelled)
                guard try directory.entry(relative: item.entry.path) == item.entry else {
                    issues.append("changed_directory: " + item.entry.path); continue
                }
                let localDeadline=ContinuousClock.now.advanced(by: .seconds(discoverySeconds() / Double(pending)))
                let listing: (names: [String], truncated: Bool)
                if let exactPaths {
                    // A target rescan reads only each bound path component and
                    // the current project context, regardless of sibling count.
                    let prefix=item.entry.path == "." ? [] : item.entry.path.split(separator: "/").map(String.init)
                    let children=exactPaths.compactMap { parts -> String? in
                        guard parts.count > prefix.count, parts.prefix(prefix.count).elementsEqual(prefix) else { return nil }
                        return parts[prefix.count]
                    }
                    listing=(Array(Set(children).union(markerNames)).sorted(), false)
                } else {
                    listing=try directory.names(limit: quota, deadline: localDeadline, cancelled: cancelled)
                }
                var children=[FileEntry]()
                var localVisited=0
                for name in listing.names {
                    try checkpoint()
                    if ContinuousClock.now >= discoveryDeadline || ContinuousClock.now >= localDeadline || localVisited >= quota { limit(item.entry.path); break }
                    if prunedNames.contains(name.lowercased()) { visited += 1; localVisited += 1; continue }
                    let child=relativeChild(item.entry.path, name)
                    let entry: FileEntry
                    do {
                        guard let found=try directory.child(name, relative: child) else {
                            if exactPaths != nil { continue }
                            visited += 1; localVisited += 1; issues.append("unreadable: " + child); continue
                        }
                        entry=found
                    } catch let failure as ShouError where failure.code == "cancelled" { throw failure }
                    catch { visited += 1; localVisited += 1; issues.append("\(child): \(error)"); continue }
                    visited += 1; localVisited += 1
                    guard entry.device == rootEntry.device else { issues.append("cross_filesystem: " + child); continue }
                    if markerNames.contains(name) { entries[child]=entry; markers[child]=entry }
                    if entry.kind == "directory" { children.append(entry) }
                }
                if listing.truncated { limit(item.entry.path) }
                if try directory.entry(relative: item.entry.path) != item.entry {
                    issues.append("changed_during_scan: " + item.entry.path)
                }
                for child in children {
                    let parts=(caseSensitive ? child.path : child.path.lowercased()).split(separator: "/").map(String.init)
                    let matches=prepared.filter { rule, patterns in
                        parts.count <= rule.scope.maxDepth && patterns.contains { $0.matches(parts) }
                            && (rule.match.projectMarkers?.allOf ?? []).allSatisfy { markers[relativeChild(item.entry.path, $0)]?.kind == "file" }
                    }
                    let discover=prepared.contains { rule, patterns in
                        parts.count < rule.scope.maxDepth && patterns.contains { $0.couldMatchDescendant(of: parts) }
                    }
                    guard !matches.isEmpty || discover else { continue }
                    entries[child.path]=child; directories[child.path]=child
                    #if !os(Windows)
                    if privacy.requiresAuthorization(absolute(child.path)) { issues.append("authorization_required: " + child.path); continue }
                    #endif
                    let childItem=CleanupDirectory(entry: child, depth: item.depth + 1)
                    if !matches.isEmpty { targets.append(childItem) }
                    else { queue.append(childItem) }
                }
                progress(ScanProgress(stage: "scanning", entryCount: visited, currentPath: absolute(item.entry.path)))
            } catch let failure as ShouError where failure.code == "cancelled" { throw failure }
            catch { issues.append("\(item.entry.path): \(error)") }
        }

        targets.sort { $0.entry.path < $1.entry.path }
        for (index, target) in targets.enumerated() {
            try checkpoint()
            let pending=targets.count - index
            let quota=(budget.maxEntries - visited) / pending
            let seconds=remainingSeconds() / Double(pending)
            guard quota >= 1, seconds > 0, target.depth <= budget.maxDepth else { limit(target.entry.path); continue }
            let base=visited
            progress(ScanProgress(stage: "scanning", entryCount: visited, currentPath: absolute(target.entry.path)))
            do {
                guard try sameBindings(for: target.entry.path) else { issues.append("changed_directory: " + target.entry.path); continue }
                let local=ScanBudget(maxEntries: quota, maxSeconds: seconds, maxDepth: budget.maxDepth - target.depth)
                let tree=try measureCleanupTarget(absolute(target.entry.path), budget: local, cancelled: cancelled, progress: { update in
                    progress(ScanProgress(stage: "scanning", entryCount: min(budget.maxEntries, base + update.entryCount), currentPath: update.currentPath, limitReached: update.limitReached))
                })
                visited += tree.complete ? tree.entries.count : quota
                guard tree.entries.first(where: { $0.path == "." }).map({ entry in
                    var expected=target.entry; expected.path="."; return entry == expected
                }) == true, try sameBindings(for: target.entry.path) else {
                    issues.append("changed_directory: " + target.entry.path); continue
                }
                for entry in tree.entries {
                    var copy=entry
                    copy.path=entry.path == "." ? target.entry.path : target.entry.path + "/" + entry.path
                    entries[copy.path]=copy
                }
                if tree.complete { completed.append(target.entry.path) }
                else {
                    for issue in tree.issues { issues.append(target.entry.path + ": " + issue) }
                    if tree.issues.contains("resource_limit") { limit(target.entry.path) }
                }
            } catch let failure as ShouError where failure.code == "cancelled" { throw failure }
            catch { visited=max(visited, base + quota); issues.append("\(target.entry.path): \(error)") }
        }
        var verified=[String]()
        for target in completed {
            if ContinuousClock.now >= deadline { limit(target); break }
            do {
                if try sameBindings(for: target) { verified.append(target) }
                else { issues.append("changed_directory: " + target) }
            } catch let failure as ShouError where failure.code == "cancelled" { throw failure }
            catch { issues.append("changed_directory: " + target) }
        }
        try checkpoint()
        progress(ScanProgress(stage: "analysis", entryCount: visited, currentPath: path, limitReached: limited))
        return TreeSnapshot(entries: entries.values.sorted { $0.path < $1.path }, complete: false, issues: issues,
            caseSensitive: caseSensitive, completedPaths: verified, discoveryComplete: issues.isEmpty)
    }
}
#endif
