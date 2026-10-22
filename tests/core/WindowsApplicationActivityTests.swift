import Foundation
import ShouCore
import ShouPlatform

private final class WindowsProcessFixture: @unchecked Sendable {
    private let lock=NSLock()
    private var running=Set<String>()
    private var queried=Set<String>()
    func setRunning(_ names: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        running=names; queried=[]
    }
    func contains(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        queried.insert(name)
        return running.contains(name)
    }
    func inspected() -> Set<String> { lock.lock(); defer { lock.unlock() }; return queried }
}

func windowsCacheApplicationsRequireMappedProcessEvidence() throws {
    let guarded=try BuiltinCatalog.templates().filter {
        $0.supportedPlatforms.contains("windows") && !($0.applicationBundleIdentifiers ?? []).isEmpty
    }
    let expected=[
        "windows-chrome": "chrome.exe", "windows-edge": "msedge.exe", "windows-vscode": "Code.exe",
        "windows-brave": "brave.exe", "windows-vivaldi": "vivaldi.exe", "windows-firefox": "firefox.exe",
        "windows-slack": "slack.exe", "windows-discord": "Discord.exe", "windows-notion": "Notion.exe",
        "windows-postman": "Postman.exe", "windows-vscode-insiders": "Code - Insiders.exe", "windows-cursor": "Cursor.exe"
    ]
    try expect(Set(guarded.map(\.location)) == Set(expected.keys))
    let fixture=WindowsProcessFixture()
    let activity=WindowsApplicationActivity(processRunning: { fixture.contains($0) })
    let ids=guarded.map(\.id)
    for template in guarded {
        let process=try require(expected[template.location])
        fixture.setRunning([process])
        let blocked=ApplicationSafety.blockedRules(ids + ["personal.cache"], activity: activity)
        try expect(blocked == [template.id: "application_running"])
        try expect(fixture.inspected() == Set(expected.values))
    }
    fixture.setRunning(["unrelated.exe"])
    try expect(ApplicationSafety.blockedRules(ids, activity: activity).isEmpty)
    fixture.setRunning([])
    try expect(try activity.runningBundleIdentifiers(in: []).isEmpty && fixture.inspected().isEmpty)

    // A new or misspelled identity must not remove its process gate.
    try expectThrows { try activity.runningBundleIdentifiers(in: ["org.example.unmapped"]) }
    try expect(fixture.inspected().isEmpty)
    let denied=WindowsApplicationActivity(processRunning: { _ in
        throw ShouError("access_denied", "Generated process inspection failure.")
    })
    let blocked=ApplicationSafety.blockedRules(ids + ["personal.cache"], activity: denied)
    try expect(blocked == Dictionary(uniqueKeysWithValues: ids.map { ($0, "application_activity_unavailable") }))
}
