import ShouCore

/// One command registry drives human help and progressive machine discovery.
enum CLICommandDiscovery {
    static func matching(_ command: String) throws -> [CommandSpec] {
        let selected=commands.filter { spec in
            #if os(Windows)
            if spec.command != "applications list", ["applications", "uninstall", "tools"].contains(where: { spec.command == $0 || spec.command.hasPrefix($0 + " ") }) { return false }
            if ["system close-plan", "system close-applications"].contains(spec.command) { return false }
            if spec.command == "skills export" { return false }
            #endif
            return command.isEmpty || spec.command == command || spec.command.hasPrefix(command + " ")
        }
        guard !selected.isEmpty else {
            throw ShouError("invalid_argument", "Unknown command or group. Use shou --help.", details: ["command": command])
        }
        return selected
    }

    static func help(for command: String) throws -> String {
        let selected=try matching(command)
        var text="Shou · 收拾一下 — Tidy up. That's it.\n\nUsage: shou <command> [options] [--json] [--locale en|zh-CN]\n\n"
        for spec in selected {
            let required=spec.required.map { "--\($0) <value>" }
            let optional=spec.optional.filter { !(spec.exactlyOne ?? []).contains($0) }.map { "[--\($0) <value>]" }
            let alternatives=spec.exactlyOne.map { ["(" + $0.map { "--\($0) <value>" }.joined(separator: " | ") + ")"] } ?? []
            let inputs=(required + alternatives + optional).joined(separator: " ")
            text += "  \(spec.command) \(inputs)\n      [\(spec.sideEffect)] \(spec.description)\n"
            if !spec.repeated.isEmpty { text += "      Repeatable: " + spec.repeated.map { "--" + $0 }.joined(separator: ", ") + "\n" }
        }
        if command.isEmpty || command == "skills" || command == "skills read" {
            text += "\nSkill examples:\n  shou skills read shou-rule-authoring\n  shou skills read shou-rule-authoring references/questionnaire.md --json\n"
        }
        text += "\nUse capabilities --command \"<command or group>\" --json for focused machine discovery.\nDestructive operations require current-scope terminal confirmation.\n"
        return text
    }
}
