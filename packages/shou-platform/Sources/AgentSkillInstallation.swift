import Foundation
import ShouAgentSupport
import ShouCore

/// Installs only the bundled instructions; never edits a client's config or starts it.
public enum AgentSkillInstallation {
    public enum Client: String, CaseIterable, Sendable {
        case codex
        case claudeCode = "claude-code"

        public func skillsDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
            home.appendingPathComponent(self == .codex ? ".agents/skills" : ".claude/skills")
        }
    }

    public struct Result: Encodable, Sendable {
        public let agent: String
        public let directory: String
        public let state: String
        public let backupDirectory: String?
    }

    public struct Preview: Encodable, Sendable {
        public let agent: String
        public let directory: String
        public let state: String
        public let digest: String
    }

    public struct ExportPreview: Encodable, Sendable {
        public let path: String
        public let digest: String
    }

    private struct Manifest: Codable {
        let skill: String
        let files: [String: String]
    }
    private static let manifestName = ".shou-skill-manifest.json"

    public static func preview(client: Client, skillsDirectory: URL? = nil) throws -> Preview {
        let parent=skillsDirectory ?? client.skillsDirectory()
        let destination=parent.appendingPathComponent(ShouAgentSkill.name)
        try rejectLinks(destination)
        let contents=try bundledContents()
        var state="installed", existing: [String: String]=[:], manifest=""
        if FileManager.default.fileExists(atPath: destination.path) {
            existing=try inventory(destination)
            let desired=contents.mapValues(Digest.sha256)
            if existing == desired { state="already_current" }
            else {
                guard let data=try? fileData(destination.appendingPathComponent(manifestName), limit: 32_768),
                      let saved=try? JSONDecoder().decode(Manifest.self, from: data), saved.skill == ShouAgentSkill.name, saved.files == existing else {
                    throw ShouError("version_conflict", "The installed Skill has local changes or is not managed by Shou. Existing files were preserved.", details: ["path": destination.path])
                }
                manifest=Digest.sha256(data); state="updated"
            }
        }
        let digest=try Digest.of(["agent": client.rawValue, "directory": destination.path, "state": state,
            "source": Digest.of(contents.mapValues(Digest.sha256)), "existing": Digest.of(existing), "manifest": manifest])
        return Preview(agent: client.rawValue, directory: destination.path, state: state, digest: digest)
    }

    public static func install(client: Client, skillsDirectory: URL? = nil, reviewedDigest: String? = nil) throws -> Result {
        let review=try preview(client: client, skillsDirectory: skillsDirectory)
        if let reviewedDigest, reviewedDigest != review.digest { throw ShouError("plan_stale", "The Skill or destination changed. Review the installation again.") }
        try Task.checkCancellation()
        if review.state == "already_current" { return Result(agent: client.rawValue, directory: review.directory, state: review.state, backupDirectory: nil) }
        let fm = FileManager.default
        let parent = skillsDirectory ?? client.skillsDirectory()
        let destination = parent.appendingPathComponent(ShouAgentSkill.name)
        let contents = try bundledContents()
        let manifest = Manifest(skill: ShouAgentSkill.name, files: contents.mapValues(Digest.sha256))
        // Do not write through linked client directories or replace an existing link.
        try rejectLinks(parent)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try rejectLinks(destination)
        let backup=review.state == "updated" ? parent.appendingPathComponent(".shou-rule-authoring-backup-" + UUID().uuidString.lowercased()) : nil

        let staged = parent.appendingPathComponent(".shou-rule-authoring-install-" + UUID().uuidString.lowercased())
        try fm.createDirectory(at: staged, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staged) }
        for (path, data) in contents {
            try Task.checkCancellation()
            let file = staged.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .withoutOverwriting)
        }
        try JSONEncoder().encode(manifest).write(to: staged.appendingPathComponent(manifestName), options: .withoutOverwriting)
        // Recheck the reviewed files before publishing, including changes during staging.
        guard try preview(client: client, skillsDirectory: skillsDirectory).digest == review.digest,
              contents.mapValues(Digest.sha256) == (try bundledContents()).mapValues(Digest.sha256) else {
            throw ShouError("plan_stale", "The Skill or destination changed. Review the installation again.")
        }
        try Task.checkCancellation()
        if let backup { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: staged, to: destination) }
        catch {
            if let backup, !fm.fileExists(atPath: destination.path) { try fm.moveItem(at: backup, to: destination) }
            throw error
        }
        return Result(agent: client.rawValue, directory: destination.path, state: backup == nil ? "installed" : "updated", backupDirectory: backup?.path)
    }

    /// A ZIP with one top-level skill directory, suitable for WorkBuddy's upload UI.
    public static func previewExport(to output: URL) throws -> ExportPreview {
        guard output.pathExtension.lowercased() == "zip" else { throw ShouError("invalid_argument", "Choose a .zip file for the Skill package.") }
        try rejectLinks(output.deletingLastPathComponent())
        try rejectLinks(output)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ShouError("version_conflict", "The output file already exists. Choose another filename; existing files were preserved.")
        }
        return try ExportPreview(path: output.path, digest: Digest.of(["path": output.path, "archive": Digest.sha256(archiveData())]))
    }

    public static func exportArchive(to output: URL, reviewedDigest: String? = nil) throws {
        let review=try previewExport(to: output), archive=try archiveData()
        guard (reviewedDigest == nil || reviewedDigest == review.digest),
              review.digest == (try Digest.of(["path": output.path, "archive": Digest.sha256(archive)])) else {
            throw ShouError("plan_stale", "The Skill or destination changed. Review the export again.")
        }
        try Task.checkCancellation()
        try archive.write(to: output, options: .withoutOverwriting)
    }

    private static func bundledContents() throws -> [String: Data] {
        let source=try ShouAgentSkill.directory()
        return try Dictionary(uniqueKeysWithValues: ShouAgentSkill.files.map { ($0, try fileData(source.appendingPathComponent($0), limit: 262_144)) })
    }

    private static func archiveData() throws -> Data {
        try SkillArchive.encode(Dictionary(uniqueKeysWithValues: bundledContents().map { (ShouAgentSkill.name + "/" + $0.key, $0.value) }))
    }

    private static func fileData(_ path: URL, limit: Int) throws -> Data {
        try rejectLinks(path)
        let handle=try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let data=try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ShouError("resource_limit", "The Skill contains an oversized file.") }
        return data
    }

    private static func rejectLinks(_ path: URL) throws {
        // Foundation standardization can shorten /private/var to the /var link.
        // Keep the supplied absolute spelling and reject traversal components.
        guard path.isFileURL, path.path.hasPrefix("/"),
              !path.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw ShouError("invalid_argument", "Choose an absolute Skill path without traversal components.")
        }
        var current = path
        while current.path != "/" && !current.path.isEmpty {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ShouError("invalid_argument", "Skill installation cannot write through symbolic links.", details: ["path": current.path])
            }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
    }

    private static func inventory(_ directory: URL) throws -> [String: String] {
        try rejectLinks(directory)
        var failed=false, count=0
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], errorHandler: { _, _ in failed=true; return false }) else {
            throw ShouError("io_error", "The installed Skill cannot be inspected.")
        }
        var values: [String: String] = [:]
        for case let entry as URL in entries {
            count += 1
            guard count <= 128 else { throw ShouError("version_conflict", "The installed Skill contains unsupported files. Existing files were preserved.") }
            let metadata = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard metadata.isSymbolicLink != true else { throw ShouError("version_conflict", "The installed Skill contains a symbolic link. Existing files were preserved.") }
            try rejectLinks(entry)
            if metadata.isDirectory == true { continue }
            let relative = String(entry.path.dropFirst(directory.path.count + 1))
            guard metadata.isRegularFile == true, values.count < 64 else { throw ShouError("version_conflict", "The installed Skill contains unsupported files. Existing files were preserved.") }
            let data=try fileData(entry, limit: 262_144)
            if relative != manifestName { values[relative] = Digest.sha256(data) }
        }
        guard !failed else { throw ShouError("io_error", "The installed Skill cannot be inspected.") }
        return values
    }
}
