import AppKit
import SwiftUI
import ShouCore

/// The shipped catalog is visible before a workspace exists. Only rules bound
/// to the current workspace expose controls that can change its configuration.
struct BuiltinRulesCatalogView: View {
    @Bindable var model: AppModel
    @State private var query=""

    private var templates: [BuiltinTemplate] {
        model.builtinTemplates.filter { matches(name: $0.name, location: locationTitle($0.location), patterns: $0.patterns) }
    }
    private var additionalRules: [CleanupRule] {
        let shipped=Set(model.builtinTemplates.map(\.id))
        return model.builtins.filter { !shipped.contains($0.id) && matches(name: $0.name, location: model.workspace?.path ?? "", patterns: $0.match.relativePatterns) }
    }
    private func matches(name: String, location: String, patterns: [String]) -> Bool {
        query.isEmpty || ([name, model.t(name), location] + patterns).contains { $0.localizedStandardContains(query) }
    }
    private func locationTitle(_ id: String) -> String {
        if id == "projects" { return model.t("Developer Projects") }
        return model.knownLocations.first { $0.id == id }.map { model.t($0.title) } ?? id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(model.t("Built-in Rules")).font(.headline)
                Text(String(templates.count + additionalRules.count)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 12)
                TextField(model.t("Search rules or paths"), text: $query)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .accessibilityIdentifier("rules.builtin.search")
            }
            Text(model.t("Built-in rules are included with Shou and automatically match supported scan locations. Select a location to manage the rules that apply there."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(templates) { template in
                    catalogRow(id: template.id, name: template.name, note: template.rebuildNote, limitation: template.limitation,
                        location: locationTitle(template.location), rule: model.builtins.first { $0.id == template.id })
                    Divider()
                }
                ForEach(additionalRules) { rule in
                    catalogRow(id: rule.id, name: rule.name, note: rule.risk.rebuildNote, limitation: rule.risk.limitations.first ?? "",
                        location: model.workspace?.path ?? "", rule: rule)
                    Divider()
                }
                if templates.isEmpty && additionalRules.isEmpty {
                    ContentUnavailableView(model.t("No matching rules"), systemImage: "magnifyingglass")
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityIdentifier("rules.builtin.catalog")
    }

    private func catalogRow(id: String, name: String, note: String, limitation: String, location: String, rule: CleanupRule?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(model.t(name)).font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let rule, model.workspace != nil {
                    Toggle(model.t(name), isOn: Binding(
                        get: { !model.configuration.bindings.contains { $0.workspaceId == model.workspaceId && $0.ruleId == id && !$0.enabled } },
                        set: { model.setEnabled(rule, enabled: $0) }))
                        .labelsHidden().toggleStyle(.switch).disabled(model.busy)
                        .accessibilityIdentifier("rules.builtin.toggle." + id)
                }
            }
            Text(model.t(note)).font(.callout).foregroundStyle(.secondary)
            Text(model.t(limitation)).font(.caption).foregroundStyle(.secondary)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain).accessibilityIdentifier("rules.builtin." + id)
    }
}
