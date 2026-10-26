import AppKit

/// Load our artwork directly; Launch Services may still have an older icon cached.
@MainActor enum AppIdentity {
    private static var icons: [String: NSImage]=[:]
    private static var missing=Set<String>()
    private static var artwork: [String: NSImage]=[:]
    static let icon: NSImage = {
        if let url=Bundle.main.url(forResource: "Shou", withExtension: "icns"), let image=NSImage(contentsOf: url) { return image }
        return NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: nil) ?? NSImage()
    }()

    static let mascot: NSImage = {
        if let url=Bundle.main.url(forResource: "ShouMascot", withExtension: "png"), let image=NSImage(contentsOf: url) { return image }
        return icon
    }()

    static func workspaceArtwork(_ name: String) -> NSImage {
        if let image=artwork[name] { return image }
        guard let url=Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Illustrations"),
              let image=NSImage(contentsOf: url) else { return mascot }
        artwork[name]=image
        return image
    }

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
