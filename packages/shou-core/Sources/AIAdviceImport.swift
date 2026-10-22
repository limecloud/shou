import Foundation

extension ShouEngine {
    /// The same disabled-draft import used by local authoring. No binding is enabled.
    public func importInvestigationAdvice(_ advice: AIAdvice, scanId: String) throws -> RuleRecord {
        let scan=try storageScan(scanId)
        try AIEvidencePolicy.validate(advice.path)
        guard advice.path != ".", !advice.path.contains("*"), !advice.path.contains("?"), advice.rule.match.relativePatterns == [advice.path],
              advice.rule.risk.declaredLevel == "high" else { throw ShouError("invalid_ai_advice", "Choose an exact high-risk AI rule draft.") }
        guard try filesystem.rootIdentity(scan.rootPath).sameObject(as: scan.identity) else {
            throw ShouError("stale_ai_evidence", "The investigation folder changed. Scan it again before importing a rule.")
        }
        let config=try configuration()
        let workspace: Workspace
        if let existing=config.workspaces.first(where: { $0.path == scan.rootPath && $0.identity.sameObject(as: scan.identity) }) {
            workspace=existing
        } else {
            workspace=try addWorkspace(path: scan.rootPath, rootRef: "ai-" + UUID().uuidString.lowercased())
        }
        var fields=try JSONValue.from(advice.rule).object ?? [:]
        var scope=fields["scope"]?.object ?? [:]
        scope["root_ref"] = .string(workspace.rootRef); fields["scope"] = .object(scope)
        return try importRule(Codec.encode(JSONValue.object(fields)), provenance: "embedded_ai")
    }
}
