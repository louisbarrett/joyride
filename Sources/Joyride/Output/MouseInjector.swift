import Foundation
import CoreGraphics
import AppKit

/// Mouse button identifiers for click events.
enum MouseButton: String, Codable, CaseIterable, Hashable {
    case left, right, middle

    var displayName: String {
        switch self {
        case .left: return "Left Click"
        case .right: return "Right Click"
        case .middle: return "Middle Click"
        }
    }

    fileprivate var downEventType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    fileprivate var upEventType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }

    fileprivate var draggedEventType: CGEventType {
        switch self {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .middle: return .otherMouseDragged
        }
    }

    fileprivate var cgMouseButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }
}

/// Synthesizes mouse clicks and cursor movement via CoreGraphics. Requires Accessibility permission.
final class MouseInjector {
    private let source: CGEventSource?
    private var heldButtons: Set<MouseButton> = []

    init() {
        self.source = CGEventSource(stateID: .hidSystemState)
    }

    // MARK: - Click

    func click(_ button: MouseButton) {
        mouseDown(button)
        mouseUp(button)
    }

    func mouseDown(_ button: MouseButton) {
        let position = currentCursorPosition()
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: button.downEventType,
            mouseCursorPosition: position,
            mouseButton: button.cgMouseButton
        )
        event?.post(tap: .cghidEventTap)
        heldButtons.insert(button)
    }

    func mouseUp(_ button: MouseButton) {
        let position = currentCursorPosition()
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: button.upEventType,
            mouseCursorPosition: position,
            mouseButton: button.cgMouseButton
        )
        event?.post(tap: .cghidEventTap)
        heldButtons.remove(button)
    }

    // MARK: - Movement

    /// Move the cursor by a delta (in points). Emits a `mouseMoved` event (or a dragged event
    /// if a mouse button is being held for drag behavior).
    func moveCursor(byDX dx: CGFloat, dy: CGFloat) {
        guard dx != 0 || dy != 0 else { return }
        let current = currentCursorPosition()
        let screen = clampToScreen(CGPoint(x: current.x + dx, y: current.y + dy))

        let eventType: CGEventType
        let buttonForDrag: CGMouseButton
        if let held = heldButtons.first {
            eventType = held.draggedEventType
            buttonForDrag = held.cgMouseButton
        } else {
            eventType = .mouseMoved
            buttonForDrag = .left
        }

        let event = CGEvent(
            mouseEventSource: source,
            mouseType: eventType,
            mouseCursorPosition: screen,
            mouseButton: buttonForDrag
        )
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Helpers

    private func currentCursorPosition() -> CGPoint {
        // CGEvent gives us the current mouse location in Quartz coordinates (y-down).
        if let event = CGEvent(source: nil) {
            return event.location
        }
        // Fallback via NSEvent (flip coordinates: NSEvent is y-up from bottom-left of primary display).
        let nsLoc = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first {
            let flipped = CGPoint(x: nsLoc.x, y: screen.frame.height - nsLoc.y)
            return flipped
        }
        return .zero
    }

    private func clampToScreen(_ point: CGPoint) -> CGPoint {
        // Union of all screen frames, converted to CG y-down coordinates.
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return point }

        // Build a quartz-coordinate union bounding box.
        let totalHeight = screens.map { $0.frame.maxY }.max() ?? 0
        var union = CGRect.null
        for screen in screens {
            let f = screen.frame
            let quartzFrame = CGRect(
                x: f.minX,
                y: totalHeight - f.maxY,
                width: f.width,
                height: f.height
            )
            union = union.union(quartzFrame)
        }
        if union.isNull { return point }
        let x = max(union.minX, min(union.maxX - 1, point.x))
        let y = max(union.minY, min(union.maxY - 1, point.y))
        return CGPoint(x: x, y: y)
    }
}
