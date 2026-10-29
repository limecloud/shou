import Foundation

/// Independent item failures do not suppress work on the remaining selection.
/// Lost outcomes and journal/identity-scope failures still stop the operation.
enum ExecutionFailurePolicy {
    static func continues(after error: Error) -> Bool {
        ["permission_denied", "io_error", "resource_limit", "plan_stale", "application_changed", "application_running",
         "application_activity_unavailable", "ownership_unverified", "protected_content", "partial_removal"].contains((error as? ShouError)?.code ?? "")
    }
    static func authorizationCancelled(_ error: Error) -> Bool {
        ["authorization_cancelled", "authorization_denied"].contains((error as? ShouError)?.code ?? "")
    }
}
