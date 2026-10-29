import SwiftUI
import ShouCore

/// Authorization restores access; callers explicitly reload and review scope.
struct AccessRecoveryControls: View {
    @Bindable var model: AppModel
    let requirement: SystemAccessRequirement
    var reload: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            switch requirement {
            case .administrator:
                Button(model.t("Authorize…")) { model.scanAccess.authorizeAdministrator(then: reload) }
                    .disabled(model.busy || model.scanAccess.authorizingAdministrator)
            case .fullDiskAccess:
                Button(model.t("Review Disk Access…")) { model.scanAccess.showingSetup=true }
                    .disabled(model.busy)
            }
            if model.scanAccess.authorizingAdministrator { ProgressView().controlSize(.small) }
        }.font(ShouType.caption)
    }
}
