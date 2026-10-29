import SwiftUI
import ShouCore
import AppKit

private struct RuleWizardFields: Equatable {
    var mode="folder"
    var name=""
    var patterns=""
    var markers=""
    var exclusions=""
    var depth="8"
    var minimumMB="100"
    var useAge=true
    var age="14"
    var rebuild=""
    var limitations=""
    var highRisk=false
}

struct RuleWizard: View {
    var model: AppModel
    private let workspace: Workspace?
    @State private var ruleId="personal." + UUID().uuidString.lowercased()
    @Environment(\.dismiss) private var dismiss
    @State private var fields: RuleWizardFields
    @State private var step=0
    @State private var issue: String?
    @State private var preview: ScanSnapshot?
    @State private var rows: [PersonalRulePreviewRow]=[]
    @State private var previewedData: Data?
    @State private var focusedPath: String?
    @State private var previewing=false
    @State private var saving=false

    init(model: AppModel, initialPattern: String = "") {
        self.model=model; workspace=model.workspace
        var fields=RuleWizardFields()
        fields.patterns=initialPattern
        fields.mode=initialPattern.contains("*") || initialPattern.contains("?") ? "patterns" : "folder"
        if initialPattern == "**/target" { fields.markers="Cargo.toml" }
        fields.depth=String(max(8, initialPattern.split(separator: "/").count))
        _fields=State(initialValue: fields)
    }

    private var working: Bool { previewing || saving }
    private var names: [String] { [model.t("Rule Scope"), model.t("Conditions & Preservation"), model.t("Read-only Preview")] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.t("Create a Personal Rule")).font(ShouType.title.bold())
            HStack(spacing: 10) {
                ForEach(names.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        Image(systemName: index < step ? "checkmark.circle.fill" : "\(index + 1).circle\(index == step ? ".fill" : "")")
                        Text(names[index]).font(ShouType.body.weight(index == step ? .semibold : .regular))
                    }.foregroundStyle(index == step ? ShouPalette.accent : ShouPalette.secondary)
                    if index != names.count - 1 { Image(systemName: "chevron.right").font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.t("Create a Personal Rule"))
            .accessibilityValue(names[step])
            .accessibilityIdentifier("rules.wizard.steps")
            if let workspace {
                Text(workspace.path).font(ShouType.caption.monospaced()).foregroundStyle(ShouPalette.secondary).lineLimit(2).textSelection(.enabled)
            }
            Group {
                if step == 0 { scopeForm }
                else if step == 1 { conditionsForm }
                else { previewContent }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let issue {
                ScrollView { Text(issue).font(ShouType.caption).foregroundStyle(ShouPalette.danger).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 60).accessibilityIdentifier("rules.wizard.issue")
            }
            Divider()
            Text(model.t("Saved as a disabled draft. Review and enable it in Rules, then scan again.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            HStack {
                Button(model.t("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Spacer()
                if step > 0 {
                    Button(model.t("Back")) { step -= 1; issue=nil }.disabled(working)
                        .accessibilityIdentifier("rules.wizard.back")
                }
                if step < 2 {
                    Button(step == 0 ? model.t("Continue") : model.t("Preview Rule")) { advance() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(working || model.busy || workspace == nil)
                        .accessibilityIdentifier("rules.wizard.next")
                } else {
                    Button(model.t("Save Draft")) { save() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(previewedData == nil || working || model.busy)
                        .accessibilityIdentifier("rules.wizard.save")
                }
            }
        }.padding(24).frame(width: 760, height: 520)
            .onChange(of: fields) { _, _ in preview=nil; rows=[]; previewedData=nil; focusedPath=nil; issue=nil }
            .interactiveDismissDisabled(working)
            .onDisappear { if previewing { model.cancel() } }
    }

    private var scopeForm: some View {
        Form {
            Section {
                TextField(model.t("Rule name"), text: $fields.name).accessibilityIdentifier("rules.wizard.name")
                Picker(model.t("Target Selection"), selection: $fields.mode) {
                    Text(model.t("One Exact Folder")).tag("folder")
                    Text(model.t("Relative Patterns")).tag("patterns")
                }.pickerStyle(.segmented).accessibilityIdentifier("rules.wizard.mode")
                if fields.mode == "folder" {
                    HStack {
                        TextField(model.t("Folder relative to workspace"), text: $fields.patterns).accessibilityIdentifier("rules.wizard.folder")
                        Button(model.t("Choose Folder…")) { chooseFolder() }.accessibilityIdentifier("rules.wizard.chooseFolder")
                    }
                    Text(model.t("Only this folder is described. The workspace itself and folders outside it cannot be selected.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                } else {
                    TextField(model.t("One relative pattern per line"), text: $fields.patterns, axis: .vertical).lineLimit(3...6)
                        .font(ShouType.body.monospaced()).accessibilityIdentifier("rules.wizard.patterns")
                    Text(model.t("For example, **/.build-cache. Patterns apply inside this workspace; choosing a pattern does not prove its contents can be rebuilt.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                }
            }
            Section {
                TextField(model.t("Parent project markers, one filename per line (optional)"), text: $fields.markers, axis: .vertical).lineLimit(1...3)
                    .accessibilityIdentifier("rules.wizard.markers")
                TextField(model.t("Maximum discovery depth (1–32)"), text: $fields.depth).accessibilityIdentifier("rules.wizard.depth")
                Text(model.t("A project marker must be an exact ordinary filename in the target's parent, such as package.json. Links do not count.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            }
        }.formStyle(.grouped)
    }

    private var conditionsForm: some View {
        Form {
            Section {
                TextField(model.t("Minimum allocated size (MB, 0 for no minimum)"), text: $fields.minimumMB).accessibilityIdentifier("rules.wizard.minimumMB")
                Toggle(model.t("Keep recently modified content"), isOn: $fields.useAge).accessibilityIdentifier("rules.wizard.useAge")
                if fields.useAge {
                    TextField(model.t("Days since newest change (0–3650)"), text: $fields.age).accessibilityIdentifier("rules.wizard.age")
                }
                Text(model.t("Age uses the newest modification anywhere inside the target. MB means 1,000,000 allocated bytes; sizes remain estimates.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            }
            Section {
                TextField(model.t("Exclusion patterns relative to workspace, one per line (optional)"), text: $fields.exclusions, axis: .vertical).lineLimit(2...5)
                    .font(ShouType.body.monospaced()).accessibilityIdentifier("rules.wizard.exclusions")
                Text(model.t("For example, project/.build-cache/keep/**. Preserving a child blocks its whole parent cleanup target; Shou does not delete around it. Global and workspace protections still apply.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            }
            Section {
                TextField(model.t("How can these files be rebuilt?"), text: $fields.rebuild, axis: .vertical).lineLimit(2...4)
                    .accessibilityIdentifier("rules.wizard.rebuild")
                TextField(model.t("Limitations and data to preserve, one note per line"), text: $fields.limitations, axis: .vertical).lineLimit(2...4)
                    .accessibilityIdentifier("rules.wizard.limitations")
                Toggle(model.t("High risk (required for installed dependencies)"), isOn: $fields.highRisk).accessibilityIdentifier("rules.wizard.highRisk")
            }
        }.formStyle(.grouped)
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.t("This preview cannot delete files or create a cleanup plan."), systemImage: "eye").font(ShouType.body)
                Spacer()
                if previewing {
                    Button(model.t("Stop")) { model.cancel() }.accessibilityIdentifier("rules.wizard.stop")
                } else {
                    Button(model.t("Preview Again")) { runPreview() }.disabled(model.busy).accessibilityIdentifier("rules.wizard.preview")
                }
            }
            if previewing {
                HStack {
                    if model.reduceMotion { Image(systemName: "hourglass") }
                    else { ProgressView().controlSize(.small) }
                    Text(model.status).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("rules.wizard.progress")
                Spacer()
            } else if let preview {
                Text(String(format: model.t("%lld matching, %lld protected, %lld outside conditions"),
                            rows.filter { $0.status == "matched" }.count, rows.filter { $0.status == "blocked" }.count, rows.filter { $0.status == "not_matched" }.count))
                    .font(ShouType.body.weight(.semibold)).accessibilityIdentifier("rules.wizard.summary")
                if preview.status != "complete" {
                    Text(model.t("Partial preview. Unreadable or time-limited locations are listed below; this is not full coverage.")).font(ShouType.caption).foregroundStyle(ShouPalette.warning)
                }
                if rows.isEmpty {
                    ContentUnavailableView(model.t("No described folders in the measured scope"), systemImage: "folder.badge.questionmark", description: Text(model.t("Check the relative path, project markers and discovery depth. Conditions and protections still apply.")))
                } else {
                    Table(Array(rows.prefix(200)), selection: $focusedPath) {
                        TableColumn(model.t("Location")) { row in Text(row.path).font(ShouType.caption.monospaced()).lineLimit(2) }.width(min: 250, ideal: 380)
                        TableColumn(model.t("Disk Usage")) { row in Text(model.bytes(row.allocatedBytes)).monospacedDigit() }.width(90)
                        TableColumn(model.t("Status")) { row in Text(status(row.status)).font(ShouType.body).foregroundStyle(row.status == "matched" ? ShouPalette.text : ShouPalette.secondary) }.width(min: 105, ideal: 135)
                    }.accessibilityIdentifier("rules.wizard.results")
                    if rows.count > 200 { Text(model.t("Showing the first 200 measured folders. Counts include all measured rows.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary) }
                    if let selected=rows.first(where: { $0.path == focusedPath }) {
                        Text(selected.path).font(ShouType.caption.monospaced()).textSelection(.enabled)
                        Text(selected.reasons.isEmpty ? model.t("Conditions matched. This remains a disabled draft until you explicitly enable it and scan again.") : selected.reasons.map(explanation).joined(separator: ", "))
                            .font(ShouType.body).textSelection(.enabled).accessibilityIdentifier("rules.wizard.explanation")
                    }
                }
                if !preview.issues.isEmpty {
                    DisclosureGroup(model.t("Coverage Issues")) {
                        ScrollView { Text(preview.issues.map(model.diagnostic).joined(separator: "\n")).font(ShouType.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                    }
                }
                Text(model.t("Only rule paths are measured, within the discovery depth and scan budget. This is not a full workspace space analysis. Editing any field requires a new preview.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            } else {
                ContentUnavailableView(model.t("Preview required before saving"), systemImage: "eye", description: Text(model.t("Review the current rule against files in this workspace. A cancelled or failed preview cannot be saved as reviewed.")))
            }
        }
    }

    private func lines(_ value: String) -> [String] {
        value.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func patterns() throws -> [String] {
        guard let workspace else { throw ShouError("invalid_argument", "No workspace selected") }
        guard !fields.patterns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShouError("invalid_rule", "Choose a folder or enter a relative pattern.") }
        if fields.mode == "folder" {
            return [try PersonalRuleDraft.exactRelativePath(selection: workspace.path + "/" + fields.patterns.trimmingCharacters(in: .whitespacesAndNewlines), workspacePath: workspace.path)]
        }
        let patterns=lines(fields.patterns)
        guard !patterns.isEmpty else { throw ShouError("invalid_rule", "Choose a folder or enter a relative pattern.") }
        for pattern in patterns { try PathPattern.validate(pattern, target: true) }
        return patterns
    }

    private func makeRule() throws -> CleanupRule {
        guard let workspace else { throw ShouError("invalid_argument", "No workspace selected") }
        guard let mb=Int64(fields.minimumMB.trimmingCharacters(in: .whitespaces)), mb >= 0,
              !mb.multipliedReportingOverflow(by: 1_000_000).overflow else { throw ShouError("invalid_rule", "Enter a nonnegative whole number for minimum MB.") }
        guard let depth=Int(fields.depth.trimmingCharacters(in: .whitespaces)), (1...32).contains(depth) else { throw ShouError("invalid_rule", "Discovery depth must be a whole number from 1 to 32.") }
        var age: Int?
        if fields.useAge {
            guard let days=Int(fields.age.trimmingCharacters(in: .whitespaces)), (0...3650).contains(days) else { throw ShouError("invalid_rule", "Age must be a whole number from 0 to 3650 days.") }
            age=days
        }
        return try PersonalRuleDraft(name: fields.name, relativePatterns: patterns(), projectMarkers: lines(fields.markers), exclusions: lines(fields.exclusions), maxDepth: depth,
                                    minimumAllocatedBytes: mb * 1_000_000, minimumAgeDays: age, rebuildNote: fields.rebuild, limitations: lines(fields.limitations), highRisk: fields.highRisk)
            .rule(id: ruleId, rootRef: workspace.rootRef, platform: "macos")
    }

    private func chooseFolder() {
        guard let workspace else { return }
        let panel=NSOpenPanel(); panel.canChooseFiles=false; panel.canChooseDirectories=true; panel.allowsMultipleSelection=false; panel.resolvesAliases=false
        panel.directoryURL=URL(fileURLWithPath: workspace.path, isDirectory: true)
        panel.message=model.t("Choose a rebuildable output folder inside this workspace. No files will be removed.")
        guard panel.runModal() == .OK, let url=panel.url else { return }
        do { fields.patterns=try PersonalRuleDraft.exactRelativePath(selection: url.path, workspacePath: workspace.path) }
        catch { show(error) }
    }

    private func advance() {
        issue=nil
        do {
            if step == 0 {
                guard !fields.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShouError("invalid_rule", "Enter a rule name.") }
                _ = try patterns(); step=1
            } else { _ = try makeRule(); step=2; runPreview() }
        } catch { show(error) }
    }

    private func runPreview() {
        guard let workspace, !working, !model.busy else { return }
        do {
            let data=try Codec.encode(makeRule())
            preview=nil; rows=[]; previewedData=nil; focusedPath=nil; issue=nil; previewing=true
            model.previewRuleDraft(data, workspaceId: workspace.id) { result in
                previewing=false
                switch result {
                case .success(let value): preview=value.0; rows=value.1; previewedData=data
                case .failure(let error): show(error)
                }
            }
        } catch { show(error) }
    }

    private func save() {
        guard let previewedData, !working, !model.busy else { return }
        do {
            guard try Codec.encode(makeRule()) == previewedData else { throw ShouError("invalid_rule", "Rule changed; preview again before saving.") }
            saving=true
            Task {
                defer { saving=false }
                do { try await model.saveRule(previewedData); dismiss() }
                catch { show(error) }
            }
        } catch { show(error) }
    }

    private func show(_ error: Error) {
        if error is CancellationError { issue=model.t("Rule preview stopped."); return }
        if let failure=error as? ShouError {
            issue=model.t(failure.message)
            if let details=failure.details["issues"] { issue=model.t(failure.message) + "\n" + details }
        } else { issue=model.diagnostic(error.localizedDescription) }
    }

    private func status(_ value: String) -> String {
        switch value {
        case "matched": model.t("Conditions Matched")
        case "blocked": model.t("Protected")
        default: model.t("Conditions Not Met")
        }
    }

    private func explanation(_ value: String) -> String {
        switch value {
        case "rule_minimum_size": model.t("Below the minimum allocated size")
        case "rule_recent_modification": model.t("A file or folder was modified too recently")
        case "rule_missing_markers": model.t("A required ordinary project marker is missing from the parent")
        case "rule_maximum_depth": model.t("Beyond the rule discovery depth")
        case "excluded_descendant": model.t("Contains excluded content; the entire cleanup target is preserved")
        case "protected_content": model.t("Contains protected content")
        case "incomplete_scan": model.t("Target inspection is incomplete")
        default: model.t(value)
        }
    }
}
