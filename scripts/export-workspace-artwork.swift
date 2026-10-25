import AppKit
import SwiftUI

@main
struct ExportWorkspaceArtwork {
    @MainActor static func main() throws {
        let directory=URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let scenes: [(String, WorkspaceArtworkKind)]=[
            ("applications", .applications), ("projects", .projects), ("space", .space),
            ("large-files", .largeFiles), ("privacy", .privacy), ("startup", .startup),
            ("rules", .rules), ("history", .history), ("settings", .settings)
        ]
        try save(WorkspaceIllustration().frame(width: 440, height: 330), to: directory.appendingPathComponent("cleanup.png"))
        for (name, kind) in scenes {
            try save(WorkspacePageArtwork(kind: kind).frame(width: 360, height: 280), to: directory.appendingPathComponent(name + ".png"))
        }
    }

    @MainActor private static func save(_ view: some View, to url: URL) throws {
        let renderer=ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale=3
        guard let image=renderer.nsImage, let tiff=image.tiffRepresentation,
              let bitmap=NSBitmapImageRep(data: tiff), let png=bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }
}
