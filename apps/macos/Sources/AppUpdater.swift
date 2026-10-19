import Combine
import Sparkle

@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates=false
    @Published var automaticChecks=false {
        didSet { controller.updater.automaticallyChecksForUpdates=automaticChecks }
    }
    var operationInProgress=false {
        didSet {
            if !operationInProgress, let resume=pendingInstallation {
                pendingInstallation=nil
                resume()
            }
        }
    }
    private var pendingInstallation: (() -> Void)?
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        // Source executables have no updateable application bundle.
        controller=SPUStandardUpdaterController(startingUpdater: Bundle.main.bundleURL.pathExtension == "app", updaterDelegate: self, userDriverDelegate: nil)
        automaticChecks=controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard operationInProgress else { return false }
        pendingInstallation=installHandler
        return true
    }
}
