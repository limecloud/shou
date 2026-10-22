#if os(Windows)
import Foundation
import ShouCore
import CShouWindows

extension NativeArtifactEvidence {
    func windowsGitTrackedFiles(at path: String) throws -> Bool {
        let path=try NativeFileSystem().normalizedPath(path)
        let target=try WindowsNative.metadata(path)
        var directory=path
        var marker: (String, FileEntry)?
        while true {
            let git=directory + (directory.hasSuffix("/") ? "" : "/") + ".git"
            do {
                let value=try WindowsNative.metadata(git)
                guard value.kind == 1 || value.kind == 2 else { throw unavailable("The Git ownership marker cannot be safely inspected.") }
                marker=(git, WindowsNative.entry(value, path: ".")); break
            } catch let error as ShouError where error.code == "not_found" { }
            catch { throw unavailable("Git ownership could not be safely inspected.") }
            if directory.count <= 3 { return false }
            guard let slash=directory.lastIndex(of: "/") else { throw unavailable("The Git ancestor path is invalid.") }
            directory=String(directory[..<slash]); if directory.hasSuffix(":") { directory += "/" }
        }
        var tracked: Int32=0
        let code=shou_win_git_tracked(path, &tracked)
        guard code == 0, let marker,
              try WindowsNative.entry(WindowsNative.metadata(path), path: ".") == WindowsNative.entry(target, path: "."),
              try WindowsNative.entry(WindowsNative.metadata(marker.0), path: ".") == marker.1 else {
            throw unavailable("Git ownership could not be verified with a trusted local Git installation.")
        }
        return tracked != 0
    }

    func windowsBuildProcesses(in names: Set<String>, project: String? = nil) throws -> Set<String> {
        guard names.count <= 64, names.allSatisfy({ $0.range(of: "^[A-Za-z0-9_.+-]{1,128}$", options: .regularExpression) != nil }) else {
            throw unavailable("Build process names must be exact executable names.")
        }
        if names.isEmpty { return [] }
        let output: String
        do {
            output=try WindowsNative.string({ result in
                let list=names.sorted().joined(separator: "\n")
                if let project { return shou_win_build_processes(list, project, result) }
                return shou_win_build_processes(list, nil, result)
            }, path: project ?? "build-processes")
        } catch { throw unavailable("Build process ownership or working directory could not be verified.") }
        let running=Set(output.split(separator: "\n").map(String.init))
        guard running.isSubset(of: names) else { throw unavailable("Build process output is invalid.") }
        return running
    }
}
#endif
