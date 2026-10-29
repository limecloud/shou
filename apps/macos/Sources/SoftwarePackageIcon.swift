import AppKit
import ShouCore
import SwiftUI

/// Icons are presentation only; neither an artifact path nor a logo proves package ownership.
struct SoftwarePackageIcon: View {
    let item: PackageUpdateItem
    @State private var applicationIcon: NSImage?
    private static let cache=NSCache<NSString, NSImage>()
    private static let tokens: [String:String] = {
        guard let url=Bundle.main.resourceURL?.appendingPathComponent("SoftwareIcons/catalog.json"),
              let data=try? Data(contentsOf: url), let object=try? JSONSerialization.jsonObject(with: data) as? [String:Any] else { return [:] }
        return object["tokens"] as? [String:String] ?? [:]
    }()
    private var logo: NSImage? {
        let token=String(item.token.split(separator: "/").last ?? "").split(separator: "@").first.map(String.init) ?? item.token
        guard let name=Self.tokens[token], let url=Bundle.main.resourceURL?.appendingPathComponent("SoftwareIcons/" + name + ".png") else { return nil }
        if let cached=Self.cache.object(forKey: url.path as NSString) { return cached }
        guard let image=NSImage(contentsOf: url) else { return nil }
        Self.cache.setObject(image, forKey: url.path as NSString); return image
    }
    var body: some View {
        Group {
            if let applicationIcon { Image(nsImage: applicationIcon).resizable().scaledToFit() }
            else if let logo { Image(nsImage: logo).renderingMode(.template).resizable().scaledToFit().foregroundStyle(ShouPalette.accent).padding(4) }
            else {
                Image(systemName: item.kind == "dependency" ? "puzzlepiece.extension.fill" : item.kind == "cask" ? "app.fill" : "terminal.fill")
                    .font(.system(size: 22)).foregroundStyle(ShouPalette.secondary)
            }
        }.frame(width: 32, height: 32).accessibilityHidden(true)
            .task(id: item.iconApplicationPaths) {
                applicationIcon=nil
                let roots=["/Applications/", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"]
                for path in item.iconApplicationPaths ?? [] where roots.contains(where: path.hasPrefix) {
                    guard !Task.isCancelled else { return }
                    guard FileManager.default.fileExists(atPath: path) else { continue }
                    if let cached=Self.cache.object(forKey: path as NSString) { applicationIcon=cached; return }
                    let image=NSWorkspace.shared.icon(forFile: path)
                    Self.cache.setObject(image, forKey: path as NSString); applicationIcon=image; return
                }
            }
    }
}
