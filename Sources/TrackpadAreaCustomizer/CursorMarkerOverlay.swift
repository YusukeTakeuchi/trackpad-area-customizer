import AppKit
import Foundation

private final class CursorMarkerView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let markerRect = bounds.insetBy(dx: 1, dy: 1)
        let markerPath = NSBezierPath(ovalIn: markerRect)
        NSColor.systemRed.setFill()
        markerPath.fill()

        NSColor.white.setStroke()
        markerPath.lineWidth = 1
        markerPath.stroke()
    }
}

final class CursorMarkerOverlay {
    private let markerSize = NSSize(width: 14, height: 14)
    private let markerOffset = NSPoint(x: 18, y: -18)
    private let window: NSWindow
    private var isVisible = false

    init() {
        let frame = NSRect(origin: .zero, size: markerSize)
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.contentView = CursorMarkerView(frame: frame)
        window.orderOut(nil)
        self.window = window
    }

    func update(isVisible: Bool) {
        guard isVisible else {
            hide()
            return
        }

        moveNearCursor()
        if !self.isVisible {
            window.orderFrontRegardless()
            self.isVisible = true
        }
    }

    func hide() {
        guard isVisible else {
            return
        }
        window.orderOut(nil)
        isVisible = false
    }

    private func moveNearCursor() {
        let cursorLocation = NSEvent.mouseLocation
        var origin = NSPoint(
            x: cursorLocation.x + markerOffset.x - (markerSize.width / 2),
            y: cursorLocation.y + markerOffset.y - (markerSize.height / 2)
        )

        if let screen = NSScreen.screens.first(where: { NSMouseInRect(cursorLocation, $0.frame, false) }) {
            origin = clampedOrigin(origin, inside: screen.visibleFrame)
        }

        window.setFrameOrigin(origin)
    }

    private func clampedOrigin(_ origin: NSPoint, inside frame: NSRect) -> NSPoint {
        let maxX = frame.maxX - markerSize.width
        let maxY = frame.maxY - markerSize.height
        return NSPoint(
            x: min(max(origin.x, frame.minX), maxX),
            y: min(max(origin.y, frame.minY), maxY)
        )
    }
}
