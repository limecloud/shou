import SwiftUI

/// Shared task identities for the packaged Shou illustration family.
enum WorkspaceArtworkKind: String {
    case cleanup, applications, projects, space, privacy, startup, rules, history, settings
    case largeFiles = "large-files"
}

struct WorkspaceIllustration: View {
    var body: some View { WorkspacePageArtwork(kind: .cleanup) }
}
