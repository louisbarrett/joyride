import Foundation
import Carbon.HIToolbox
import CoreGraphics

/// A catalog of virtual keycodes we support for key bindings. We use the stable `kVK_*`
/// constants from Carbon.HIToolbox rather than a private table so names and codes stay
/// correct across macOS versions.
enum KeyCode: String, Codable, CaseIterable, Identifiable, Hashable {
    // Letters
    case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z

    // Digits
    case digit0 = "0", digit1 = "1", digit2 = "2", digit3 = "3", digit4 = "4"
    case digit5 = "5", digit6 = "6", digit7 = "7", digit8 = "8", digit9 = "9"

    // Arrows + navigation
    case left, right, up, down
    case pageUp = "page_up", pageDown = "page_down"
    case home, end

    // Common action keys
    case space, tab, returnKey = "return", escape, delete, forwardDelete = "forward_delete"

    // Function keys
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    // Media / misc
    case minusKey = "minus", equalKey = "equal"
    case leftBracket = "left_bracket", rightBracket = "right_bracket"
    case semicolon, quote, comma, period, slash, backslash, grave

    var id: String { rawValue }

    var carbonKeyCode: CGKeyCode {
        switch self {
        case .a: return CGKeyCode(kVK_ANSI_A)
        case .b: return CGKeyCode(kVK_ANSI_B)
        case .c: return CGKeyCode(kVK_ANSI_C)
        case .d: return CGKeyCode(kVK_ANSI_D)
        case .e: return CGKeyCode(kVK_ANSI_E)
        case .f: return CGKeyCode(kVK_ANSI_F)
        case .g: return CGKeyCode(kVK_ANSI_G)
        case .h: return CGKeyCode(kVK_ANSI_H)
        case .i: return CGKeyCode(kVK_ANSI_I)
        case .j: return CGKeyCode(kVK_ANSI_J)
        case .k: return CGKeyCode(kVK_ANSI_K)
        case .l: return CGKeyCode(kVK_ANSI_L)
        case .m: return CGKeyCode(kVK_ANSI_M)
        case .n: return CGKeyCode(kVK_ANSI_N)
        case .o: return CGKeyCode(kVK_ANSI_O)
        case .p: return CGKeyCode(kVK_ANSI_P)
        case .q: return CGKeyCode(kVK_ANSI_Q)
        case .r: return CGKeyCode(kVK_ANSI_R)
        case .s: return CGKeyCode(kVK_ANSI_S)
        case .t: return CGKeyCode(kVK_ANSI_T)
        case .u: return CGKeyCode(kVK_ANSI_U)
        case .v: return CGKeyCode(kVK_ANSI_V)
        case .w: return CGKeyCode(kVK_ANSI_W)
        case .x: return CGKeyCode(kVK_ANSI_X)
        case .y: return CGKeyCode(kVK_ANSI_Y)
        case .z: return CGKeyCode(kVK_ANSI_Z)
        case .digit0: return CGKeyCode(kVK_ANSI_0)
        case .digit1: return CGKeyCode(kVK_ANSI_1)
        case .digit2: return CGKeyCode(kVK_ANSI_2)
        case .digit3: return CGKeyCode(kVK_ANSI_3)
        case .digit4: return CGKeyCode(kVK_ANSI_4)
        case .digit5: return CGKeyCode(kVK_ANSI_5)
        case .digit6: return CGKeyCode(kVK_ANSI_6)
        case .digit7: return CGKeyCode(kVK_ANSI_7)
        case .digit8: return CGKeyCode(kVK_ANSI_8)
        case .digit9: return CGKeyCode(kVK_ANSI_9)
        case .left: return CGKeyCode(kVK_LeftArrow)
        case .right: return CGKeyCode(kVK_RightArrow)
        case .up: return CGKeyCode(kVK_UpArrow)
        case .down: return CGKeyCode(kVK_DownArrow)
        case .pageUp: return CGKeyCode(kVK_PageUp)
        case .pageDown: return CGKeyCode(kVK_PageDown)
        case .home: return CGKeyCode(kVK_Home)
        case .end: return CGKeyCode(kVK_End)
        case .space: return CGKeyCode(kVK_Space)
        case .tab: return CGKeyCode(kVK_Tab)
        case .returnKey: return CGKeyCode(kVK_Return)
        case .escape: return CGKeyCode(kVK_Escape)
        case .delete: return CGKeyCode(kVK_Delete)
        case .forwardDelete: return CGKeyCode(kVK_ForwardDelete)
        case .f1: return CGKeyCode(kVK_F1)
        case .f2: return CGKeyCode(kVK_F2)
        case .f3: return CGKeyCode(kVK_F3)
        case .f4: return CGKeyCode(kVK_F4)
        case .f5: return CGKeyCode(kVK_F5)
        case .f6: return CGKeyCode(kVK_F6)
        case .f7: return CGKeyCode(kVK_F7)
        case .f8: return CGKeyCode(kVK_F8)
        case .f9: return CGKeyCode(kVK_F9)
        case .f10: return CGKeyCode(kVK_F10)
        case .f11: return CGKeyCode(kVK_F11)
        case .f12: return CGKeyCode(kVK_F12)
        case .minusKey: return CGKeyCode(kVK_ANSI_Minus)
        case .equalKey: return CGKeyCode(kVK_ANSI_Equal)
        case .leftBracket: return CGKeyCode(kVK_ANSI_LeftBracket)
        case .rightBracket: return CGKeyCode(kVK_ANSI_RightBracket)
        case .semicolon: return CGKeyCode(kVK_ANSI_Semicolon)
        case .quote: return CGKeyCode(kVK_ANSI_Quote)
        case .comma: return CGKeyCode(kVK_ANSI_Comma)
        case .period: return CGKeyCode(kVK_ANSI_Period)
        case .slash: return CGKeyCode(kVK_ANSI_Slash)
        case .backslash: return CGKeyCode(kVK_ANSI_Backslash)
        case .grave: return CGKeyCode(kVK_ANSI_Grave)
        }
    }

    var displayName: String {
        switch self {
        case .returnKey: return "Return"
        case .space: return "Space"
        case .escape: return "Esc"
        case .delete: return "Delete"
        case .forwardDelete: return "Fwd Delete"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .leftBracket: return "["
        case .rightBracket: return "]"
        case .minusKey: return "-"
        case .equalKey: return "="
        case .semicolon: return ";"
        case .quote: return "'"
        case .comma: return ","
        case .period: return "."
        case .slash: return "/"
        case .backslash: return "\\"
        case .grave: return "`"
        default: return rawValue.uppercased()
        }
    }

    /// Flag bits macOS considers *intrinsic* to the key, independent of which
    /// modifiers the user is holding. Real hardware events for these keys
    /// always carry these bits set; CGEvent's keyboard constructor does not
    /// populate them automatically, so we OR them in at post time.
    ///
    /// Why this matters: macOS's symbolic-hotkey dispatcher (the one that
    /// owns Mission Control `⌃↑`, Application Windows `⌃↓`, Move-to-Space
    /// `⌃←/→`, etc.) matches on keycode **plus** modifier mask **plus** these
    /// bits. A synthesized `⌃↑` without `.maskNumericPad | .maskSecondaryFn`
    /// looks to the dispatcher like an unknown keycode with Control held,
    /// and silently falls through. Adding the bits makes the event
    /// bit-identical to what a physical arrow press produces.
    ///
    ///   - Arrow keys: numericPad + function (historical: arrows lived on
    ///     the numeric keypad, and are "function" keys in NSEvent terms).
    ///   - PageUp/Down, Home/End, ForwardDelete: function only.
    ///   - F1–F12: function only.
    ///   - Everything else: no intrinsic flags.
    var characteristicFlags: CGEventFlags {
        switch self {
        case .left, .right, .up, .down:
            return [.maskNumericPad, .maskSecondaryFn]
        case .pageUp, .pageDown, .home, .end, .forwardDelete:
            return [.maskSecondaryFn]
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return [.maskSecondaryFn]
        default:
            return []
        }
    }
}

/// Modifier keys, represented as an OptionSet so bindings can include any combination.
struct KeyModifiers: OptionSet, Codable, Hashable {
    let rawValue: Int

    static let command = KeyModifiers(rawValue: 1 << 0)
    static let shift   = KeyModifiers(rawValue: 1 << 1)
    static let option  = KeyModifiers(rawValue: 1 << 2)
    static let control = KeyModifiers(rawValue: 1 << 3)
    static let fn      = KeyModifiers(rawValue: 1 << 4)

    var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.shift)   { flags.insert(.maskShift) }
        if contains(.option)  { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.fn)      { flags.insert(.maskSecondaryFn) }
        return flags
    }

    var displayFragments: [String] {
        var out: [String] = []
        if contains(.control) { out.append("⌃") }
        if contains(.option)  { out.append("⌥") }
        if contains(.shift)   { out.append("⇧") }
        if contains(.command) { out.append("⌘") }
        if contains(.fn)      { out.append("fn") }
        return out
    }
}
