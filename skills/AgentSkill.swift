import Foundation

/// Ships instructions for external agents without depending on the cleanup engine.
public enum ShouAgentSkill {
    public static let name = "shou-rule-authoring"
    public static let files = ["SKILL.md", "references/questionnaire.md", "agents/openai.yaml"]
    public static let cleanupName = "shou-cleanup-assistant"
    public static let names = [name, cleanupName]
    public static func files(for skill: String) throws -> [String] {
        switch skill {
        case name: return files
        case cleanupName: return ["SKILL.md", "references/macos.md", "references/windows.md", "references/databases-and-containers.md", "agents/openai.yaml"]
        default: throw CocoaError(.fileNoSuchFile)
        }
    }

    public struct Descriptor: Encodable, Sendable {
        public let name: String
        public let directory: String
        public let entrypoint: String
        public let instructions: String
    }

    public static func directory(name: String = name) throws -> URL {
        guard names.contains(name) else { throw CocoaError(.fileNoSuchFile) }
        let packaged = Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("Shou_ShouAgentSupport.bundle"))
        }
        let bundle = packaged ?? Bundle.module
        guard let directory = bundle.url(forResource: name, withExtension: nil),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return directory
    }

    public static func descriptor(name: String = name) throws -> Descriptor {
        let directory = try directory(name: name)
        let entrypoint = directory.appendingPathComponent("SKILL.md")
        return try Descriptor(name: name, directory: directory.path, entrypoint: entrypoint.path,
                              instructions: String(contentsOf: entrypoint, encoding: .utf8))
    }

    public static func read(file: String = "SKILL.md", name: String = name) throws -> String {
        guard try files(for: name).contains(file) else { throw CocoaError(.fileNoSuchFile) }
        return try String(contentsOf: directory(name: name).appendingPathComponent(file), encoding: .utf8)
    }
}
