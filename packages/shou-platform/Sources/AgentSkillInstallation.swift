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

    private struct Manifest: Codable {
        let skill: String
        let files: [String: String]
    }
    private static let manifestName = ".shou-skill-manifest.json"

    public static func install(client: Client, skillsDirectory: URL? = nil) throws -> Result {
        let fm = FileManager.default
        let parent = skillsDirectory ?? client.skillsDirectory()
        let destination = parent.appendingPathComponent(ShouAgentSkill.name)
        let source = try ShouAgentSkill.directory()
        let contents = try Dictionary(uniqueKeysWithValues: ShouAgentSkill.files.map { ($0, try Data(contentsOf: source.appendingPathComponent($0))) })
        let manifest = Manifest(skill: ShouAgentSkill.name, files: contents.mapValues(Digest.sha256))
        // Do not write through linked client directories or replace an existing link.
        try rejectLinks(parent)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try rejectLinks(destination)
        var backup: URL?
        if fm.fileExists(atPath: destination.path) {
            let actual = try inventory(destination)
            if actual == manifest.files { return Result(agent: client.rawValue, directory: destination.path, state: "already_current", backupDirectory: nil) }
            let savedURL = destination.appendingPathComponent(manifestName)
            guard let data = try? Data(contentsOf: savedURL), data.count <= 32_768,
                  let saved = try? JSONDecoder().decode(Manifest.self, from: data),
                  saved.skill == ShouAgentSkill.name, saved.files == actual else {
                throw ShouError("version_conflict", "The installed Skill has local changes or is not managed by Shou. Existing files were preserved.", details: ["path": destination.path])
            }
            backup = parent.appendingPathComponent(".shou-rule-authoring-backup-" + UUID().uuidString.lowercased())
        }

        let staged = parent.appendingPathComponent(".shou-rule-authoring-install-" + UUID().uuidString.lowercased())
        try fm.createDirectory(at: staged, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staged) }
        for (path, data) in contents {
            let file = staged.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .withoutOverwriting)
        }
        try JSONEncoder().encode(manifest).write(to: staged.appendingPathComponent(manifestName), options: .withoutOverwriting)
        if let backup { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: staged, to: destination) }
        catch {
            if let backup, !fm.fileExists(atPath: destination.path) { try fm.moveItem(at: backup, to: destination) }
            throw error
        }
        return Result(agent: client.rawValue, directory: destination.path, state: backup == nil ? "installed" : "updated", backupDirectory: backup?.path)
    }

    /// A ZIP with one top-level skill directory, suitable for WorkBuddy's upload UI.
    public static func exportArchive(to output: URL) throws {
        guard output.pathExtension.lowercased() == "zip" else { throw ShouError("invalid_argument", "Choose a .zip file for the Skill package.") }
        try rejectLinks(output.deletingLastPathComponent())
        try rejectLinks(output)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ShouError("version_conflict", "The output file already exists. Choose another filename; existing files were preserved.")
        }
#if os(macOS)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("shou-skill-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("skill.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", "--norsrc", try ShouAgentSkill.directory().path, archive.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ShouError("io_error", "The Skill package could not be created.") }
        try Data(contentsOf: archive).write(to: output, options: .withoutOverwriting)
#else
        throw ShouError("invalid_argument", "Skill ZIP export is currently available on macOS only.")
#endif
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
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else {
            throw ShouError("io_error", "The installed Skill cannot be inspected.")
        }
        var values: [String: String] = [:]
        for case let entry as URL in entries {
            let metadata = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard metadata.isSymbolicLink != true else { throw ShouError("version_conflict", "The installed Skill contains a symbolic link. Existing files were preserved.") }
            if metadata.isDirectory == true { continue }
            let relative = String(entry.path.dropFirst(directory.path.count + 1))
            guard metadata.isRegularFile == true, values.count < 64 else { throw ShouError("version_conflict", "The installed Skill contains unsupported files. Existing files were preserved.") }
            let handle = try FileHandle(forReadingFrom: entry)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 262_145) ?? Data()
            guard data.count <= 262_144 else { throw ShouError("version_conflict", "The installed Skill contains an oversized file. Existing files were preserved.") }
            if relative != manifestName { values[relative] = Digest.sha256(data) }
        }
        return values
    }
}
