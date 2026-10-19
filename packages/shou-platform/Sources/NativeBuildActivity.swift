import Foundation
import ShouCore
#if canImport(Darwin)
import Darwin
#endif

extension NativeArtifactEvidence {
    public func runningBuildProcesses(in names: Set<String>, affecting projectPath: String) throws -> Set<String> {
        #if os(macOS)
        guard names.allSatisfy({ $0.range(of: "^[A-Za-z0-9_.+-]+$", options: .regularExpression) != nil }) else {
            throw unavailable("Build process names must be exact executable names.")
        }
        let project=try verifiedBuildActivityPath(projectPath)
        if names.isEmpty { return [] }
        let deadline=uptime + 3
        let output=try command("/bin/ps", arguments: ["-U", String(getuid()), "-o", "pid=,comm="], limit: 4_194_304, deadline: deadline, requireSilentDiagnostics: true)
        guard let text=String(data: output, encoding: .utf8), text.hasSuffix("\n") else {
            throw unavailable("Build process output could not be decoded.")
        }
        var seen=Set<Int32>(), matching: [(Int32, String)]=[]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            let fields=line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid=Int32(fields[0]), pid > 0, seen.insert(pid).inserted,
                  String(fields[1]).rangeOfCharacter(from: .controlCharacters) == nil else {
                throw unavailable("Build process output is ambiguous.")
            }
            let name=(String(fields[1]).trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
            if names.contains(name) { matching.append((pid, name)) }
        }
        guard !seen.isEmpty, matching.count <= 64 else { throw unavailable("Build activity exceeded its verification budget.") }
        let caseSensitive=(try? URL(fileURLWithPath: project).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
        let comparedProject=caseSensitive ? project : project.lowercased()
        var running=Set<String>()
        for (pid, name) in matching {
            guard uptime < deadline else { throw unavailable("Build activity exceeded its verification budget.") }
            // Query only this process's vnode information. Spawning lsof for
            // every unrelated build can exhaust the shared evidence deadline.
            var info=proc_vnodepathinfo()
            let size=Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
                throw unavailable("Build process working directory could not be verified.")
            }
            let path=withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes -> String? in
                guard let end=bytes.firstIndex(of: 0) else { return nil }
                return String(bytes: bytes[..<end], encoding: .utf8)
            }
            guard let path, path.hasPrefix("/"), uptime < deadline else {
                throw unavailable("Build process working directory could not be verified.")
            }
            let directory=try verifiedBuildActivityPath(path)
            let comparedDirectory=caseSensitive ? directory : directory.lowercased()
            if containsBuildActivityPath(comparedProject, comparedDirectory) || containsBuildActivityPath(comparedDirectory, comparedProject) { running.insert(name) }
        }
        return running
        #else
        throw unavailable("Native build process checks are unavailable on this platform.")
        #endif
    }

    #if os(macOS)
    private func verifiedBuildActivityPath(_ path: String) throws -> String {
        guard path.rangeOfCharacter(from: .controlCharacters) == nil, !path.contains("\\") else {
            throw unavailable("Build process working directory could not be verified.")
        }
        _ = try SecurePaths.components(path)
        // Foundation can shorten /private/var back to the /var symlink on macOS.
        // realpath preserves the physical path needed by no-follow traversal.
        guard let resolved=path.withCString({ realpath($0, nil) }) else {
            throw unavailable("Build process working directory could not be verified.")
        }
        defer { free(resolved) }
        guard let canonical=String(validatingCString: resolved),
              canonical.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw unavailable("Build process working directory could not be verified.")
        }
        let descriptor=try SecurePaths.directory(canonical, readFinalDirectory: false)
        close(descriptor)
        return canonical
    }
    private func containsBuildActivityPath(_ parent: String, _ child: String) -> Bool {
        parent == child || parent == "/" || child.hasPrefix(parent + "/")
    }
    #endif
}
