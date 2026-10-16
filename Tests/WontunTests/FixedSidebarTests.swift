import AppKit
import SwiftUI
import Testing
@testable import Wontun

@MainActor struct FixedSidebarTests {
    @Test func swiftUISidebarAttachesToLockedNativeItem() async throws {
        _ = NSApplication.shared
        let model = AppModel()
        let host = NSHostingController(rootView: ContentView(model: model))
        let window = NSWindow(contentViewController: host)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 1120, height: 740))
        window.contentView?.layoutSubtreeIfNeeded()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        window.contentView?.layoutSubtreeIfNeeded()

        func findSplitView(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            return view.subviews.lazy.compactMap { findSplitView(in: $0) }.first
        }
        let split = try #require(findSplitView(in: host.view))
        let controller = try #require(split.delegate as? NSSplitViewController)
        let sidebar = try #require(controller.splitViewItems.first)
        #expect(!sidebar.canCollapse)
        #expect(!sidebar.canCollapseFromWindowResize)
        #expect(sidebar.minimumThickness == 220)
        #expect(sidebar.maximumThickness == 220)
        #expect(!controller.splitView(split, canCollapseSubview: sidebar.viewController.view))
        let divider = NSRect(x: 220, y: 0, width: split.dividerThickness, height: split.bounds.height)
        #expect(controller.splitView(split, effectiveRect: divider.insetBy(dx: -5, dy: 0),
                                     forDrawnRect: divider, ofDividerAt: 0).isEmpty)
        #expect(controller.splitView(split, additionalEffectiveRectOfDividerAt: 0).isEmpty)
        controller.toggleSidebar(nil)
        #expect(!sidebar.isCollapsed)

        // Re-render the real sidebar, then try moving its divider in both directions.
        model.section = .settings
        window.contentView?.layoutSubtreeIfNeeded()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        for position: CGFloat in [350, 0] {
            split.setPosition(position, ofDividerAt: 0)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(abs(sidebar.viewController.view.frame.width - 220) < 1)
            #expect(!sidebar.isCollapsed)
        }

        window.setContentSize(NSSize(width: 950, height: 650))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(sidebar.viewController.view.frame.width - 220) < 1)
        #expect(!sidebar.isCollapsed)
    }

    @Test func lockedSidebarStaysExpandedAndFixedWidth() {
        let sidebar = NSSplitViewItem(sidebarWithViewController: NSViewController())
        sidebar.lockSidebar(width: 220)

        #expect(!sidebar.canCollapse)
        #expect(!sidebar.canCollapseFromWindowResize)
        #expect(!sidebar.isCollapsed)
        #expect(sidebar.minimumThickness == 220)
        #expect(sidebar.maximumThickness == 220)

        // A subsequent SwiftUI setter must not re-enable divider collapsing.
        sidebar.canCollapse = true
        sidebar.canCollapseFromWindowResize = true
        sidebar.minimumThickness = 140
        sidebar.maximumThickness = 500
        #expect(!sidebar.canCollapse)
        #expect(!sidebar.canCollapseFromWindowResize)
        #expect(sidebar.minimumThickness == 220)
        #expect(sidebar.maximumThickness == 220)
    }

    @Test func otherSplitViewItemsKeepTheirCollapseBehavior() {
        let locked = NSSplitViewItem(sidebarWithViewController: NSViewController())
        locked.lockSidebar(width: 220)
        let other = NSSplitViewItem(sidebarWithViewController: NSViewController())

        other.canCollapse = true
        #expect(other.canCollapse)
        other.canCollapse = false
        #expect(!other.canCollapse)
        other.canCollapseFromWindowResize = true
        other.minimumThickness = 180
        other.maximumThickness = 350
        #expect(other.canCollapseFromWindowResize)
        #expect(other.minimumThickness == 180)
        #expect(other.maximumThickness == 350)
        let controller = NSSplitViewController()
        controller.addSplitViewItem(other)
        controller.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
        let divider = NSRect(x: 220, y: 0, width: 10, height: 600)
        #expect(!controller.splitView(controller.splitView, effectiveRect: divider,
                                      forDrawnRect: divider, ofDividerAt: 0).isEmpty)
    }
}
