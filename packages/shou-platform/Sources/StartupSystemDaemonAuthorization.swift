import Foundation
import ShouCore

/// The administrator request is a fixed launchctl operation. There are no
/// caller-supplied shell fragments, paths, environment assignments or helpers.
public enum StartupSystemDaemonAuthorization {
    public static func script(action: StartupControlAction, label: String) throws -> String {
        try validate(action:action,label:label)
        return "do shell script \"/bin/launchctl \(action.rawValue) system/\(label)\" with administrator privileges"
    }
    public static func apply(label: String, action: StartupControlAction,
                             command: NativeStartupControl.Command, administrator: NativeStartupControl.Command) throws -> String {
        try validate(action:action,label:label)
        let changed=try administrator([action.rawValue,"system/" + label],120)
        guard changed.status == 0 else { throw ShouError("startup_control_failed", "The administrator did not change the system startup definition.",details:["status":String(changed.status)]) }
        let observed=try command(["print-disabled","system"],2)
        let expected=action == .enable ? "enabled" : "disabled"
        guard observed.status == 0, LaunchctlStateParser.disabledOverrides(observed.output)?[label] == expected else {
            throw ShouError("startup_verification_failed", "The system startup state may have changed, but launchctl readback could not verify it. Scan again before retrying.")
        }
        return expected
    }
    private static func validate(action: StartupControlAction, label: String) throws {
        guard action != .remove, !label.hasPrefix("com.apple."),
              label.range(of:"^[A-Za-z0-9._@-]{1,255}$",options:.regularExpression) != nil else {
            throw ShouError("permission_denied", "Only a fixed third-party system launchctl toggle may request administrator authorization.")
        }
    }
}
