import AppKit

enum TrayIcon {
    // A template lets macOS choose the ink color for each menu bar appearance.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let curl = NSBezierPath()
            curl.move(to: NSPoint(x: 5.7, y: 5.2))
            curl.curve(to: NSPoint(x: 6.4, y: 7.1),
                       controlPoint1: NSPoint(x: 7.3, y: 4.9),
                       controlPoint2: NSPoint(x: 7.7, y: 6.8))
            curl.curve(to: NSPoint(x: 3.1, y: 5.5),
                       controlPoint1: NSPoint(x: 5, y: 7.5),
                       controlPoint2: NSPoint(x: 3.1, y: 7.2))
            curl.curve(to: NSPoint(x: 6.2, y: 2.1),
                       controlPoint1: NSPoint(x: 3.1, y: 3.6),
                       controlPoint2: NSPoint(x: 4.4, y: 2.1))
            curl.curve(to: NSPoint(x: 9.4, y: 5.4),
                       controlPoint1: NSPoint(x: 8.2, y: 2.1),
                       controlPoint2: NSPoint(x: 9.7, y: 3.5))
            curl.curve(to: NSPoint(x: 9.4, y: 9),
                       controlPoint1: NSPoint(x: 9.2, y: 6.9),
                       controlPoint2: NSPoint(x: 8.4, y: 7.9))
            curl.curve(to: NSPoint(x: 12.1, y: 12.4),
                       controlPoint1: NSPoint(x: 10.4, y: 10.1),
                       controlPoint2: NSPoint(x: 11.7, y: 10.7))
            curl.curve(to: NSPoint(x: 15.4, y: 15),
                       controlPoint1: NSPoint(x: 12.5, y: 14.1),
                       controlPoint2: NSPoint(x: 13.1, y: 16))
            curl.lineWidth = 1.55
            curl.lineCapStyle = .round
            curl.lineJoinStyle = .round
            NSColor.black.setStroke()
            curl.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Wontun"
        return image
    }()
}
