import Foundation

enum NativeDeveloperStorageRoots {
    static func referenceData(home: URL) -> [URL] {
        var roots=["Library/PhpWebStudy", "Library/FlyEnv", "Library/Application Support/FlyEnv"].map { home.appendingPathComponent($0) }
        if let path=ProcessInfo.processInfo.environment["FLYENV_DATA_ROOT"], path.hasPrefix("/"),
           !path.unicodeScalars.contains(where:{ $0.value < 32 || $0.value == 127 }) {
            roots.append(URL(fileURLWithPath:path))
        }
        return roots
    }
}
