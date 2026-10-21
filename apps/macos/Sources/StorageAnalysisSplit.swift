import AppKit
import SwiftUI

/// Start with useful space for both tables and map; keep the native draggable divider.
struct StorageAnalysisSplit<Upper: View, Lower: View>: NSViewControllerRepresentable {
    @ViewBuilder var upper: Upper
    @ViewBuilder var lower: Lower
    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller=StorageAnalysisSplitController()
        controller.splitView.isVertical=false
        controller.splitView.dividerStyle = .thin
        let top=NSSplitViewItem(viewController: NSHostingController(rootView: upper))
        top.minimumThickness=160
        let bottom=NSSplitViewItem(viewController: NSHostingController(rootView: lower))
        bottom.minimumThickness=160
        controller.addSplitViewItem(top); controller.addSplitViewItem(bottom)
        return controller
    }
    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {
        (controller.splitViewItems[0].viewController as? NSHostingController<Upper>)?.rootView=upper
        (controller.splitViewItems[1].viewController as? NSHostingController<Lower>)?.rootView=lower
    }
}

private final class StorageAnalysisSplitController: NSSplitViewController {
    private var appliedInitialLayout=false

    override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialLayout()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyInitialLayout()
    }

    private func applyInitialLayout() {
        guard !appliedInitialLayout, view.window != nil, splitViewItems.count == 2 else { return }
        let available=splitView.bounds.height - splitView.dividerThickness
        guard available >= splitViewItems.reduce(0, { $0 + $1.minimumThickness }) else { return }
        // Preferred fractions alone can leave the map at its minimum thickness.
        // Apply once after attachment so later user adjustments remain untouched.
        appliedInitialLayout=true
        splitView.setPosition(available * 0.60, ofDividerAt: 0)
    }
}
