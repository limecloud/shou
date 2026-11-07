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
    @State private var selectedSkill = ShouAgentSkill.cleanupName
    @State private var installation: AgentSkillInstallation.Result?
    @State private var exported = false

    private var prompt: String {
        let skill = (try? ShouAgentSkill.directory(name: selectedSkill).appendingPathComponent("SKILL.md").path) ?? ""
        let executable = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shou").path
            : Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("shou").path
        let request=contextPath ?? (model.language == .simplifiedChinese ? "当前电脑主要磁盘占用" : "the largest disk consumers on this computer")
        let invocation=(client == "claude-code" ? "/" : "$") + selectedSkill
        if selectedSkill == ShouAgentSkill.name {
            return model.language == .simplifiedChinese ? """
            请阅读本地 Shou Skill：\(skill)
            使用 Shou CLI：\(executable)
            使用 \(invocation)，针对 \(request) 调查可重建产物与保留条件，复用现有规则，必要时验证、导入并预览禁用草稿。
            只追问证据无法确定的用途；不要启用规则或执行删除。
            """ : """
            Read the local Shou Skill: \(skill)
            Use this Shou CLI: \(executable)
            Use \(invocation) to investigate \(request), rebuild requirements and retention. Reuse existing rules or validate, import and preview disabled drafts.
            Ask only unresolved purpose questions. Do not enable rules or execute cleanup.
            """
        }
        if model.language == .simplifiedChinese {
            return """
            请阅读本地 Shou Skill：\(skill)
            使用 Shou CLI：\(executable)
            使用 \(invocation) 调查：\(request)。
            先发现当前平台实际能力，复用扫描，按大项说明用途、大小、活跃情况、重建代价和保留条件。
            将建议清理、需要判断、受保护和本次保留分开，逐批让我选择。现有授权按范围继续；新增目标另列，不继承历史删除确认。
            通过 Shou 当前计划与确认执行，未支持或门禁关闭的操作交回产品，不用 Shell 绕过。核对逐项回执、保留对象和宿主空间变化；没有回执不得称已清理。
            """
        }
        return """
        Read the local Shou Skill: \(skill)
        Use this Shou CLI: \(executable)
        Use \(invocation) to investigate \(request).
        Discover current platform capabilities and reuse scan evidence. Explain purpose, size, activity, rebuild cost and retention for the largest consumers.
        Separate recommendations, decisions, protected and kept items. Let me select independent batches; reuse explicit scope only.
        Execute through Shou plans and current confirmation. Hand unsupported or gated actions back without Shell bypass. Verify receipts, retained objects and host space change; do not claim cleanup without a receipt.
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(model.t("Customize with AI"), systemImage: "sparkles").font(ShouType.title.bold())
            Text(model.t("Install an assistant for investigating disk usage or authoring reusable cleanup rules."))
                .foregroundStyle(ShouPalette.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Picker(model.t("Skill"), selection: $selectedSkill) {
                    Text(model.t("Cleanup assistant")).tag(ShouAgentSkill.cleanupName)
                    Text(model.t("Rule authoring")).tag(ShouAgentSkill.name)
                }.pickerStyle(.segmented).accessibilityIdentifier("rules.agent.skill")
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
                    Text(selected.skillsDirectory().appendingPathComponent(selectedSkill).path)
                        .font(ShouType.caption.monospaced()).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
                    Text((client == "codex" ? "$" : "/") + selectedSkill)
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
                Label(model.t("3. Review independent cleanup batches in Shou."), systemImage: "checkmark.circle")
                Label(model.t("4. Clean selected items, then verify the result and retained items."), systemImage: "checkmark.seal")
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
                    do { NSWorkspace.shared.activateFileViewerSelecting([try ShouAgentSkill.directory(name: selectedSkill).appendingPathComponent("SKILL.md")]) }
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
            .onChange(of: selectedSkill) { _, _ in installation=nil; exported=false; issue=nil; copied=false }
            .onChange(of: client) { _, _ in installation = nil; exported = false; issue = nil }
    }

    private func installOrExport() {
        issue = nil
        do {
            if let selected = AgentSkillInstallation.Client(rawValue: client) {
                installation = try AgentSkillInstallation.install(client: selected, skill: selectedSkill)
            } else {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.zip]
                panel.nameFieldStringValue = selectedSkill + ".zip"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try AgentSkillInstallation.exportArchive(to: url, skill: selectedSkill)
                exported = true
            }
        } catch { issue = model.t(error.localizedDescription) }
    }
}
