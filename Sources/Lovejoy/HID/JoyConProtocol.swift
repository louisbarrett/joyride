import Foundation

/// Constants and data types derived from the reverse-engineered Joy-Con HID protocol.
/// Reference: https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering
enum JoyConProtocol {
    static let vendorIDNintendo: Int = 0x057E
    static let productIDLeftJoyCon: Int = 0x2006
    static let productIDRightJoyCon: Int = 0x2007
    static let productIDProController: Int = 0x2009
    static let productIDChargingGrip: Int = 0x200E

    /// Neutral (silent) rumble payload required in every output report.
    static let neutralRumble: [UInt8] = [0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40]

    /// Maximum input report length we ever expect from a Joy-Con (standard full report is 49 bytes).
    static let maxInputReportSize: Int = 64

    enum OutputReportID: UInt8 {
        case rumbleAndSubcommand = 0x01
        case rumbleOnly = 0x10
    }

    enum InputReportID: UInt8 {
        case subcommandReply = 0x21
        case standardFull = 0x30
        case simpleHID = 0x3F
    }

    enum Subcommand: UInt8 {
        case setInputReportMode = 0x03
        case setPlayerLights = 0x30
        case enableIMU = 0x40
        case enableVibration = 0x48
    }

    enum InputReportMode: UInt8 {
        case standardFull = 0x30
        case simpleHID = 0x3F
    }
}

/// Identifies a physical Joy-Con form factor.
enum JoyConSide: String, Codable, CaseIterable, Hashable {
    case left
    case right
    case proController
    case unknown

    init(productID: Int) {
        switch productID {
        case JoyConProtocol.productIDLeftJoyCon: self = .left
        case JoyConProtocol.productIDRightJoyCon: self = .right
        case JoyConProtocol.productIDProController: self = .proController
        default: self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .left: return "Left Joy-Con"
        case .right: return "Right Joy-Con"
        case .proController: return "Pro Controller"
        case .unknown: return "Unknown Controller"
        }
    }
}

/// Every button we care about, addressable in a device-agnostic way.
enum JoyConButton: String, Codable, CaseIterable, Identifiable, Hashable {
    // Right Joy-Con face buttons
    case a, b, x, y
    case r, zr, plus, rightStickClick, home

    // Left Joy-Con face buttons
    case dpadUp = "dpad_up"
    case dpadDown = "dpad_down"
    case dpadLeft = "dpad_left"
    case dpadRight = "dpad_right"
    case l, zl, minus, leftStickClick = "left_stick_click", capture

    // Side-rail buttons (usable when Joy-Con is held sideways)
    case slLeft = "sl_left"
    case srLeft = "sr_left"
    case slRight = "sl_right"
    case srRight = "sr_right"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .r: return "R"
        case .zr: return "ZR"
        case .plus: return "+"
        case .rightStickClick: return "Right Stick Click"
        case .home: return "Home"
        case .dpadUp: return "D-Pad Up"
        case .dpadDown: return "D-Pad Down"
        case .dpadLeft: return "D-Pad Left"
        case .dpadRight: return "D-Pad Right"
        case .l: return "L"
        case .zl: return "ZL"
        case .minus: return "-"
        case .leftStickClick: return "Left Stick Click"
        case .capture: return "Capture"
        case .slLeft: return "SL (Left)"
        case .srLeft: return "SR (Left)"
        case .slRight: return "SL (Right)"
        case .srRight: return "SR (Right)"
        }
    }

    /// Buttons available on the given side. Used to filter UI to avoid showing bindings for
    /// buttons that physically don't exist on the connected controller.
    static func buttons(for side: JoyConSide) -> [JoyConButton] {
        switch side {
        case .left:
            return [.dpadUp, .dpadDown, .dpadLeft, .dpadRight,
                    .l, .zl, .minus, .leftStickClick, .capture, .slLeft, .srLeft]
        case .right:
            return [.a, .b, .x, .y, .r, .zr, .plus, .rightStickClick, .home, .slRight, .srRight]
        case .proController, .unknown:
            return JoyConButton.allCases
        }
    }
}

/// Parsed snapshot of the controller state at one report tick.
struct JoyConInputState: Equatable {
    /// Buttons currently pressed.
    var pressedButtons: Set<JoyConButton> = []
    /// Normalized left stick, each axis in [-1.0, 1.0], 0 = centered.
    var leftStick: SIMD2<Double> = .zero
    /// Normalized right stick.
    var rightStick: SIMD2<Double> = .zero
    /// Battery percentage, 0-4 (raw 4-bit).
    var batteryLevel: UInt8 = 0
    /// Timestamp (monotonic) when this state was parsed.
    var timestamp: TimeInterval = 0
}

/// Axis for the two sticks on each controller.
enum StickAxis: String, Codable, CaseIterable, Hashable {
    case leftStickX = "left_stick_x"
    case leftStickY = "left_stick_y"
    case rightStickX = "right_stick_x"
    case rightStickY = "right_stick_y"

    var displayName: String {
        switch self {
        case .leftStickX: return "Left Stick X"
        case .leftStickY: return "Left Stick Y"
        case .rightStickX: return "Right Stick X"
        case .rightStickY: return "Right Stick Y"
        }
    }
}
