import Foundation
import ShouCore

/// Maps bundled application identities to Windows executable names. Unknown
/// identities and process inspection errors preserve the cleanup activity gate.
public struct WindowsApplicationActivity: ApplicationActivityChecking {
    private let processRunning: @Sendable (String) throws -> Bool

    public init(processRunning: @escaping @Sendable (String) throws -> Bool) {
        self.processRunning=processRunning
    }

    public func runningBundleIdentifiers(in identifiers: Set<String>) throws -> Set<String> {
        let names=[
            "com.google.Chrome": "chrome.exe",
            "com.microsoft.edgemac": "msedge.exe",
            "com.microsoft.VSCode": "Code.exe",
            "com.microsoft.VSCodeInsiders": "Code - Insiders.exe",
            "com.brave.Browser": "brave.exe",
            "com.vivaldi.Vivaldi": "vivaldi.exe",
            "org.mozilla.firefox": "firefox.exe",
            "com.tinyspeck.slackmacgap": "slack.exe",
            "com.hnc.Discord": "Discord.exe",
            "notion.id": "Notion.exe",
            "com.postmanlabs.mac": "Postman.exe",
            "com.todesktop.230313mzl4w4u92": "Cursor.exe"
        ]
        guard identifiers.allSatisfy({ names[$0] != nil }) else {
            throw ShouError("application_activity_unavailable", "Unknown Windows application activity mapping.")
        }
        var running=Set<String>()
        for identifier in identifiers.sorted() {
            if try processRunning(names[identifier]!) { running.insert(identifier) }
        }
        return running
    }
}
