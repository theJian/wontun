import AppKit
import ObjectiveC
import SwiftUI

/// Keeps the native split view and titlebar layout while locking only this sidebar.
struct FixedSidebar: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context: Context) -> SidebarView { SidebarView() }

    func updateNSView(_ view: SidebarView, context: Context) {
        view.sidebarWidth = width
        view.scheduleConfiguration()
    }

    final class SidebarView: NSView {
        var sidebarWidth: CGFloat = 220

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
                    item.lockSidebar(width: sidebarWidth)
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

@MainActor extension NSSplitViewItem {
    private static let fixedSidebars = NSMapTable<NSSplitViewItem, NSNumber>.weakToStrongObjects()

    private static let installSidebarOverrides: Void = {
        let setters = [
            (#selector(setter: canCollapse), #selector(setFixedSidebarCanCollapse(_:))),
            (#selector(setter: canCollapseFromWindowResize), #selector(setFixedSidebarCanCollapseFromWindowResize(_:))),
            (#selector(setter: minimumThickness), #selector(setFixedSidebarMinimumThickness(_:))),
            (#selector(setter: maximumThickness), #selector(setFixedSidebarMaximumThickness(_:)))
        ]
        for (originalSelector, replacementSelector) in setters {
            guard let original = class_getInstanceMethod(NSSplitViewItem.self, originalSelector),
                  let replacement = class_getInstanceMethod(NSSplitViewItem.self, replacementSelector)
            else { preconditionFailure("NSSplitViewItem sidebar setter is unavailable") }
            method_exchangeImplementations(original, replacement)
        }
    }()

    func lockSidebar(width: CGFloat) {
        _ = Self.installSidebarOverrides
        NSSplitViewController.disableFixedSidebarDividers()
        Self.fixedSidebars.setObject(NSNumber(value: Double(width)), forKey: self)
        canCollapse = false
        canCollapseFromWindowResize = false
        minimumThickness = width
        maximumThickness = width
        isCollapsed = false
    }

    fileprivate var fixedSidebarWidth: CGFloat? {
        Self.fixedSidebars.object(forKey: self).map { CGFloat($0.doubleValue) }
    }

    // SwiftUI rewrites these properties during updates. Enforce the lock at the setters
    // so AppKit's stored values, layout constraints, and divider cursor agree.
    @objc private func setFixedSidebarCanCollapse(_ value: Bool) {
        setFixedSidebarCanCollapse(fixedSidebarWidth == nil ? value : false)
    }

    @objc private func setFixedSidebarCanCollapseFromWindowResize(_ value: Bool) {
        setFixedSidebarCanCollapseFromWindowResize(fixedSidebarWidth == nil ? value : false)
    }

    @objc private func setFixedSidebarMinimumThickness(_ value: CGFloat) {
        setFixedSidebarMinimumThickness(fixedSidebarWidth ?? value)
    }

    @objc private func setFixedSidebarMaximumThickness(_ value: CGFloat) {
        setFixedSidebarMaximumThickness(fixedSidebarWidth ?? value)
    }
}

@MainActor private extension NSSplitViewController {
    static let installDividerOverrides: Void = {
        let methods = [
            (#selector(splitView(_:effectiveRect:forDrawnRect:ofDividerAt:)),
             #selector(fixedSidebarSplitView(_:effectiveRect:forDrawnRect:ofDividerAt:))),
            (#selector(splitView(_:additionalEffectiveRectOfDividerAt:)),
             #selector(fixedSidebarSplitView(_:additionalEffectiveRectOfDividerAt:)))
        ]
        for (originalSelector, replacementSelector) in methods {
            guard let original = class_getInstanceMethod(NSSplitViewController.self, originalSelector),
                  let replacement = class_getInstanceMethod(NSSplitViewController.self, replacementSelector)
            else { preconditionFailure("NSSplitViewController divider method is unavailable") }
            method_exchangeImplementations(original, replacement)
        }
    }()

    static func disableFixedSidebarDividers() {
        _ = installDividerOverrides
    }

    func hasFixedSidebar(at divider: Int) -> Bool {
        splitViewItems.indices.contains(divider) && splitViewItems[divider].fixedSidebarWidth != nil
    }

    // Empty effective rectangles remove the divider's drag target and resize cursor.
    @objc func fixedSidebarSplitView(_ splitView: NSSplitView, effectiveRect proposed: NSRect,
                                    forDrawnRect drawn: NSRect, ofDividerAt divider: Int) -> NSRect {
        if hasFixedSidebar(at: divider) { return .zero }
        return fixedSidebarSplitView(splitView, effectiveRect: proposed, forDrawnRect: drawn, ofDividerAt: divider)
    }

    @objc func fixedSidebarSplitView(_ splitView: NSSplitView, additionalEffectiveRectOfDividerAt divider: Int) -> NSRect {
        if hasFixedSidebar(at: divider) { return .zero }
        return fixedSidebarSplitView(splitView, additionalEffectiveRectOfDividerAt: divider)
    }
}
