import Foundation
import ShouCore
import ShouPlatform

enum PrivacyCLI {
    static let commands: [CommandSpec] = [
        .init("privacy scan", "snapshot", [], ["range"], "Count known browser history and cookies without reading record contents. Range last-hour (default), last-day (rolling 24 hours), last-seven-days, or all-time. Running browsers are blocked. All sources remain unselected."),
        .init("privacy scan show", "read", ["scan-id"], [], "Show aggregate privacy source counts and explicit unavailable or unsupported statuses. No URLs, domains or cookie values are returned."),
        .init("privacy plan", "plan", ["scan-id", "source"], ["acknowledge-sign-out"], repeated: ["source"], "Plan exact ready source IDs. Cookie sources require acknowledge-sign-out true; default false. Plans expire and permanently delete selected records after separate terminal confirmation."),
        .init("privacy plan show", "read", ["plan-id"], [], "Show the exact privacy sources, time bounds, irreversible impact, digest and expiry."),
        .init("privacy execute", "destructive", ["plan-id"], [], "Permanently remove privacy records after interactive terminal confirmation. Recheck browser activity, source identity, schema, protection configuration and counts; commit each database independently. No Trash or restore capability."),
        .init("privacy history", "read", [], [], "List privacy receipts containing only source IDs, time bounds, aggregate counts and item statuses. Interrupted execution is never automatically retried.")
    ]
    static func run(_ args: Arguments, engine: ShouEngine) async throws -> Bool {
        guard args.command.hasPrefix("privacy ") else { return false }
        let service=await engine.privacyService(activity: NativeApplicationActivity(), sources: NativePrivacySources())
        let value: JSONValue
        switch args.command {
        case "privacy scan":
            let raw=args.value("range")
            guard let range=PrivacyTimeRange(rawValue: raw.isEmpty ? "last-hour" : raw) else { throw ShouError("invalid_argument", "Unknown privacy time range.") }
            value=try .from(await service.scan(range: range))
        case "privacy scan show": value=try .from(await service.scan(id: args.value("scan-id")))
        case "privacy plan":
            let raw=args.value("acknowledge-sign-out")
            guard raw.isEmpty || ["true", "false"].contains(raw) else { throw ShouError("invalid_argument", "acknowledge-sign-out must be true or false.") }
            value=try .from(await service.preparePlan(scanId: args.value("scan-id"), sourceIDs: args.all("source"), acknowledgeSignOut: raw == "true"))
        case "privacy plan show": value=try .from(await service.plan(id: args.value("plan-id")))
        case "privacy execute":
            let plan=try await service.plan(id: args.value("plan-id"))
            struct Scope: Encodable {
                let warning: String
                let irreversible: Bool
                let canSignOut: Bool
                let restoreSupported: Bool
                let plan: PrivacyPlan
            }
            let warning=args.locale == "zh-CN" ? "永久删除选中隐私记录；不会进入废纸篓，无法通过历史恢复。Cookie 可能使你退出登录。" : "Permanently delete the selected records. They will not enter Trash and cannot be restored through history. Cookies may sign you out."
            try Terminal.confirm(Scope(warning: warning, irreversible: true, canSignOut: plan.requiresSignOutConsent, restoreSupported: false, plan: plan), phrase: "DELETE-PRIVACY", locale: args.locale)
            value=try .from(await service.execute(planId: plan.id, digest: plan.digest, consent: PrivacyConsent(irreversibleDeletion: true, signOut: plan.requiresSignOutConsent)))
        case "privacy history": value=try .from(await service.history())
        default: return false
        }
        try ShouCLI.result(value, json: args.json); return true
    }
}
