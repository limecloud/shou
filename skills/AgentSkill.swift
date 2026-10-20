import Foundation

/// Ships instructions for external agents without depending on the cleanup engine.
public enum ShouAgentSkill {
    public static let name = "shou-rule-authoring"
    public static let files = ["SKILL.md", "references/questionnaire.md", "agents/openai.yaml"]

    public struct Descriptor: Encodable, Sendable {
        public let name: String
        public let directory: String
        public let entrypoint: String
        public let instructions: String
    }

    public static func directory() throws -> URL {
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

    public static func descriptor() throws -> Descriptor {
        let directory = try directory()
        let entrypoint = directory.appendingPathComponent("SKILL.md")
        return try Descriptor(name: name, directory: directory.path, entrypoint: entrypoint.path,
                              instructions: String(contentsOf: entrypoint, encoding: .utf8))
    }

    public static func read(file: String = "SKILL.md") throws -> String {
        guard files.contains(file) else { throw CocoaError(.fileNoSuchFile) }
        return try String(contentsOf: directory().appendingPathComponent(file), encoding: .utf8)
    }
}
