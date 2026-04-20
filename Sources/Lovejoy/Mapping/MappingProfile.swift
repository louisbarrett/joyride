import Foundation

/// A single action that a button press can perform.
enum ButtonAction: Codable, Hashable, Identifiable {
    case none
    case key(KeyBinding)
    case mouseClick(MouseButton)
    case scroll(ScrollAction)

    var id: String {
        switch self {
        case .none: return "none"
        case .key(let b): return "key:\(b.id)"
        case .mouseClick(let m): return "mouse:\(m.rawValue)"
        case .scroll(let s): return "scroll:\(s.id)"
        }
    }

    var displayName: String {
        switch self {
        case .none: return "Unassigned"
        case .key(let b): return b.displayName
        case .mouseClick(let m): return m.displayName
        case .scroll(let s): return s.displayName
        }
    }

    // Codable plumbing via discriminator, so profiles stay stable as we add new cases.
    private enum CodingKeys: String, CodingKey { case type, value }
    private enum ActionType: String, Codable { case none, key, mouseClick = "mouse_click", scroll }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(ActionType.self, forKey: .type)
        switch type {
        case .none:
            self = .none
        case .key:
            self = .key(try c.decode(KeyBinding.self, forKey: .value))
        case .mouseClick:
            self = .mouseClick(try c.decode(MouseButton.self, forKey: .value))
        case .scroll:
            self = .scroll(try c.decode(ScrollAction.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try c.encode(ActionType.none, forKey: .type)
        case .key(let b):
            try c.encode(ActionType.key, forKey: .type)
            try c.encode(b, forKey: .value)
        case .mouseClick(let m):
            try c.encode(ActionType.mouseClick, forKey: .type)
            try c.encode(m, forKey: .value)
        case .scroll(let s):
            try c.encode(ActionType.scroll, forKey: .type)
            try c.encode(s, forKey: .value)
        }
    }
}

/// A key + modifiers combination bound to a button.
struct KeyBinding: Codable, Hashable, Identifiable {
    var key: KeyCode
    var modifiers: KeyModifiers

    var id: String {
        "\(modifiers.rawValue)-\(key.rawValue)"
    }

    var displayName: String {
        let mods = modifiers.displayFragments.joined()
        return mods + key.displayName
    }
}

/// Scroll assignment for a button — which direction and whether it should auto-repeat while held.
struct ScrollAction: Codable, Hashable, Identifiable {
    var direction: ScrollDirection
    /// Pixels emitted per repeat tick. Default yields ~60 px/sec at 5ms tick, a comfortable pace.
    var pixelsPerTick: Int32
    /// Tick interval in seconds while the button is held. Smaller = smoother but more CPU.
    var tickInterval: TimeInterval
    /// If false, a single press emits exactly one scroll event (no repeat).
    var repeatWhileHeld: Bool

    init(direction: ScrollDirection,
         pixelsPerTick: Int32 = 12,
         tickInterval: TimeInterval = 0.016,
         repeatWhileHeld: Bool = true) {
        self.direction = direction
        self.pixelsPerTick = pixelsPerTick
        self.tickInterval = tickInterval
        self.repeatWhileHeld = repeatWhileHeld
    }

    var id: String {
        "\(direction.rawValue)-\(pixelsPerTick)-\(tickInterval)-\(repeatWhileHeld)"
    }

    var displayName: String {
        repeatWhileHeld ? "\(direction.displayName) (hold)" : "\(direction.displayName) (tap)"
    }
}

/// Stick assignment — today, either cursor movement or "unassigned".
enum StickAction: Codable, Hashable {
    case none
    case mouseCursor(MouseCursorStickConfig)

    private enum CodingKeys: String, CodingKey { case type, value }
    private enum StickActionType: String, Codable { case none, mouseCursor = "mouse_cursor" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(StickActionType.self, forKey: .type)
        switch type {
        case .none: self = .none
        case .mouseCursor: self = .mouseCursor(try c.decode(MouseCursorStickConfig.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try c.encode(StickActionType.none, forKey: .type)
        case .mouseCursor(let cfg):
            try c.encode(StickActionType.mouseCursor, forKey: .type)
            try c.encode(cfg, forKey: .value)
        }
    }

    var displayName: String {
        switch self {
        case .none: return "Unassigned"
        case .mouseCursor: return "Mouse Cursor"
        }
    }
}

/// Tunable parameters for mapping a stick to the mouse cursor.
struct MouseCursorStickConfig: Codable, Hashable {
    /// Below this magnitude (in [0, 1] from center), the stick is treated as neutral.
    var deadzone: Double
    /// Max pixels per second the cursor moves at full deflection.
    var pixelsPerSecond: Double
    /// Exponent used to curve stick response; 1.0 = linear, 2.0 = "gamer" acceleration.
    var responseCurve: Double
    /// Invert Y so pushing up moves the cursor up on screen.
    var invertY: Bool

    init(deadzone: Double = 0.12,
         pixelsPerSecond: Double = 900,
         responseCurve: Double = 1.5,
         invertY: Bool = false) {
        self.deadzone = deadzone
        self.pixelsPerSecond = pixelsPerSecond
        self.responseCurve = responseCurve
        self.invertY = invertY
    }
}

/// A named set of button- and stick-to-action bindings.
struct MappingProfile: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var buttonBindings: [JoyConButton: ButtonAction]
    var leftStick: StickAction
    var rightStick: StickAction

    init(id: UUID = UUID(),
         name: String,
         buttonBindings: [JoyConButton: ButtonAction] = [:],
         leftStick: StickAction = .none,
         rightStick: StickAction = .none) {
        self.id = id
        self.name = name
        self.buttonBindings = buttonBindings
        self.leftStick = leftStick
        self.rightStick = rightStick
    }

    func action(for button: JoyConButton) -> ButtonAction {
        buttonBindings[button] ?? .none
    }

    // Codable: `[JoyConButton: ButtonAction]` needs explicit string-keyed encoding because
    // the default keyed container would try to use String keys — which works — but we want
    // stable JSON key ordering and to survive unknown enum cases without crashing.
    private enum CodingKeys: String, CodingKey {
        case id, name, buttonBindings = "button_bindings", leftStick = "left_stick", rightStick = "right_stick"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.leftStick = (try? c.decode(StickAction.self, forKey: .leftStick)) ?? .none
        self.rightStick = (try? c.decode(StickAction.self, forKey: .rightStick)) ?? .none

        let raw = try c.decodeIfPresent([String: ButtonAction].self, forKey: .buttonBindings) ?? [:]
        var bindings: [JoyConButton: ButtonAction] = [:]
        for (key, value) in raw {
            if let btn = JoyConButton(rawValue: key) {
                bindings[btn] = value
            }
        }
        self.buttonBindings = bindings
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(leftStick, forKey: .leftStick)
        try c.encode(rightStick, forKey: .rightStick)
        var stringKeyed: [String: ButtonAction] = [:]
        for (k, v) in buttonBindings { stringKeyed[k.rawValue] = v }
        try c.encode(stringKeyed, forKey: .buttonBindings)
    }
}

extension MappingProfile {
    /// The default "Scrolling" profile that demonstrates the headline feature.
    static func defaultScrollingProfile() -> MappingProfile {
        MappingProfile(
            name: "Scrolling",
            buttonBindings: [
                .a: .scroll(ScrollAction(direction: .down)),
                .b: .scroll(ScrollAction(direction: .up)),
                .x: .scroll(ScrollAction(direction: .up, pixelsPerTick: 40, tickInterval: 0.02)),
                .y: .scroll(ScrollAction(direction: .down, pixelsPerTick: 40, tickInterval: 0.02)),
                .r: .mouseClick(.left),
                .zr: .mouseClick(.right),
                .plus: .key(KeyBinding(key: .space, modifiers: [])),
                .home: .key(KeyBinding(key: .escape, modifiers: [])),
                // Left Joy-Con defaults in case only a Left is connected
                .dpadUp: .scroll(ScrollAction(direction: .up)),
                .dpadDown: .scroll(ScrollAction(direction: .down)),
                .dpadLeft: .scroll(ScrollAction(direction: .left)),
                .dpadRight: .scroll(ScrollAction(direction: .right)),
                .l: .mouseClick(.left),
                .zl: .mouseClick(.right),
                .minus: .key(KeyBinding(key: .space, modifiers: [])),
                .capture: .key(KeyBinding(key: .escape, modifiers: []))
            ],
            leftStick: .mouseCursor(MouseCursorStickConfig()),
            rightStick: .mouseCursor(MouseCursorStickConfig())
        )
    }

    /// A gaming-oriented starter: WASD + arrow keys, sticks as cursor.
    static func defaultGamingProfile() -> MappingProfile {
        MappingProfile(
            name: "Gaming",
            buttonBindings: [
                .a: .key(KeyBinding(key: .space, modifiers: [])),
                .b: .key(KeyBinding(key: .returnKey, modifiers: [])),
                .x: .key(KeyBinding(key: .e, modifiers: [])),
                .y: .key(KeyBinding(key: .q, modifiers: [])),
                .r: .mouseClick(.left),
                .zr: .mouseClick(.right),
                .plus: .key(KeyBinding(key: .escape, modifiers: [])),
                .dpadUp: .key(KeyBinding(key: .w, modifiers: [])),
                .dpadDown: .key(KeyBinding(key: .s, modifiers: [])),
                .dpadLeft: .key(KeyBinding(key: .a, modifiers: [])),
                .dpadRight: .key(KeyBinding(key: .d, modifiers: [])),
                .l: .mouseClick(.left),
                .zl: .mouseClick(.right),
                .minus: .key(KeyBinding(key: .tab, modifiers: []))
            ],
            rightStick: .mouseCursor(MouseCursorStickConfig())
        )
    }

    /// Presentation remote: page up/down + space.
    static func defaultPresentationProfile() -> MappingProfile {
        MappingProfile(
            name: "Presentation",
            buttonBindings: [
                .a: .key(KeyBinding(key: .right, modifiers: [])),
                .b: .key(KeyBinding(key: .left, modifiers: [])),
                .x: .key(KeyBinding(key: .pageUp, modifiers: [])),
                .y: .key(KeyBinding(key: .pageDown, modifiers: [])),
                .r: .key(KeyBinding(key: .right, modifiers: [])),
                .zr: .key(KeyBinding(key: .left, modifiers: [])),
                .plus: .key(KeyBinding(key: .space, modifiers: [])),
                .home: .key(KeyBinding(key: .escape, modifiers: [])),
                .dpadUp: .key(KeyBinding(key: .pageUp, modifiers: [])),
                .dpadDown: .key(KeyBinding(key: .pageDown, modifiers: [])),
                .dpadLeft: .key(KeyBinding(key: .left, modifiers: [])),
                .dpadRight: .key(KeyBinding(key: .right, modifiers: [])),
                .l: .key(KeyBinding(key: .left, modifiers: [])),
                .zl: .key(KeyBinding(key: .right, modifiers: [])),
                .minus: .key(KeyBinding(key: .escape, modifiers: []))
            ]
        )
    }
}
