import SwiftUI

/// Main window for editing mapping profiles.
struct MappingEditorView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var profileStore: ProfileStore
    @ObservedObject var joyConManager: JoyConManager

    @State private var selectedProfileID: UUID?
    @State private var renameText: String = ""
    @State private var showRename: Bool = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            profileList
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            if let profile = currentProfile {
                ProfileDetailView(
                    profile: binding(for: profile.id),
                    joyConManager: joyConManager
                )
            } else {
                ContentUnavailableLabel(
                    title: "Select a profile",
                    systemImage: "slider.horizontal.3",
                    description: "Choose a profile on the left to edit its button and stick bindings."
                )
            }
        }
        .navigationTitle("Lovejoy — Mapping Editor")
        .frame(minWidth: 980, minHeight: 620)
        .onAppear {
            if selectedProfileID == nil {
                selectedProfileID = profileStore.activeProfileID
            }
        }
    }

    private var currentProfile: MappingProfile? {
        guard let id = selectedProfileID else { return nil }
        return profileStore.profiles.first(where: { $0.id == id })
    }

    private func binding(for id: UUID) -> Binding<MappingProfile> {
        Binding(
            get: {
                profileStore.profiles.first(where: { $0.id == id })
                    ?? MappingProfile.defaultScrollingProfile()
            },
            set: { new in
                profileStore.save(new)
            }
        )
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedProfileID) {
                Section("Profiles") {
                    ForEach(profileStore.profiles) { profile in
                        HStack {
                            Image(systemName: profile.id == profileStore.activeProfileID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(profile.id == profileStore.activeProfileID ? .green : .secondary)
                                .onTapGesture {
                                    profileStore.setActive(profile.id)
                                }
                            Text(profile.name)
                                .fontWeight(profile.id == profileStore.activeProfileID ? .semibold : .regular)
                        }
                        .tag(profile.id)
                        .contextMenu {
                            Button("Set Active") { profileStore.setActive(profile.id) }
                            Button("Duplicate") { profileStore.duplicate(profile.id) }
                            Button("Rename…") {
                                renameText = profile.name
                                selectedProfileID = profile.id
                                showRename = true
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                profileStore.delete(profile.id)
                            }
                            .disabled(profileStore.profiles.count <= 1)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 8) {
                Button {
                    let new = MappingProfile(name: "New Profile")
                    profileStore.save(new)
                    selectedProfileID = new.id
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a new empty profile")

                Button {
                    if let id = selectedProfileID { profileStore.duplicate(id) }
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .help("Duplicate selected profile")
                .disabled(selectedProfileID == nil)

                Button {
                    if let id = selectedProfileID, profileStore.profiles.count > 1 {
                        profileStore.delete(id)
                        selectedProfileID = profileStore.profiles.first?.id
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .help("Delete selected profile")
                .disabled((selectedProfileID == nil) || profileStore.profiles.count <= 1)

                Spacer()

                Toggle("Enabled", isOn: $app.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(8)
        }
        .alert("Rename Profile", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                if let id = selectedProfileID,
                   var p = profileStore.profiles.first(where: { $0.id == id }) {
                    p.name = renameText
                    profileStore.save(p)
                }
            }
        }
    }
}

// MARK: - Profile detail

/// Groups of buttons for sectioned display. Each group is tied to a physical
/// Joy-Con "side" so we can hide sections whose hardware isn't connected.
private enum ButtonGroup: String, CaseIterable {
    case rightJoyCon = "Right Joy-Con"
    case leftJoyCon = "Left Joy-Con"
    case rightSideRails = "Right Joy-Con — Side Rails (SL / SR)"
    case leftSideRails = "Left Joy-Con — Side Rails (SL / SR)"

    var buttons: [JoyConButton] {
        switch self {
        case .rightJoyCon:
            return [.a, .b, .x, .y, .r, .zr, .plus, .rightStickClick, .home]
        case .leftJoyCon:
            return [.dpadUp, .dpadDown, .dpadLeft, .dpadRight, .l, .zl, .minus, .leftStickClick, .capture]
        case .rightSideRails:
            return [.slRight, .srRight]
        case .leftSideRails:
            return [.slLeft, .srLeft]
        }
    }

    /// Which physical Joy-Con sides populate this group. A group is shown if any
    /// of the connected devices matches one of these sides (or if nothing is
    /// connected at all, or the user has flipped "Show all").
    var sides: Set<JoyConSide> {
        switch self {
        case .rightJoyCon, .rightSideRails: return [.right, .proController]
        case .leftJoyCon, .leftSideRails:   return [.left, .proController]
        }
    }
}

private struct ProfileDetailView: View {
    @Binding var profile: MappingProfile
    @ObservedObject var joyConManager: JoyConManager

    /// When true, we force-show every section regardless of what's paired. Lets
    /// users edit bindings for a Joy-Con that isn't currently connected.
    @State private var showAllSides: Bool = false

    /// Sides currently connected (Left, Right, Pro, …).
    private var connectedSides: Set<JoyConSide> {
        Set(joyConManager.devices.map { $0.side })
    }

    /// Returns true if this group should be visible given what's connected and
    /// the "Show all" toggle. When no controller is connected we default to
    /// showing everything so the editor isn't empty the first time a user opens it.
    private func isGroupVisible(_ group: ButtonGroup) -> Bool {
        if showAllSides || joyConManager.devices.isEmpty { return true }
        return !group.sides.isDisjoint(with: connectedSides)
    }

    private var showLeftStick: Bool {
        if showAllSides || joyConManager.devices.isEmpty { return true }
        return !connectedSides.isDisjoint(with: [.left, .proController])
    }

    private var showRightStick: Bool {
        if showAllSides || joyConManager.devices.isEmpty { return true }
        return !connectedSides.isDisjoint(with: [.right, .proController])
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Profile name", text: $profile.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3.bold())
                    Spacer()
                }
                Text("Bindings apply when this profile is active. Switch profiles from the menu bar popover.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: joyConManager.devices.isEmpty ? "exclamationmark.triangle.fill" : "dot.radiowaves.left.and.right")
                        .foregroundStyle(joyConManager.devices.isEmpty ? .orange : .green)
                    if joyConManager.devices.isEmpty {
                        Text("No controllers connected — showing all sections so you can still edit.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Connected: \(connectedSides.map { $0.displayName }.sorted().joined(separator: ", "))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Show all", isOn: $showAllSides)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Show bindings for Joy-Con sides that aren't currently connected.")
                        .disabled(joyConManager.devices.isEmpty)
                }
            }

            ForEach(ButtonGroup.allCases, id: \.self) { group in
                if isGroupVisible(group) {
                    Section(group.rawValue) {
                        ForEach(group.buttons) { button in
                            ButtonBindingRow(
                                button: button,
                                action: Binding(
                                    get: { profile.buttonBindings[button] ?? .none },
                                    set: { new in
                                        var copy = profile
                                        if case .none = new {
                                            copy.buttonBindings.removeValue(forKey: button)
                                        } else {
                                            copy.buttonBindings[button] = new
                                        }
                                        profile = copy
                                    }
                                )
                            )
                        }
                    }
                }
            }

            if showLeftStick || showRightStick {
                Section("Analog Sticks") {
                    if showLeftStick {
                        StickBindingRow(label: "Left Stick", action: $profile.leftStick)
                    }
                    if showRightStick {
                        StickBindingRow(label: "Right Stick", action: $profile.rightStick)
                    }
                }
            }

            Section("Live Input Preview") {
                if joyConManager.devices.isEmpty {
                    Text("No controllers connected — pair a Joy-Con to see live input here.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(joyConManager.devices, id: \.identifier) { device in
                        LiveInputView(device: device, state: joyConManager.latestStates[device.identifier])
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Button binding row

private struct ButtonBindingRow: View {
    let button: JoyConButton
    @Binding var action: ButtonAction

    var body: some View {
        HStack(spacing: 12) {
            Text(button.displayName)
                .font(.body)
                .frame(width: 160, alignment: .leading)
            ActionPicker(action: $action)
            Spacer(minLength: 0)
        }
    }
}

private struct ActionPicker: View {
    @Binding var action: ButtonAction

    var body: some View {
        HStack(spacing: 10) {
            Picker("Type", selection: Binding<Int>(
                get: { action.typeIndex },
                set: { idx in action = ButtonAction.defaultFor(typeIndex: idx, previous: action) }
            )) {
                Text("Unassigned").tag(0)
                Text("Key").tag(1)
                Text("Mouse").tag(2)
                Text("Scroll").tag(3)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 110)

            Group {
                switch action {
                case .none:
                    EmptyView()
                case .key:
                    KeyActionEditor(action: $action)
                case .mouseClick:
                    MouseActionEditor(action: $action)
                case .scroll:
                    ScrollActionEditor(action: $action)
                }
            }
        }
    }
}

private struct KeyActionEditor: View {
    @Binding var action: ButtonAction

    var body: some View {
        if case .key(let binding) = action {
            HStack(spacing: 6) {
                ModifierToggle(symbol: "⌃", isOn: modifierBinding(.control, binding: binding))
                ModifierToggle(symbol: "⌥", isOn: modifierBinding(.option, binding: binding))
                ModifierToggle(symbol: "⇧", isOn: modifierBinding(.shift, binding: binding))
                ModifierToggle(symbol: "⌘", isOn: modifierBinding(.command, binding: binding))

                Picker("Key", selection: Binding<KeyCode>(
                    get: { binding.key },
                    set: { new in
                        var b = binding
                        b.key = new
                        action = .key(b)
                    }
                )) {
                    ForEach(KeyCode.allCases) { code in
                        Text(code.displayName).tag(code)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }
        }
    }

    private func modifierBinding(_ mod: KeyModifiers, binding: KeyBinding) -> Binding<Bool> {
        Binding<Bool>(
            get: { binding.modifiers.contains(mod) },
            set: { on in
                var b = binding
                if on { b.modifiers.insert(mod) } else { b.modifiers.remove(mod) }
                action = .key(b)
            }
        )
    }
}

private struct ModifierToggle: View {
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Button(action: { isOn.toggle() }) {
            Text(symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isOn ? Color.accentColor : Color.gray.opacity(0.35), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MouseActionEditor: View {
    @Binding var action: ButtonAction

    var body: some View {
        if case .mouseClick(let m) = action {
            Picker("Button", selection: Binding<MouseButton>(
                get: { m },
                set: { action = .mouseClick($0) }
            )) {
                ForEach(MouseButton.allCases, id: \.self) { b in
                    Text(b.displayName).tag(b)
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }
}

private struct ScrollActionEditor: View {
    @Binding var action: ButtonAction

    var body: some View {
        if case .scroll(let cfg) = action {
            HStack(spacing: 10) {
                Picker("Direction", selection: Binding<ScrollDirection>(
                    get: { cfg.direction },
                    set: { new in
                        action = .scroll(ScrollAction(
                            direction: new,
                            pixelsPerTick: cfg.pixelsPerTick,
                            tickInterval: cfg.tickInterval,
                            repeatWhileHeld: cfg.repeatWhileHeld
                        ))
                    }
                )) {
                    ForEach(ScrollDirection.allCases, id: \.self) { d in
                        Text(d.displayName).tag(d)
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                HStack(spacing: 4) {
                    Text("\(cfg.pixelsPerTick) px")
                        .monospaced()
                        .font(.callout)
                        .frame(width: 56, alignment: .trailing)
                    Stepper("", value: Binding<Int>(
                        get: { Int(cfg.pixelsPerTick) },
                        set: { new in
                            action = .scroll(ScrollAction(
                                direction: cfg.direction,
                                pixelsPerTick: Int32(new),
                                tickInterval: cfg.tickInterval,
                                repeatWhileHeld: cfg.repeatWhileHeld
                            ))
                        }
                    ), in: 1...200, step: 1)
                    .labelsHidden()
                }

                Toggle(isOn: Binding<Bool>(
                    get: { cfg.repeatWhileHeld },
                    set: { new in
                        action = .scroll(ScrollAction(
                            direction: cfg.direction,
                            pixelsPerTick: cfg.pixelsPerTick,
                            tickInterval: cfg.tickInterval,
                            repeatWhileHeld: new
                        ))
                    }
                )) {
                    Text("Repeat while held").font(.callout)
                }
                .toggleStyle(.checkbox)
                .fixedSize()
            }
        }
    }
}

// MARK: - Stick binding row

private struct StickBindingRow: View {
    let label: String
    @Binding var action: StickAction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(label)
                    .font(.body)
                    .frame(width: 160, alignment: .leading)
                Picker("Mode", selection: Binding<Int>(
                    get: {
                        switch action {
                        case .none: return 0
                        case .mouseCursor: return 1
                        }
                    },
                    set: { idx in
                        switch idx {
                        case 0: action = .none
                        default:
                            if case .mouseCursor = action { return }
                            action = .mouseCursor(MouseCursorStickConfig())
                        }
                    }
                )) {
                    Text("Unassigned").tag(0)
                    Text("Mouse Cursor").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Spacer()
            }

            if case .mouseCursor(let cfg) = action {
                VStack(alignment: .leading, spacing: 6) {
                    SliderRow(
                        label: "Sensitivity",
                        value: Binding<Double>(
                            get: { cfg.pixelsPerSecond },
                            set: { new in
                                var c = cfg; c.pixelsPerSecond = new
                                action = .mouseCursor(c)
                            }
                        ),
                        range: 100...2500,
                        format: "%.0f px/s"
                    )
                    SliderRow(
                        label: "Deadzone",
                        value: Binding<Double>(
                            get: { cfg.deadzone },
                            set: { new in
                                var c = cfg; c.deadzone = new
                                action = .mouseCursor(c)
                            }
                        ),
                        range: 0.0...0.5,
                        format: "%.2f"
                    )
                    SliderRow(
                        label: "Response Curve",
                        value: Binding<Double>(
                            get: { cfg.responseCurve },
                            set: { new in
                                var c = cfg; c.responseCurve = new
                                action = .mouseCursor(c)
                            }
                        ),
                        range: 1.0...3.0,
                        format: "%.2f"
                    )
                    Toggle("Invert Y axis", isOn: Binding<Bool>(
                        get: { cfg.invertY },
                        set: { new in
                            var c = cfg; c.invertY = new
                            action = .mouseCursor(c)
                        }
                    ))
                    .padding(.leading, 160)
                }
            }
        }
    }
}

private struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            Slider(value: $value, in: range)
                .frame(minWidth: 200, maxWidth: 360)
            Text(String(format: format, value))
                .monospaced()
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Spacer()
        }
    }
}

// MARK: - Live input preview

private struct LiveInputView: View {
    let device: JoyConDevice
    let state: JoyConInputState?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
                Text(device.side.displayName).font(.subheadline.bold())
                Spacer()
                if let s = state {
                    Text("Battery: \(min(100, Int(Double(s.batteryLevel) / 8.0 * 100)))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let s = state {
                HStack(alignment: .top, spacing: 20) {
                    if device.side == .left || device.side == .proController || device.side == .unknown {
                        StickVisualizer(label: "Left", value: s.leftStick)
                    }
                    if device.side == .right || device.side == .proController || device.side == .unknown {
                        StickVisualizer(label: "Right", value: s.rightStick)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pressed").font(.caption.bold())
                        if s.pressedButtons.isEmpty {
                            Text("—").foregroundStyle(.secondary).font(.caption)
                        } else {
                            Text(s.pressedButtons.map { $0.displayName }.sorted().joined(separator: ", "))
                                .font(.caption.monospaced())
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                }
            } else {
                Text("Waiting for first report…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StickVisualizer: View {
    let label: String
    let value: SIMD2<Double>

    var body: some View {
        VStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.4), lineWidth: 1)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .offset(x: CGFloat(value.x) * 26, y: CGFloat(-value.y) * 26)
            }
            .frame(width: 60, height: 60)
            Text(String(format: "%.2f, %.2f", value.x, value.y))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

private struct ContentUnavailableLabel: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 48)).foregroundStyle(.tertiary)
            Text(title).font(.title3)
            Text(description).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Helpers

private extension ButtonAction {
    var typeIndex: Int {
        switch self {
        case .none: return 0
        case .key: return 1
        case .mouseClick: return 2
        case .scroll: return 3
        }
    }

    static func defaultFor(typeIndex: Int, previous: ButtonAction) -> ButtonAction {
        switch typeIndex {
        case 0: return .none
        case 1:
            if case .key(let b) = previous { return .key(b) }
            return .key(KeyBinding(key: .space, modifiers: []))
        case 2:
            if case .mouseClick(let m) = previous { return .mouseClick(m) }
            return .mouseClick(.left)
        case 3:
            if case .scroll(let s) = previous { return .scroll(s) }
            return .scroll(ScrollAction(direction: .down))
        default: return .none
        }
    }
}
