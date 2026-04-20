import Foundation
import CoreGraphics

/// Direction of a scroll event.
enum ScrollDirection: String, Codable, CaseIterable, Hashable {
    case up, down, left, right

    var displayName: String {
        switch self {
        case .up: return "Scroll Up"
        case .down: return "Scroll Down"
        case .left: return "Scroll Left"
        case .right: return "Scroll Right"
        }
    }
}

/// Synthesizes mouse scroll wheel events — the headline feature Lovejoy adds over JoyMapper.
///
/// We use `CGEvent(scrollWheelEvent2Source:...)` with `.pixel` units for smooth, per-pixel scroll
/// that matches trackpad behavior (momentum-free, but pixel-precise). For discrete line-based scroll
/// pass `.line` units via `scrollLines`.
final class ScrollInjector {
    private let source: CGEventSource?

    /// Default pixels-per-tick when a button is held and `tick()` is called on a timer.
    var pixelsPerTick: Int32 = 12

    init() {
        self.source = CGEventSource(stateID: .hidSystemState)
    }

    /// Emit a single pixel-based scroll event of the given direction and magnitude.
    func scrollPixels(direction: ScrollDirection, magnitude: Int32) {
        let m = max(0, magnitude)
        var wheel1: Int32 = 0
        var wheel2: Int32 = 0
        switch direction {
        case .up: wheel1 = m
        case .down: wheel1 = -m
        case .right: wheel2 = m
        case .left: wheel2 = -m
        }
        postEvent(units: .pixel, wheel1: wheel1, wheel2: wheel2)
    }

    /// Emit a line-based scroll event (equivalent to a physical notch of a wheel).
    func scrollLines(direction: ScrollDirection, lines: Int32) {
        let m = max(0, lines)
        var wheel1: Int32 = 0
        var wheel2: Int32 = 0
        switch direction {
        case .up: wheel1 = m
        case .down: wheel1 = -m
        case .right: wheel2 = m
        case .left: wheel2 = -m
        }
        postEvent(units: .line, wheel1: wheel1, wheel2: wheel2)
    }

    /// Convenience: scroll by the configured `pixelsPerTick` in the given direction. Used by
    /// the `MappingEngine`'s repeat timer for continuous scrolling while a button is held.
    func tick(direction: ScrollDirection) {
        scrollPixels(direction: direction, magnitude: pixelsPerTick)
    }

    private func postEvent(units: CGScrollEventUnit, wheel1: Int32, wheel2: Int32) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: units,
            wheelCount: 2,
            wheel1: wheel1,
            wheel2: wheel2,
            wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }
}
