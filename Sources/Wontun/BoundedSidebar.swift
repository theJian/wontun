import AppKit
import ObjectiveC
import SwiftUI

/// Keeps the native sidebar expanded while allowing resizing within its width bounds.
struct BoundedSidebar: NSViewRepresentable {
    let minWidth: CGFloat
    let maxWidth: CGFloat

    func makeNSView(context: Context) -> SidebarView { SidebarView() }

    func updateNSView(_ view: SidebarView, context: Context) {
        view.minWidth = minWidth
        view.maxWidth = maxWidth
        view.scheduleConfiguration()
    }

    final class SidebarView: NSView {
        var minWidth: CGFloat = 180
        var maxWidth: CGFloat = 360

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            // SwiftUI must finish attaching the sidebar to its native split view first.
            DispatchQueue.main.async { [weak self] in self?.configureSidebar() }
        }

        private func configureSidebar() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let splitView = view as? NSSplitView,
                   let controller = splitView.delegate as? NSSplitViewController,
                   let item = controller.splitViewItems.first,
                   isDescendant(of: item.viewController.view) {
                    item.constrainSidebar(minWidth: minWidth, maxWidth: maxWidth)
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

@MainActor extension NSSplitViewItem {
    private final class WidthBounds {
        let minimum: CGFloat
        let maximum: CGFloat

        init(minimum: CGFloat, maximum: CGFloat) {
            self.minimum = minimum
            self.maximum = maximum
        }
    }

    private static let boundedSidebars = NSMapTable<NSSplitViewItem, WidthBounds>.weakToStrongObjects()

    private static let installSidebarOverrides: Void = {
        let setters = [
            (#selector(setter: canCollapse), #selector(setBoundedSidebarCanCollapse(_:))),
            (#selector(setter: canCollapseFromWindowResize), #selector(setBoundedSidebarCanCollapseFromWindowResize(_:))),
            (#selector(setter: minimumThickness), #selector(setBoundedSidebarMinimumThickness(_:))),
            (#selector(setter: maximumThickness), #selector(setBoundedSidebarMaximumThickness(_:)))
        ]
        for (originalSelector, replacementSelector) in setters {
            guard let original = class_getInstanceMethod(NSSplitViewItem.self, originalSelector),
                  let replacement = class_getInstanceMethod(NSSplitViewItem.self, replacementSelector)
            else { preconditionFailure("NSSplitViewItem sidebar setter is unavailable") }
            method_exchangeImplementations(original, replacement)
        }
    }()

    func constrainSidebar(minWidth: CGFloat, maxWidth: CGFloat) {
        _ = Self.installSidebarOverrides
        Self.boundedSidebars.setObject(WidthBounds(minimum: minWidth, maximum: maxWidth), forKey: self)
        canCollapse = false
        canCollapseFromWindowResize = false
        minimumThickness = minWidth
        maximumThickness = maxWidth
        isCollapsed = false
    }

    private var sidebarBounds: WidthBounds? {
        Self.boundedSidebars.object(forKey: self)
    }

    // SwiftUI rewrites these properties during updates. Enforce the bounds at the setters
    // so AppKit's stored values, layout constraints, and divider cursor agree.
    @objc private func setBoundedSidebarCanCollapse(_ value: Bool) {
        setBoundedSidebarCanCollapse(sidebarBounds == nil ? value : false)
    }

    @objc private func setBoundedSidebarCanCollapseFromWindowResize(_ value: Bool) {
        setBoundedSidebarCanCollapseFromWindowResize(sidebarBounds == nil ? value : false)
    }

    @objc private func setBoundedSidebarMinimumThickness(_ value: CGFloat) {
        setBoundedSidebarMinimumThickness(sidebarBounds?.minimum ?? value)
    }

    @objc private func setBoundedSidebarMaximumThickness(_ value: CGFloat) {
        setBoundedSidebarMaximumThickness(sidebarBounds?.maximum ?? value)
    }
}
