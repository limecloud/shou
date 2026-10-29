import Foundation

public enum SystemAuthorizationState: String, Codable, Sendable {
    case notRequested, authorized, cancelled, unavailable
}

public enum SystemAccessRequirement: String, Codable, Sendable {
    case administrator, fullDiskAccess
}

public extension ShouError {
    var accessRequirement: SystemAccessRequirement? {
        if let value=details["access_requirement"] { return SystemAccessRequirement(rawValue: value) }
        return ["authorization_denied", "authorization_unavailable"].contains(code) ? .administrator : nil
    }
}

/// System privilege is a process capability, never a cleanup confirmation.
/// Every mutation still binds its own current selection and records its result.
public protocol SystemAuthorizationProviding: Sendable {
    var administratorState: SystemAuthorizationState { get }
    func authorizeAdministrator() throws
}
