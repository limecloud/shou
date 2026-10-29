import Foundation

public enum ProgressPresentation {
    /// Only selected targets and their descendants belong on a mutation progress page.
    public static func selectedPath(_ path: String, within selectedPaths: [String]) -> String {
        guard !path.isEmpty else { return "" }
        let current=StorageRemovalPolicy.canonical(path)
        return selectedPaths.contains { selected in
            let selected=StorageRemovalPolicy.canonical(selected)
            return current == selected || current.hasPrefix(selected + "/")
        } ? path : ""
    }

    public static func singleLinePath(_ path: String) -> String {
        String(path.map { $0.isNewline || $0 == "\t" ? Character(" ") : $0 })
            .replacingOccurrences(of: "\\", with: "/")
    }

    /// Shorten only the middle so the path origin and current item remain recognizable.
    /// Callers retain the original path for help and inspection.
    public static func shortPath(_ path: String) -> String {
        let normalized=singleLinePath(path)
        guard normalized.count > 64 else { return normalized }
        return String(normalized.prefix(24)) + "…" + String(normalized.suffix(39))
    }
}
