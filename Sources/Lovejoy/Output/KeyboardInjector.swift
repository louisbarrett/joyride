import Foundation
import CoreGraphics

/// Synthesizes keyboard events system-wide via CoreGraphics. Requires Accessibility permission.
final class KeyboardInjector {
    private let source: CGEventSource?

    init() {
        // `.hidSystemState` yields the most compatible events across apps.
        self.source = CGEventSource(stateID: .hidSystemState)
    }

    /// Press and release the key with modifiers.
    func tap(key: KeyCode, modifiers: KeyModifiers) {
        keyDown(key: key, modifiers: modifiers)
        keyUp(key: key, modifiers: modifiers)
    }

    func keyDown(key: KeyCode, modifiers: KeyModifiers) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key.carbonKeyCode, keyDown: true) else { return }
        event.flags = modifiers.cgFlags
        event.post(tap: .cghidEventTap)
    }

    func keyUp(key: KeyCode, modifiers: KeyModifiers) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key.carbonKeyCode, keyDown: false) else { return }
        event.flags = modifiers.cgFlags
        event.post(tap: .cghidEventTap)
    }
}
