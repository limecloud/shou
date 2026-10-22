import Foundation
import ShouCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Read-only facts from fixed system tools and no-follow file reads, never rule commands.
public struct NativeArtifactEvidence: ArtifactEvidenceChecking {
    public init() {}

    public func hasGitTrackedFiles(at path: String) throws -> Bool {
        #if os(macOS)
        var directory=path
        var found=false
        while true {
            let descriptor=try SecurePaths.directory(directory, readFinalDirectory: false)
            var marker=stat()
            let result=fstatat(descriptor, ".git", &marker, AT_SYMLINK_NOFOLLOW)
            let failure=errno
            close(descriptor)
            if result == 0 {
                guard marker.st_mode & S_IFMT == S_IFDIR || marker.st_mode & S_IFMT == S_IFREG else {
                    throw unavailable("The Git ownership marker cannot be safely inspected.")
                }
                found=true; break
            }
            guard failure == ENOENT else { throw unavailable("Git ownership could not be inspected.") }
            if directory == "/" { break }
            directory=URL(fileURLWithPath: directory).deletingLastPathComponent().path
        }
        guard found else { return false }
        let output=try command("/usr/bin/git", arguments: ["-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-C", path, "ls-files", "--cached", "-z", "--", "."], limit: 2_097_152, deadline: uptime + 3)
        return !output.isEmpty
        #else
        throw unavailable("Native artifact ownership checks are unavailable on this platform.")
        #endif
    }

    public func runningBuildProcesses(in names: Set<String>) throws -> Set<String> {
        #if os(macOS)
        guard names.allSatisfy({ $0.range(of: "^[A-Za-z0-9_.+-]+$", options: .regularExpression) != nil }) else {
            throw unavailable("Build process names must be exact executable names.")
        }
        let output=try command("/bin/ps", arguments: ["-axo", "comm="], limit: 4_194_304, deadline: uptime + 3)
        guard let text=String(data: output, encoding: .utf8) else { throw unavailable("Build process output could not be decoded.") }
        let running=Set(text.split(separator: "\n").map { (String($0).trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent })
        return names.intersection(running)
        #else
        throw unavailable("Native build process checks are unavailable on this platform.")
        #endif
    }

    public func cargoSourceIntegrity(at path: String, expected: [FileEntry]) throws -> CargoSourceIntegrity {
        #if os(macOS)
        let deadline=uptime + 10
        let parts=try SecurePaths.components(path)
        guard parts.count >= 4, parts[parts.count-4] == "registry", parts[parts.count-3] == "src",
              expected.count <= 4096, Set(expected.map(\.path)).count == expected.count,
              expected.allSatisfy({ $0.kind == "file" || $0.kind == "directory" }) else {
            throw unavailable("The Cargo source layout or evidence budget is unsupported.")
        }
        try verifyTree(path, expected: expected, deadline: deadline)
        guard let checksum=expected.first(where: { $0.path == ".cargo-checksum.json" && $0.kind == "file" }) else {
            throw unavailable("Cargo checksum evidence is missing.")
        }
        let checksumData=try readFile(path + "/.cargo-checksum.json", expected: checksum, limit: 2_097_152, deadline: deadline).data
        guard let object=try JSONSerialization.jsonObject(with: checksumData) as? [String: Any],
              let files=object["files"] as? [String: String], !files.isEmpty, files.count <= 256,
              let package=object["package"] as? String, validHash(package) else {
            throw unavailable("Cargo checksum evidence is invalid or exceeds the verification budget.")
        }
        for (file, hash) in files {
            guard validRelativeFile(file), validHash(hash) else { throw unavailable("Cargo checksum paths or hashes are invalid.") }
        }
        let actual=Dictionary(uniqueKeysWithValues: expected.filter { $0.kind == "file" }.map { ($0.path, $0) })
        let generated=Set([".cargo-checksum.json", ".cargo-ok"])
        guard Set(actual.keys).subtracting(generated) == Set(files.keys).subtracting(generated) else { return .modified }
        if let marker=actual[".cargo-ok"], marker.logicalBytes > 1024 { return .modified }

        let crate=parts[parts.count-1], registry=parts[parts.count-2]
        let archive="/" + parts.dropLast(3).joined(separator: "/") + "/cache/" + registry + "/" + crate + ".crate"
        let retained: (data: Data, entry: FileEntry)
        do { retained=try readFile(archive, expected: nil, limit: 67_108_864, deadline: deadline) }
        catch { throw ShouError("artifact_restore_unavailable", "The retained Cargo package archive could not be verified.") }
        guard bareHash(retained.data) == package.lowercased() else {
            throw ShouError("artifact_restore_unavailable", "The retained Cargo package archive does not match the package checksum.")
        }

        // Editable checksum files cannot prove source integrity. Two bounded tar
        // calls provide archive member sizes/types and their bytes in archive order.
        try verifyFile(archive, expected: retained.entry)
        let listing=try command("/usr/bin/tar", arguments: ["-tvzf", archive, "--numeric-owner"], limit: 2_097_152, deadline: deadline, requireSilentDiagnostics: true)
        let members=try cargoArchiveMembers(listing, crate: crate, expected: expected)
        guard Set(members.map(\.path)) == Set(files.keys) else { return .modified }
        let total=members.reduce(0) { $0 + $1.size }
        try verifyFile(archive, expected: retained.entry)
        let archived=try command("/usr/bin/tar", arguments: ["-xOzf", archive], limit: total, deadline: deadline, requireSilentDiagnostics: true)
        guard archived.count == total else { throw unavailable("Cargo archive bytes do not match its member boundaries.") }
        var offset=0
        for member in members {
            guard let entry=actual[member.path], entry.kind == "file", entry.logicalBytes == Int64(member.size) else { return .modified }
            let data=try readFile(path + "/" + member.path, expected: entry, limit: 16_777_216, deadline: deadline).data
            guard data.count == member.size, bareHash(data) == files[member.path]?.lowercased(),
                  archived[offset..<(offset + member.size)] == data else { return .modified }
            offset += member.size
        }
        try verifyFile(archive, expected: retained.entry)
        try verifyTree(path, expected: expected, deadline: deadline)
        return .verified
        #else
        throw unavailable("Native Cargo integrity checks are unavailable on this platform.")
        #endif
    }

    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func unavailable(_ message: String) -> ShouError { ShouError("artifact_evidence_unavailable", message) }
    private func validHash(_ value: String) -> Bool { value.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil }
    private func bareHash(_ data: Data) -> String { String(Digest.sha256(data).dropFirst("sha256:".count)) }
    private func validRelativeFile(_ path: String) -> Bool {
        let components=path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && path.rangeOfCharacter(from: .controlCharacters.union(CharacterSet(charactersIn: "*?[]\\"))) == nil
    }

    #if os(macOS)
    private struct CargoArchiveMember {
        let path: String
        let size: Int
    }
    private func cargoArchiveMembers(_ listing: Data, crate: String, expected: [FileEntry]) throws -> [CargoArchiveMember] {
        guard let text=String(data: listing, encoding: .utf8), text.hasSuffix("\n") else {
            throw unavailable("Cargo archive metadata could not be decoded without loss.")
        }
        let lines=text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        guard !lines.isEmpty, lines.count <= 4096 else { throw unavailable("Cargo archive exceeded its member budget.") }
        // Understand only the fixed C-locale bsdtar layout with numeric owners.
        // The single separator after the date preserves leading filename spaces.
        let format=try NSRegularExpression(pattern: #"^([d-])[rwxstST-]{9} +[0-9]+ +[0-9]+ +[0-9]+ +([0-9]+) +(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) +[0-9]{1,2} +(?:[0-9]{4}|[0-9]{1,2}:[0-9]{2}) (.+)$"#)
        let entries=Dictionary(uniqueKeysWithValues: expected.map { ($0.path, $0) })
        var seen=Set<String>(), files: [CargoArchiveMember]=[], total=0
        for line in lines {
            let line=String(line), range=NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match=format.firstMatch(in: line, range: range), match.range == range,
                  let typeRange=Range(match.range(at: 1), in: line), let sizeRange=Range(match.range(at: 2), in: line),
                  let pathRange=Range(match.range(at: 3), in: line), let size=Int(line[sizeRange]) else {
                throw unavailable("Cargo archive contains unsupported file types or metadata.")
            }
            let directory=line[typeRange] == "d", member=String(line[pathRange])
            // bsdtar escapes paths outside printable ASCII in the C locale.
            // Unsupported escaped/Unicode paths fail closed instead of guessing.
            guard member.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }),
                  member == crate || member.hasPrefix(crate + "/") else { throw unavailable("Cargo archive root or path encoding is unsupported.") }
            var relative=member == crate ? "" : String(member.dropFirst(crate.count + 1))
            if directory && relative.hasSuffix("/") { relative.removeLast() }
            if relative.isEmpty && directory { relative="." }
            guard (relative == "." && directory) || validRelativeFile(relative), seen.insert(relative).inserted else {
                throw unavailable("Cargo archive contains unsafe or duplicate member paths.")
            }
            if directory {
                guard size == 0, entries[relative]?.kind == "directory" else { throw unavailable("Cargo archive directory metadata does not match the source tree.") }
            } else {
                guard size <= 16_777_216, files.count < 256, total + size <= 67_108_864 else {
                    throw unavailable("Cargo archive exceeded its file or byte budget.")
                }
                files.append(CargoArchiveMember(path: relative, size: size)); total += size
            }
        }
        return files
    }
    private func verifyTree(_ path: String, expected: [FileEntry], deadline: TimeInterval) throws {
        let remaining=deadline - uptime
        guard remaining > 0 else { throw unavailable("Cargo source verification exceeded its time budget.") }
        let tree=try NativeFileSystem().inspect(path, budget: ScanBudget(maxEntries: max(100_000, expected.count + 1), maxSeconds: remaining), cancelled: { Task.isCancelled })
        guard uptime < deadline, tree.complete, tree.entries == expected else { throw unavailable("Cargo source identity or contents changed during verification.") }
    }
    private func verifyFile(_ path: String, expected: FileEntry) throws {
        let (parent, name)=try SecurePaths.parent(path); defer { close(parent) }
        var metadata=stat()
        guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              SecurePaths.entry(metadata, path: expected.path) == expected else { throw unavailable("Artifact evidence changed during verification.") }
    }
    private func readFile(_ path: String, expected: FileEntry?, limit: Int, deadline: TimeInterval) throws -> (data: Data, entry: FileEntry) {
        let (parent, name)=try SecurePaths.parent(path); defer { close(parent) }
        let descriptor=openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw unavailable("Artifact evidence could not be opened without following links.") }
        defer { close(descriptor) }
        var before=stat(), after=stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0, before.st_size <= limit else {
            throw unavailable("Artifact evidence is not a bounded regular file.")
        }
        let entry=SecurePaths.entry(before, path: expected?.path ?? ".")
        if let expected, entry != expected { throw unavailable("Artifact evidence no longer matches the scan.") }
        var data=Data(), buffer=[UInt8](repeating: 0, count: 65_536)
        while true {
            guard uptime < deadline, !Task.isCancelled else { throw unavailable("Artifact evidence verification timed out or was cancelled.") }
            let count=buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0, data.count + count <= limit else { throw unavailable("Artifact evidence exceeded its read budget.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(descriptor, &after) == 0, SecurePaths.entry(after, path: entry.path) == entry else {
            throw unavailable("Artifact evidence changed while being read.")
        }
        try verifyFile(path, expected: entry)
        return (data, entry)
    }

    func command(_ executable: String, arguments: [String], limit: Int, deadline: TimeInterval, requireSilentDiagnostics: Bool = false) throws -> Data {
        guard uptime < deadline, !Task.isCancelled else { throw unavailable("Artifact evidence verification timed out or was cancelled.") }
        let process=Process(), output=Pipe()
        let diagnostics=requireSilentDiagnostics ? Pipe() : nil
        process.executableURL=URL(fileURLWithPath: executable); process.arguments=arguments
        process.environment=["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"]
        process.standardInput=FileHandle.nullDevice; process.standardOutput=output
        if let diagnostics { process.standardError=diagnostics } else { process.standardError=FileHandle.nullDevice }
        do { try process.run() } catch { throw unavailable("A required read-only system tool could not be started.") }
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            try? output.fileHandleForReading.close()
            try? diagnostics?.fileHandleForReading.close()
        }
        let descriptor=output.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else { throw unavailable("Read-only system tool output could not be bounded.") }
        let diagnosticDescriptor=diagnostics?.fileHandleForReading.fileDescriptor
        if let diagnosticDescriptor {
            guard fcntl(diagnosticDescriptor, F_SETFL, fcntl(diagnosticDescriptor, F_GETFL) | O_NONBLOCK) == 0 else { throw unavailable("Read-only system tool diagnostics could not be bounded.") }
        }
        var data=Data(), buffer=[UInt8](repeating: 0, count: 65_536), ended=false, diagnosticsEnded=diagnostics == nil
        while !ended || !diagnosticsEnded {
            guard uptime < deadline, !Task.isCancelled else { throw unavailable("Artifact evidence verification timed out or was cancelled.") }
            var progressed=false
            if !ended {
                let count=buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard data.count + count <= limit else { throw unavailable("Read-only system tool output exceeded its budget.") }
                    data.append(contentsOf: buffer.prefix(count)); progressed=true
                } else if count == 0 { ended=true; progressed=true }
                else if errno != EAGAIN && errno != EINTR { throw unavailable("Read-only system tool output could not be read.") }
            }
            if let diagnosticDescriptor, !diagnosticsEnded {
                let count=buffer.withUnsafeMutableBytes { Darwin.read(diagnosticDescriptor, $0.baseAddress, $0.count) }
                guard count <= 0 else { throw unavailable("A read-only system tool reported unsupported archive evidence.") }
                if count == 0 { diagnosticsEnded=true; progressed=true }
                else if errno != EAGAIN && errno != EINTR { throw unavailable("Read-only system tool diagnostics could not be read.") }
            }
            if !progressed { Thread.sleep(forTimeInterval: 0.005) }
        }
        while process.isRunning {
            guard uptime < deadline, !Task.isCancelled else { throw unavailable("Artifact evidence verification timed out or was cancelled.") }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw unavailable("A read-only system tool could not verify artifact evidence.") }
        return data
    }
    #endif
}
