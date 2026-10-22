import Foundation
import ShouCore

/// Maps bundled application identities to Windows executable names. Unknown
/// identities and process inspection errors preserve the cleanup activity gate.
public struct WindowsApplicationActivity: ApplicationActivityChecking {
    public static let executableNames=[
        "com.google.Chrome": "chrome.exe", "org.chromium.Chromium": "chrome.exe", "com.microsoft.edgemac": "msedge.exe",
        "com.microsoft.VSCode": "Code.exe", "com.microsoft.VSCodeInsiders": "Code - Insiders.exe", "com.brave.Browser": "brave.exe",
        "com.vivaldi.Vivaldi": "vivaldi.exe", "org.mozilla.firefox": "firefox.exe", "com.tinyspeck.slackmacgap": "slack.exe",
        "com.hnc.Discord": "Discord.exe", "notion.id": "Notion.exe", "com.postmanlabs.mac": "Postman.exe", "com.todesktop.230313mzl4w4u92": "Cursor.exe"
    ]
    private let processRunning: @Sendable (String) throws -> Bool

    public init(processRunning: @escaping @Sendable (String) throws -> Bool) {
        self.processRunning=processRunning
    }

    public func runningBundleIdentifiers(in identifiers: Set<String>) throws -> Set<String> {
        let requested=try identifiers.sorted().map { identifier in
            guard let name=Self.executableNames[identifier] else {
                throw ShouError("application_activity_unavailable", "Unknown Windows application activity mapping.")
            }
            return (identifier, name)
        }
        var running=Set<String>()
        for (identifier, name) in requested {
            if try processRunning(name) { running.insert(identifier) }
        }
        return running
    }
}
