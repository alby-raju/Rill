import AppKit
import SwiftUI

/// Fixed native hosting boundaries keep tab-specific intrinsic sizes out of divider layout.
struct RequestSplitView<Leading: View, Trailing: View>: NSViewControllerRepresentable {
    let vertical: Bool
    let leadingMinimum: CGFloat
    let trailingMinimum: CGFloat
    let leading: Leading
    let trailing: Trailing

    func makeNSViewController(context: Context) -> Controller {
        Controller(vertical: vertical, leading: leading, trailing: trailing)
    }
    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.leadingHost.rootView = leading
        controller.trailingHost.rootView = trailing
        controller.splitViewItems[0].minimumThickness = leadingMinimum
        controller.splitViewItems[1].minimumThickness = trailingMinimum
    }
    final class Controller: NSSplitViewController {
        let leadingHost: NSHostingView<Leading>
        let trailingHost: NSHostingView<Trailing>
        init(vertical: Bool, leading: Leading, trailing: Trailing) {
            leadingHost = NSHostingView(rootView: leading)
            trailingHost = NSHostingView(rootView: trailing)
            super.init(nibName: nil, bundle: nil)
            splitView.isVertical = vertical
            splitView.dividerStyle = .thin
            // SwiftUI's default hosting sizing options publish new minimum/intrinsic sizes
            // when tabs change. Disable those at the entire native pane boundary.
            leadingHost.sizingOptions = []
            trailingHost.sizingOptions = []
            for host in [leadingHost as NSView, trailingHost as NSView] {
                let child = NSViewController()
                child.view = host
                addSplitViewItem(NSSplitViewItem(viewController: child))
            }
            if !RillPreview.isRendering {
                splitView.autosaveName = NSSplitView.AutosaveName(
                    vertical ? "rill.request.horizontal" : "rill.request.vertical")
            }
        }
        required init?(coder: NSCoder) { nil }
    }
}
