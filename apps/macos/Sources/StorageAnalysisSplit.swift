import AppKit
import SwiftUI

/// Native split items give the dense table a useful initial share of the window.
/// AppKit retains the user's divider adjustment across visits.
struct StorageAnalysisSplit<Upper: View, Lower: View>: NSViewControllerRepresentable {
    @ViewBuilder var upper: Upper
    @ViewBuilder var lower: Lower
    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller=NSSplitViewController()
        controller.splitView.isVertical=false
        controller.splitView.dividerStyle = .thin
        let top=NSSplitViewItem(viewController: NSHostingController(rootView: upper))
        top.minimumThickness=160; top.preferredThicknessFraction=0.62
        let bottom=NSSplitViewItem(viewController: NSHostingController(rootView: lower))
        bottom.minimumThickness=160; bottom.preferredThicknessFraction=0.38
        controller.addSplitViewItem(top); controller.addSplitViewItem(bottom)
        controller.splitView.autosaveName="ShouStorageAnalysisSplit"
        return controller
    }
    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {
        (controller.splitViewItems[0].viewController as? NSHostingController<Upper>)?.rootView=upper
        (controller.splitViewItems[1].viewController as? NSHostingController<Lower>)?.rootView=lower
    }
}
