import AppKit
import SwiftUI
import Testing
@testable import Wontun

@MainActor struct BoundedSidebarTests {
    @Test func swiftUISidebarResizesWithinNativeBounds() async throws {
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
        #expect(sidebar.minimumThickness == 180)
        #expect(sidebar.maximumThickness == 360)
        #expect(!controller.splitView(split, canCollapseSubview: sidebar.viewController.view))
        let divider = NSRect(x: 220, y: 0, width: split.dividerThickness, height: split.bounds.height)
        #expect(!controller.splitView(split, effectiveRect: divider.insetBy(dx: -5, dy: 0),
                                     forDrawnRect: divider, ofDividerAt: 0).isEmpty)
        controller.toggleSidebar(nil)
        #expect(!sidebar.isCollapsed)

        // Re-render the real sidebar, then try moving its divider in both directions.
        model.section = .settings
        window.contentView?.layoutSubtreeIfNeeded()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        // Native sidebar chrome can add an inset between divider position and content width.
        for (position, expectedWidths): (CGFloat, ClosedRange<CGFloat>) in [
            (300, 181...359), (500, 360...360), (0, 180...180), (280, 181...359)
        ] {
            split.setPosition(position, ofDividerAt: 0)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(expectedWidths.contains(sidebar.viewController.view.frame.width))
            #expect(!sidebar.isCollapsed)
        }

        let resizedWidth = sidebar.viewController.view.frame.width
        model.section = .logs
        window.contentView?.layoutSubtreeIfNeeded()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(sidebar.viewController.view.frame.width - resizedWidth) < 1)
        #expect(sidebar.minimumThickness == 180)
        #expect(sidebar.maximumThickness == 360)

        window.setContentSize(NSSize(width: 950, height: 650))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(sidebar.viewController.view.frame.width >= 180)
        #expect(sidebar.viewController.view.frame.width <= 360)
        #expect(!sidebar.isCollapsed)
    }

    @Test func boundedSidebarStaysExpandedAndKeepsWidthLimits() {
        let sidebar = NSSplitViewItem(sidebarWithViewController: NSViewController())
        sidebar.constrainSidebar(minWidth: 180, maxWidth: 360)

        #expect(!sidebar.canCollapse)
        #expect(!sidebar.canCollapseFromWindowResize)
        #expect(!sidebar.isCollapsed)
        #expect(sidebar.minimumThickness == 180)
        #expect(sidebar.maximumThickness == 360)

        // A subsequent SwiftUI setter must not re-enable divider collapsing.
        sidebar.canCollapse = true
        sidebar.canCollapseFromWindowResize = true
        sidebar.minimumThickness = 140
        sidebar.maximumThickness = 500
        #expect(!sidebar.canCollapse)
        #expect(!sidebar.canCollapseFromWindowResize)
        #expect(sidebar.minimumThickness == 180)
        #expect(sidebar.maximumThickness == 360)
    }

    @Test func otherSplitViewItemsKeepTheirCollapseBehavior() {
        let bounded = NSSplitViewItem(sidebarWithViewController: NSViewController())
        bounded.constrainSidebar(minWidth: 180, maxWidth: 360)
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
