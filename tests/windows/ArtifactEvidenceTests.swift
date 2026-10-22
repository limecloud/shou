import Foundation
import ShouCore
import ShouPlatform

func windowsArtifactEvidenceChecksNativeGitAndProjectProcesses(root: String) throws {
    let fs=NativeFileSystem(), evidence=NativeArtifactEvidence()
    let project=root + "/evidence-project", other=root + "/other-project"
    try privateDirectory(project); try privateDirectory(other)
    try require(try !evidence.hasGitTrackedFiles(at: project), "Untracked fixture directories should not contain tracked artifacts")
    try require(try evidence.runningBuildProcesses(in: [], affecting: project).isEmpty, "Empty process sets should not inspect unrelated processes")

    let childName="shou-evidence-" + UUID().uuidString.lowercased()
    let childURL=URL(fileURLWithPath: root).appendingPathComponent(childName + ".exe")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: childURL)
    let child=Process(); child.executableURL=childURL; child.arguments=["--evidence-child"]
    child.currentDirectoryURL=URL(fileURLWithPath: project)
    let ready=Pipe(); child.standardOutput=ready; child.standardError=FileHandle.standardError
    try child.run()
    defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
    // The child emits this after startup, so no timing-based readiness guess is
    // needed before reading its native process parameters.
    let signal=ready.fileHandleForReading.readData(ofLength: 1)
    try require(signal == Data([1]), "Evidence child did not become ready")
    let names: Set<String>=[childName]
    try require(try evidence.runningBuildProcesses(in: names) == names, "Global build process discovery failed")
    try require(try evidence.runningBuildProcesses(in: names, affecting: project) == names, "The active project's build process was missed")
    try require(try evidence.runningBuildProcesses(in: names, affecting: other).isEmpty, "An unrelated project was blocked by another build")
    print("PASS native process identity and working-directory scoping across projects")

    let gitRoots=["ProgramW6432", "ProgramFiles", "ProgramFiles(x86)"].compactMap { ProcessInfo.processInfo.environment[$0] }
    guard let git=gitRoots.map({ URL(fileURLWithPath: $0).appendingPathComponent("Git/cmd/git.exe") }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
        throw Failure(message: "Native Git evidence tests require a standard Git installation")
    }
    func command(_ arguments: [String]) throws {
        let process=Process(); process.executableURL=git; process.arguments=arguments
        process.currentDirectoryURL=URL(fileURLWithPath: project)
        var environment=ProcessInfo.processInfo.environment.filter { !$0.key.uppercased().hasPrefix("GIT_") && !$0.key.uppercased().hasPrefix("GCM_") }
        environment["GIT_CONFIG_NOSYSTEM"]="1"; environment["GIT_CONFIG_GLOBAL"]="NUL"; environment["GIT_TERMINAL_PROMPT"]="0"
        process.environment=environment
        try process.run(); process.waitUntilExit()
        try require(process.terminationStatus == 0, "Isolated Git fixture setup failed")
    }
    try command(["init", "--quiet", "--separate-git-dir", root + "/isolated-git-metadata", project])
    let generated=project + "/dist"; try privateDirectory(generated)
    try write(generated + "/tracked.js", "generated Git boundary fixture")
    try require(try !evidence.hasGitTrackedFiles(at: generated), "Untracked generated output was incorrectly protected as tracked")
    try command(["-C", project, "-c", "core.autocrlf=false", "add", "--", "dist/tracked.js"])
    try require(try evidence.hasGitTrackedFiles(at: generated), "A tracked generated-looking file must remain protected")
    print("PASS native Git tracked/untracked evidence and gitdir-file workspaces; no commits created")

    let locations=try KnownLocations.catalog(platform: "windows")
    for location in locations where location.path.lowercased().contains("/appdata/") {
        guard FileManager.default.fileExists(atPath: location.path) else { continue }
        let metadata=try fs.analysisRootIdentity(location.path)
        guard metadata.windowsIdentity?.ownerSid == (try fs.analysisRootIdentity(project)).windowsIdentity?.ownerSid else { continue }
        _=try fs.rootIdentity(location.path)
    }
    let home=FileManager.default.homeDirectoryForCurrentUser.path
    for path in [home + "/AppData", home + "/AppData/Local", home + "/AppData/Roaming"] where FileManager.default.fileExists(atPath: path) {
        do { _=try fs.rootIdentity(path); throw Failure(message: "A broad AppData root was authorized") }
        catch let error as ShouError { try require(error.code == "permission_denied", "Unexpected AppData root refusal") }
    }
    print("PASS existing built-in cache roots and broad AppData root refusal (read-only)")
}
