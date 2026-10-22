import Foundation
import ShouCore
import ShouPlatform
import CShouWindows

func windowsPrivacySourcesPinDatabasePathsAndRejectHardlinks(root: String) throws {
    let home=root + "/privacy-home"
    try privateDirectory(home)
    let relative=PrivacySourcePolicy.windowsChromiumRoots[0].2 + "/Default/Network/Cookies"
    var directory=home
    for component in relative.split(separator: "/").dropLast() { directory += "/" + component; try privateDirectory(directory) }
    let path=home + "/" + relative
    try write(path, "Generated identity fixture; no browser rows.")
    let catalog=NativePrivacySources(), definitions=try catalog.discover(home: URL(fileURLWithPath: home))
    guard let source=definitions.first(where: { $0.relativePath == relative }) else { throw Failure(message: "Standard Windows privacy source missing") }
    try require(source.platform == "windows" && PrivacySourcePolicy.valid(source), "Privacy source platform or scope is invalid")
    let evidence=try catalog.evidence(source: source, home: URL(fileURLWithPath: home), writable: false)
    try require(evidence.last?.path == "database" && evidence.allSatisfy { $0.windowsIdentity != nil }, "Privacy evidence lost Windows File ID or SID")
    let access=try catalog.acquire(source: source, home: URL(fileURLWithPath: home), writable: false)
    let destination=path + ".renamed"
    do {
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        access.release()
        throw Failure(message: "A pinned privacy database was replaced")
    } catch is Failure { throw Failure(message: "A pinned privacy database was replaced") }
    catch { }
    access.release()
    try FileManager.default.moveItem(atPath: path, toPath: destination)
    try FileManager.default.moveItem(atPath: destination, toPath: path)
    try require(try catalog.evidence(source: source, home: URL(fileURLWithPath: home), writable: false).last?.sameObject(as: evidence.last!) == true, "Releasing a privacy lease changed its source")
    let alias=path + ".hardlink"
    try FileManager.default.linkItem(atPath: path, toPath: alias)
    var handle: OpaquePointer?
    let result=shou_win_privacy_acquire(home, path, 0, &handle)
    defer { shou_win_privacy_release(handle) }
    try require(result != 0 && handle == nil, "Privacy access accepted a hardlinked database")
    try FileManager.default.removeItem(atPath: alias)
    try require(shou_win_privacy_acquire(home + "-other", path, 0, &handle) != 0 && handle == nil, "Privacy access escaped the exact home boundary")
    print("PASS native privacy source scope, full identities, pinned namespace, lease release and hardlink refusal")
}
