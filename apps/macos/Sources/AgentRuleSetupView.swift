import AppKit
import ShouAgentSupport
import ShouPlatform
import SwiftUI
import UniformTypeIdentifiers

struct AgentRuleSetupView: View {
    var model: AppModel
    var contextPath: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var issue: String?
    @State private var client = "codex"
    @State private var installation: AgentSkillInstallation.Result?
    @State private var exported = false

    private var prompt: String {
        let skill = (try? ShouAgentSkill.directory().appendingPathComponent("SKILL.md").path) ?? ""
        let executable = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shou").path
            : Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("shou").path
        if model.language == .simplifiedChinese {
            return """
            请阅读本地 Shou Skill：\(skill)
            使用 Shou CLI：\(executable)
            \(contextPath.map { "请分析这个目录并制定规则：" + $0 } ?? "先查看常用位置、开发项目和现有规则，再定位尚未覆盖的占用大头。")

            请帮我制定适合这台 Mac 的清理规则。先查看目录占用和现有规则；只追问尚不明确的用途、重建方式、活跃项目和必须保留的内容。由你编写规则，校验、导入为禁用草稿并预览，向我说明命中路径、空间估计和清理代价。暂不启用或清理；预览后再由我决定。
            """
        }
        return """
        Read the local Shou Skill: \(skill)
        Use this Shou CLI: \(executable)
        \(contextPath.map { "Investigate this directory to author a rule: " + $0 } ?? "Inspect common locations, developer projects and existing rules, then find large areas not yet covered.")

        Help me customize cleanup rules for this Mac. Inspect disk usage and existing rules, then ask only about unclear purpose, rebuild steps, active projects, and content to preserve. Write and validate the rules, import disabled drafts, and preview them. Explain exact paths, size estimates, and rebuild costs. Do not enable or clean yet; let me decide after the preview.
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(model.t("Customize with AI"), systemImage: "sparkles").font(.title2.bold())
            Text(model.t("Tell your coding agent what to clean. It asks the right questions and writes the rules for you."))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker(model.t("Your AI Agent"), selection: $client) {
                        Text("Codex").tag("codex")
                        Text("Claude Code").tag("claude-code")
                        Text("WorkBuddy").tag("workbuddy")
                    }.frame(width: 300).accessibilityIdentifier("rules.agent.client")
                    Spacer()
                    Button(model.t(client == "workbuddy" ? "Export Skill ZIP…" : "Install Skill")) { installOrExport() }
                        .accessibilityIdentifier("rules.agent.install")
                }
                if let selected = AgentSkillInstallation.Client(rawValue: client) {
                    Text(selected.skillsDirectory().appendingPathComponent(ShouAgentSkill.name).path)
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(model.t(client == "codex" ? "After installation, use $shou-rule-authoring in Codex. Restart Codex if it does not appear." : "After installation, use /shou-rule-authoring in a local Claude Code session."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.t("In WorkBuddy, open Skills → Add Skill → Upload Skill, select the ZIP, enable it, and start a new task."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let installation {
                    Label(model.t(installation.state == "already_current" ? "Skill is already up to date." : "Skill installed. Open your agent to use it."), systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green).accessibilityIdentifier("rules.agent.installed")
                }
                if exported { Text(model.t("Skill ZIP exported. Upload it in WorkBuddy to finish installation.")).font(.caption).foregroundStyle(.green) }
            }
            .padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 12) {
                Label(model.t("1. Copy the request to Codex, Claude Code, or WorkBuddy."), systemImage: "doc.on.doc")
                Label(model.t("2. Answer questions about your projects and what to keep."), systemImage: "text.bubble")
                Label(model.t("3. Review the draft in Shou, then enable it when ready."), systemImage: "checkmark.circle")
            }.font(.callout)
            ScrollView {
                Text(prompt).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.1)))
            .accessibilityIdentifier("rules.agent.prompt")
            Text(model.t("Shou includes the Skill and CLI. Use your existing agent; no model setup is needed in Shou."))
                .font(.caption).foregroundStyle(.secondary)
            if let issue { Text(issue).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(model.t("Show Skill in Finder…")) {
                    do { NSWorkspace.shared.activateFileViewerSelecting([try ShouAgentSkill.directory().appendingPathComponent("SKILL.md")]) }
                    catch { issue = error.localizedDescription }
                }.accessibilityIdentifier("rules.agent.reveal")
                Spacer()
                Button(model.t("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.t(copied ? "Copied" : "Copy Request")) {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(prompt, forType: .string) { copied = true }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("rules.agent.copy")
            }
        }.padding(24).frame(width: 740, height: 740)
            .onChange(of: client) { _, _ in installation = nil; exported = false; issue = nil }
    }

    private func installOrExport() {
        issue = nil
        do {
            if let selected = AgentSkillInstallation.Client(rawValue: client) {
                installation = try AgentSkillInstallation.install(client: selected)
            } else {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.zip]
                panel.nameFieldStringValue = ShouAgentSkill.name + ".zip"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try AgentSkillInstallation.exportArchive(to: url)
                exported = true
            }
        } catch { issue = model.t(error.localizedDescription) }
    }
}
