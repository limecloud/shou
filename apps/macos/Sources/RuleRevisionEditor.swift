import SwiftUI
import ShouCore

struct RuleRevisionEditor: View {
    var model: AppModel
    let original: RuleRecord
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var validatedData: Data?
    @State private var issue: String?
    @State private var saving=false

    init(model: AppModel, original: RuleRecord) {
        self.model=model; self.original=original
        do {
            var draft=original.rule
            let versions=Set(model.configuration.rules.filter { $0.rule.id == draft.id }.map { $0.rule.version })
            let parts=draft.version.split(separator: ".").map(String.init)
            if parts.count == 3, var patch=Int(parts[2]) {
                while patch < Int.max {
                    patch += 1
                    let version=parts[0] + "." + parts[1] + "." + String(patch)
                    if version.count > 32 { break }
                    if !versions.contains(version) { draft.version=version; break }
                }
            }
            let object=try JSONSerialization.jsonObject(with: Codec.encode(draft))
            let data=try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            _text=State(initialValue: String(decoding: data, as: UTF8.self))
        } catch {
            _text=State(initialValue: "")
            _issue=State(initialValue: error.localizedDescription)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.t("Edit Personal Rule")).font(.title2.bold())
            Text(original.rule.id + " · " + original.rule.version).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text(model.t("Edit the complete JSON definition. Keep the rule ID and use an unused version.")).font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityLabel(model.t("Rule JSON"))
                .accessibilityIdentifier("rules.revision.json")
                .disabled(saving)
            if let issue {
                ScrollView { Text(issue).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 85)
                    .accessibilityIdentifier("rules.revision.issue")
            } else if validatedData != nil {
                Label(model.t("Rule is valid. Ready to save as a disabled version."), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            }
            Text(model.t("The new version stays disabled. Existing bindings keep their version. Preview the new draft, then enable it and scan again.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.t("Validate Rule")) { validate() }.disabled(saving || model.busy)
                    .accessibilityIdentifier("rules.revision.validate")
                Spacer()
                Button(model.t("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(model.t("Save New Version")) { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(validatedData == nil || saving || model.busy)
                    .accessibilityIdentifier("rules.revision.save")
            }
        }.padding(24).frame(width: 760, height: 660)
            .onChange(of: text) { _, _ in validatedData=nil; issue=nil }
            .interactiveDismissDisabled(saving)
    }

    private func validate() {
        validatedData=nil; issue=nil
        do {
            let data=Data(text.utf8)
            let rule=try CleanupRule.parse(data)
            guard rule.id == original.rule.id else { throw ShouError("invalid_rule", "Keep the original rule ID when editing a version.") }
            guard !model.configuration.rules.contains(where: { $0.rule.id == rule.id && $0.rule.version == rule.version }) else {
                throw ShouError("version_conflict", "Choose an unused rule version. Existing versions cannot be overwritten.")
            }
            validatedData=data
        } catch { show(error) }
    }

    private func save() {
        validate()
        guard let data=validatedData else { return }
        saving=true
        Task {
            defer { saving=false }
            do { try await model.saveRule(data, requireNewVersion: true); dismiss() }
            catch { show(error) }
        }
    }

    private func show(_ error: Error) {
        validatedData=nil
        if let failure=error as? ShouError {
            issue=model.t(failure.message)
            if let details=failure.details["issues"] { issue=model.t(failure.message) + "\n" + details }
        } else { issue=error.localizedDescription }
    }
}
