import Foundation
import ShouCore
import ShouPlatform
#if canImport(WinSDK)
import WinSDK
#endif

func windowsCanonicalSpellingRetainsProtectedRoots(root: String) throws {
    #if canImport(WinSDK)
    func shortPath(_ path: String) throws -> String {
        let source=Array(path.replacingOccurrences(of: "/", with: "\\").utf16) + [0]
        var output=[UInt16](repeating: 0, count: 32768)
        let count=source.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { buffer in
                GetShortPathNameW(input.baseAddress, buffer.baseAddress, UInt32(buffer.count))
            }
        }
        try require(count > 0 && Int(count) < output.count, "Could not query DOS path spelling")
        return String(decoding: output.prefix(Int(count)), as: UTF16.self)
    }
    let fs=NativeFileSystem(), alias=try shortPath(root)
    try require(try fs.normalizedPath(alias).lowercased() == fs.normalizedPath(root).lowercased(), "DOS aliases must share canonical spelling")
    try require(try fs.normalizedPath(alias + "/not-created/leaf").lowercased() == fs.normalizedPath(root + "/not-created/leaf").lowercased(),
        "New destinations must retain their existing ancestor's canonical spelling")
    let appData=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData").path
    let protectedAlias=try shortPath(appData)
    do {
        _ = try fs.rootIdentity(protectedAlias)
        throw Failure(message: "DOS spelling bypassed the protected AppData root")
    } catch let error as ShouError { try require(error.code == "permission_denied", "Unexpected protected-root error") }
    if alias.contains("~") || protectedAlias.contains("~") { print("PASS DOS aliases expand before protected-root checks") }
    else { print("PASS canonical spelling and protected roots; SKIP alternate DOS spelling because this volume did not return one") }
    #endif
}
