import Combine
import Sparkle

@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates=false
    @Published var automaticChecks=false {
        didSet { if controller.updater.automaticallyChecksForUpdates != automaticChecks { controller.updater.automaticallyChecksForUpdates=automaticChecks } }
    }
    @Published var automaticDownloads=false {
        didSet { if controller.updater.automaticallyDownloadsUpdates != automaticDownloads { controller.updater.automaticallyDownloadsUpdates=automaticDownloads } }
    }
    @Published private(set) var allowsAutomaticUpdates=false
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var status="Updates are verified before installation."
    private var observations=Set<AnyCancellable>()
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
        automaticDownloads=controller.updater.automaticallyDownloadsUpdates
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.allowsAutomaticUpdates).assign(to: &$allowsAutomaticUpdates)
        controller.updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastCheckDate)
        // Sparkle's dialog can also change these options; settings must reflect it.
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).removeDuplicates().sink { [weak self] value in
            if self?.automaticChecks != value { self?.automaticChecks=value }
        }.store(in: &observations)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).removeDuplicates().sink { [weak self] value in
            if self?.automaticDownloads != value { self?.automaticDownloads=value }
        }.store(in: &observations)
    }

    func checkForUpdates() {
        guard canCheckForUpdates, !operationInProgress else { return }
        status="Checking for updates…"
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status="A new version of Shou is available."
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        // An incompatible release is different from being on the latest version.
        let reason=(error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        status=(reason?.int32Value ?? -1) == SPUNoUpdateFoundReason.onLatestVersion.rawValue
            ? "You’re up to date." : "No compatible update is available."
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if (error as NSError).code != SUError.noUpdateError.rawValue {
            status="Could not check for updates. Check your connection and try again."
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard operationInProgress else { return false }
        pendingInstallation=installHandler
        return true
    }
}
