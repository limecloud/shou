import SwiftUI

/// Decorative artwork shares the same canonical PNG bytes with Windows.
struct WorkspacePageArtwork: View {
    let kind: WorkspaceArtworkKind
    var body: some View {
        Image(nsImage: AppIdentity.workspaceArtwork(kind.rawValue))
            .resizable().interpolation(.high).scaledToFit()
            .accessibilityHidden(true).allowsHitTesting(false)
    }
}
