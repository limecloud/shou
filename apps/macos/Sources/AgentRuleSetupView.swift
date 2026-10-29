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

            请按 Skill 认真分析主要占用，沿大目录调查到具体用途，不要只清小缓存。按用途、重建代价和保留条件拆分可独立选择的规则，每条分别校验、导入为禁用草稿并预览，说明命中、保护项和新增收益。对不能处理的大项说明未知点与下一步。只追问证据不能回答的用途、活跃项目与保留要求。预览后由我逐条决定；回到 Shou“规则 → 审阅并清理…”启用并扫描所选规则，再确认实际删除。已有明确授权可继续，未有回执不得称已清理；执行后核验逐项结果与剩余占用。
            """
        }
        return """
        Read the local Shou Skill: \(skill)
        Use this Shou CLI: \(executable)
        \(contextPath.map { "Investigate this directory to author a rule: " + $0 } ?? "Inspect common locations, developer projects and existing rules, then find large areas not yet covered.")

        Follow the Skill to investigate the largest consumers to their actual purpose, including unresolved large areas and next diagnostics. Split independently selectable rules by purpose, rebuild cost and retention. Validate, import disabled and preview each; explain matches, protections and additional benefit. Ask only what evidence cannot resolve. Let me choose each rule, then return to Shou Rules → Review & Clean… → Enable & Scan This Rule and confirm actual deletion. Reuse explicit authorization, never claim cleanup without a receipt, and verify per-item outcomes and remaining space afterwards.
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(model.t("Customize with AI"), systemImage: "sparkles").font(ShouType.title.bold())
            Text(model.t("Tell your coding agent what to clean. It asks the right questions and writes the rules for you."))
                .foregroundStyle(ShouPalette.secondary)
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
                        .font(ShouType.caption.monospaced()).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
                    Text(model.t(client == "codex" ? "After installation, use $shou-rule-authoring in Codex. Restart Codex if it does not appear." : "After installation, use /shou-rule-authoring in a local Claude Code session."))
                        .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                } else {
                    Text(model.t("In WorkBuddy, open Skills → Add Skill → Upload Skill, select the ZIP, enable it, and start a new task."))
                        .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                }
                if let installation {
                    Label(model.t(installation.state == "already_current" ? "Skill is already up to date." : "Skill installed. Open your agent to use it."), systemImage: "checkmark.circle.fill")
                        .font(ShouType.caption).foregroundStyle(ShouPalette.success).accessibilityIdentifier("rules.agent.installed")
                }
                if exported { Text(model.t("Skill ZIP exported. Upload it in WorkBuddy to finish installation.")).font(ShouType.caption).foregroundStyle(ShouPalette.success) }
            }
            .padding(14).background(ShouPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 12) {
                Label(model.t("1. Copy the request to Codex, Claude Code, or WorkBuddy."), systemImage: "doc.on.doc")
                Label(model.t("2. Answer questions about your projects and what to keep."), systemImage: "text.bubble")
                Label(model.t("3. Review the draft in Shou, then enable it when ready."), systemImage: "checkmark.circle")
                Label(model.t("4. Clean selected rules, then verify the result and retained items."), systemImage: "checkmark.seal")
            }.font(ShouType.body)
            ScrollView {
                Text(prompt).font(ShouType.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            .background(ShouPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ShouPalette.border, lineWidth: ShouDesign.hairlineWidth))
            .accessibilityIdentifier("rules.agent.prompt")
            Text(model.t("Shou includes the Skill and CLI. Use your existing agent; no model setup is needed in Shou."))
                .font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            if let issue { Text(issue).font(ShouType.caption).foregroundStyle(ShouPalette.danger) }
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
        }.padding(24).frame(width: 740, height: 520)
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
