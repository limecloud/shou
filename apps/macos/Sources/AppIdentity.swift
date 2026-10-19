import AppKit

/// Load our artwork directly; Launch Services may still have an older icon cached.
@MainActor enum AppIdentity {
    private static var icons: [String: NSImage]=[:]
    private static var missing=Set<String>()
    static let icon: NSImage = {
        if let url=Bundle.main.url(forResource: "Shou", withExtension: "icns"), let image=NSImage(contentsOf: url) { return image }
        return NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: nil) ?? NSImage()
    }()

    static func applicationIcon(_ identifiers: [String]) -> NSImage? {
        for identifier in identifiers {
            if let cached=icons[identifier] { return cached }
            if missing.contains(identifier) { continue }
            if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                let icon=NSWorkspace.shared.icon(forFile: url.path)
                icons[identifier]=icon; return icon
            }
            missing.insert(identifier)
        }
        return nil
    }
}
