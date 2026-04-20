import Foundation
import CoreGraphics
import Carbon.HIToolbox

/// Synthesizes keyboard events system-wide via CoreGraphics. Requires Accessibility permission.
///
/// ### Why we emit explicit modifier key events
///
/// The obvious implementation — build a single `CGEvent` for the target key and
/// set `event.flags = .maskControl` — works fine for app-level shortcuts that
/// inspect `NSEvent.modifierFlags` when handling keyDown. It does **not** work
/// for system hotkeys registered with `RegisterEventHotKey` / WindowServer, such
/// as Mission Control (`⌃↑`), Application Windows (`⌃↓`), Spaces switching
/// (`⌃←/→`), and Spotlight. Those handlers only fire when WindowServer has
/// observed a proper modifier-key state transition (a keyDown with virtual
/// keycode `kVK_Control` *first*), not just a flag bit riding on the arrow key.
///
/// So for each modifier in the binding we synthesize its physical keyDown
/// before the target key, and its keyUp after the target key releases. The
/// CGEvent `flags` field on each event reflects the accumulating modifier state
/// as it would on a real keyboard — e.g. pressing `⌃⌘↑` emits:
///
///   1. keyDown(Control)  flags = ⌃
///   2. keyDown(Command)  flags = ⌃⌘
///   3. keyDown(UpArrow)  flags = ⌃⌘
///   …release in reverse order with flags decreasing.
///
/// Fn is a special case: there's no virtual keycode that reliably produces a
/// modifier state transition for Fn on modern Macs (it's a firmware-level flag
/// on Apple keyboards), so we still attach `.maskSecondaryFn` to the target key
/// event only — that's what CGEvent callers are documented to do for Fn, and
/// it's enough for most Fn-based shortcuts.
final class KeyboardInjector {
    private let source: CGEventSource?

    /// Modifier key virtual codes + their CGEventFlags bit, in the order we press
    /// them. Order matches what `Command + Shift + …` would look like if typed
    /// outward from the space bar, which is close enough to typical user behavior
    /// that no app should flinch at the sequence.
    private static let modifierKeys: [(modifier: KeyModifiers, code: CGKeyCode, flag: CGEventFlags)] = [
        (.command, CGKeyCode(kVK_Command),    .maskCommand),
        (.shift,   CGKeyCode(kVK_Shift),      .maskShift),
        (.option,  CGKeyCode(kVK_Option),     .maskAlternate),
        (.control, CGKeyCode(kVK_Control),    .maskControl)
    ]

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
        // Press each physical modifier first so WindowServer sees proper state
        // transitions — required by system hotkeys like Mission Control.
        var running: CGEventFlags = []
        for entry in Self.modifierKeys where modifiers.contains(entry.modifier) {
            running.insert(entry.flag)
            post(virtualKey: entry.code, keyDown: true, flags: running)
        }
        // Fn has no physical-key state change we can synthesize reliably; it
        // piggy-backs as a flag on the target key event only.
        let targetFlags = modifiers.contains(.fn) ? running.union(.maskSecondaryFn) : running
        post(virtualKey: key.carbonKeyCode, keyDown: true, flags: targetFlags)
    }

    func keyUp(key: KeyCode, modifiers: KeyModifiers) {
        // Release the target key first (while modifiers are still "held"), then
        // release modifiers in reverse press order so the flag state ramps back
        // down the way a human's fingers would lift off the keyboard.
        var running: CGEventFlags = modifiers.cgFlags
        post(virtualKey: key.carbonKeyCode, keyDown: false, flags: running)

        for entry in Self.modifierKeys.reversed() where modifiers.contains(entry.modifier) {
            running.remove(entry.flag)
            post(virtualKey: entry.code, keyDown: false, flags: running)
        }
    }

    private func post(virtualKey: CGKeyCode, keyDown: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
