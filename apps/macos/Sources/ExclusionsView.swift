import SwiftUI
import ShouCore

struct ExclusionsView: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope: String
    @State private var workspaceId: String
    @State private var project=""
    @State private var pattern=""
    @State private var issue: String?
    @State private var saving=false

    init(model: AppModel) {
        self.model=model
        _workspaceId=State(initialValue: model.workspaceId)
        _scope=State(initialValue: model.workspace == nil ? "global" : "workspace")
    }

    private var workspace: Workspace? { model.configuration.workspaces.first { $0.id == workspaceId } }
    private var globalPatterns: [String] { model.configuration.globalExclusions ?? [] }
    private var entries: [String] {
        if scope == "global" { return globalPatterns }
        let patterns=workspace?.exclusions ?? []
        if scope == "project" { return project.isEmpty ? [] : patterns.filter { $0.hasPrefix(project + "/") } }
        return patterns
    }
    private var inputPattern: String { scope == "project" && pattern.isEmpty ? "**" : pattern }
    private var resolvedPattern: String? {
        guard scope == "global" || workspace != nil else { return nil }
        if scope == "project" { return try? ExclusionPattern.scopedToProject(project, pattern: inputPattern) }
        guard (try? PathPattern.validate(pattern)) != nil else { return nil }
        return pattern
    }
    private var inputIssue: String? {
        guard !pattern.isEmpty || (scope == "project" && !project.isEmpty) else { return nil }
        do {
            if scope == "project" { _ = try ExclusionPattern.scopedToProject(project, pattern: inputPattern) }
            else { try PathPattern.validate(pattern) }
            return nil
        } catch { return model.diagnostic(error.localizedDescription) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t("Exclusions")).font(ShouType.title.bold())
            Text(model.t("Excluded content also protects its parent cleanup target. Changes require a fresh scan.")).font(ShouType.body).foregroundStyle(ShouPalette.secondary)
            Picker(model.t("Exclusion Scope"), selection: $scope) {
                Text(model.t("All Workspaces")).tag("global")
                Text(model.t("Workspace")).tag("workspace")
                Text(model.t("Project")).tag("project")
            }.pickerStyle(.segmented).disabled(saving)
            if scope != "global" {
                Picker(model.t("Workspace"), selection: $workspaceId) {
                    if model.configuration.workspaces.isEmpty { Text(model.t("No workspace selected")).tag("") }
                    ForEach(model.configuration.workspaces) { root in
                        Text(model.knownLocations.first { $0.path == root.path }.map { model.t($0.title) } ?? root.path).tag(root.id)
                    }
                }.disabled(saving || model.configuration.workspaces.isEmpty)
                if let workspace { Text(workspace.path).font(ShouType.caption.monospaced()).foregroundStyle(ShouPalette.secondary).textSelection(.enabled) }
            } else {
                Text(model.t("Global patterns apply relative to every current and future workspace. Earlier builds cannot read the upgraded configuration.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            }
            if scope == "project" {
                TextField(model.t("Project directory relative to workspace"), text: $project).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("exclusions.project")
                Text(model.t("Use an exact relative project directory. Leave the pattern empty to protect the whole project.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            }
            HStack {
                TextField(model.t("Relative exclusion pattern"), text: $pattern).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("exclusions.pattern")
                Button(model.t("Add Exclusion")) { add() }.buttonStyle(.borderedProminent)
                    .disabled(resolvedPattern == nil || saving || model.busy)
                    .accessibilityIdentifier("exclusions.add")
            }.disabled(saving)
            if let resolvedPattern {
                Text(resolvedPattern).font(ShouType.caption.monospaced()).foregroundStyle(ShouPalette.secondary).textSelection(.enabled)
            } else {
                Text(model.t("Use relative patterns such as **/target/** or **/keep/**. Absolute paths and parent traversal are not allowed.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
            }
            if let message=issue ?? inputIssue { Text(message).font(ShouType.caption).foregroundStyle(ShouPalette.danger).textSelection(.enabled) }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.t(scope == "global" ? "Global Exclusions" : "Workspace Exclusions")).font(ShouType.body.weight(.semibold))
                    if entries.isEmpty { Text(model.t("No exclusions in this scope.")).foregroundStyle(ShouPalette.secondary).padding(.vertical, 12) }
                    ForEach(entries, id: \.self) { entry in
                        HStack {
                            Text(entry).font(ShouType.body.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button { remove(entry) } label: { Label(model.t("Remove Exclusion"), systemImage: "xmark.circle") }
                                .disabled(saving || model.busy).buttonStyle(.bordered)
                        }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if scope != "global", !globalPatterns.isEmpty {
                        Divider()
                        Text(model.t("Inherited Global Exclusions")).font(ShouType.body.weight(.semibold))
                        ForEach(globalPatterns, id: \.self) { Text($0).font(ShouType.body.monospaced()).textSelection(.enabled) }
                        Text(model.t("Manage these patterns in All Workspaces. Per-rule exclusions remain in each rule definition.")).font(ShouType.caption).foregroundStyle(ShouPalette.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button(model.t("Close")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving) }
        }.padding(24).frame(width: 760, height: 520)
            .onChange(of: scope) { _, _ in issue=nil; pattern="" }
            .onChange(of: workspaceId) { _, _ in issue=nil; project=""; pattern="" }
            .onChange(of: pattern) { _, _ in issue=nil }
            .onChange(of: project) { _, _ in issue=nil }
            .interactiveDismissDisabled(saving)
    }

    private func add() {
        guard resolvedPattern != nil else { return }
        apply(pattern: inputPattern, remove: false, project: scope == "project" ? project : nil)
    }
    private func remove(_ entry: String) { apply(pattern: entry, remove: true) }
    private func apply(pattern: String, remove: Bool, project: String? = nil) {
        let target=scope == "global" ? nil : workspaceId
        saving=true; issue=nil
        Task {
            defer { saving=false }
            do { try await model.saveExclusion(workspaceId: target, pattern: pattern, remove: remove, project: project); if !remove { self.pattern="" } }
            catch { issue=model.diagnostic(error.localizedDescription) }
        }
    }
}
