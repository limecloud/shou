import Foundation

enum CoreResources {
    static let bundle: Bundle = {
        // App bundles use Contents/Resources; standalone executables keep the
        // same resource bundle beside the binary. SwiftPM is the source fallback.
        let packaged=Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("Shou_ShouCore.bundle"))
        }
        return packaged ?? Bundle.module
    }()
}
