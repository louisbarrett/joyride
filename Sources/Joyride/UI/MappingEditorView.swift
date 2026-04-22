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
        .navigationTitle("Joyride — Mapping Editor")
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
    /// Observed ONLY for device add/remove and `connectedSides`, both of which are now
    /// published at very low frequency by `JoyConManager`. The high-frequency live state
    /// (stick values, report counts, pressed buttons) is isolated on `joyConManager.liveInput`
    /// and only subscribed to by `LiveInputSection` below. This is what stops the mapping
    /// Form from rebuilding at HID rate when a controller is connected.
    @ObservedObject var joyConManager: JoyConManager

    /// When true, we force-show every section regardless of what's paired. Lets
    /// users edit bindings for a Joy-Con that isn't currently connected.
    @State private var showAllSides: Bool = false

    /// Returns true if this group should be visible given what's connected and
    /// the "Show all" toggle. When no controller is connected we default to
    /// showing everything so the editor isn't empty the first time a user opens it.
    private func isGroupVisible(_ group: ButtonGroup) -> Bool {
        if showAllSides || joyConManager.devices.isEmpty { return true }
        return !group.sides.isDisjoint(with: joyConManager.connectedSides)
    }

    private var showLeftStick: Bool {
        if showAllSides || joyConManager.devices.isEmpty { return true }
        return !joyConManager.connectedSides.isDisjoint(with: [.left, .proController])
    }

    private var showRightStick: Bool {
        if showAllSides || joyConManager.devices.isEmpty { return true }
        return !joyConManager.connectedSides.isDisjoint(with: [.right, .proController])
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    ProfileNameField(name: $profile.name)
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
                        Text("Connected: \(joyConManager.connectedSides.map { $0.displayName }.sorted().joined(separator: ", "))")
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
                LiveInputSection(joyConManager: joyConManager, liveInput: joyConManager.liveInput)
            }
        }
        .formStyle(.grouped)
    }
}

/// Text field for the profile name that commits edits locally first and only propagates
/// the change to the binding on commit / end-editing. The previous implementation wrote
/// through the binding on every keystroke, which triggered a full `@Published profiles`
/// mutation, a debounced disk write, and a SwiftUI rebuild of the entire Form per
/// character. On a slow machine this dropped keystrokes.
private struct ProfileNameField: View {
    @Binding var name: String
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Profile name", text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.title3.bold())
            .focused($focused)
            .onAppear { draft = name }
            .onChange(of: name) { new in
                // External update (profile switched, rename applied from alert): resync
                // the local draft unless the user is mid-edit.
                if !focused { draft = new }
            }
            .onSubmit {
                if draft != name { name = draft }
            }
            .onChange(of: focused) { isFocused in
                // Commit on blur — the common Mac pattern for text fields.
                if !isFocused && draft != name { name = draft }
            }
    }
}

/// The part of the mapping editor that needs to reflect live controller input in real time.
/// This is the *only* place in the Form subtree that observes the high-frequency
/// `JoyConLiveInput` publisher, so it refreshes at ~30 Hz without dragging the rest of
/// the Form through a rebuild.
private struct LiveInputSection: View {
    @ObservedObject var joyConManager: JoyConManager
    @ObservedObject var liveInput: JoyConLiveInput

    var body: some View {
        if joyConManager.devices.isEmpty {
            Text("No controllers connected — pair a Joy-Con to see live input here.")
                .foregroundStyle(.secondary)
                .font(.callout)
        } else {
            ForEach(joyConManager.devices, id: \.identifier) { device in
                LiveInputView(
                    device: device,
                    state: liveInput.states[device.identifier],
                    joyConManager: joyConManager
                )
            }
        }
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
                // Fn (the "globe" key on modern Apple keyboards) is a first-class
                // modifier in CGEventFlags via `.maskSecondaryFn`. Adding it here
                // lets users emit combos like Fn+F for Full Screen or Fn+C for
                // the character viewer.
                ModifierToggle(symbol: "fn", isOn: modifierBinding(.fn, binding: binding), width: 30)
                    .help("Fn / Globe modifier")

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
    /// Wider glyphs like "fn" need a slightly roomier pill than single-symbol modifiers.
    var width: CGFloat = 26

    var body: some View {
        Button(action: { isOn.toggle() }) {
            Text(symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: width, height: 22)
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
        if case .mouseClick(let click) = action {
            HStack(spacing: 10) {
                Picker("Button", selection: Binding<MouseButton>(
                    get: { click.button },
                    set: { new in
                        action = .mouseClick(MouseClickAction(button: new, clickCount: click.clickCount))
                    }
                )) {
                    ForEach(MouseButton.allCases, id: \.self) { b in
                        Text(b.displayName).tag(b)
                    }
                }
                .labelsHidden()
                .frame(width: 160)

                // Segmented "click count" selector. We expose 1/2/3 rather than just
                // a "double click" checkbox because triple-click has real uses on
                // macOS (select-paragraph in text views) and the underlying CGEvent
                // API supports all three uniformly via kCGMouseEventClickState.
                Picker("Clicks", selection: Binding<Int>(
                    get: { click.clickCount },
                    set: { new in
                        action = .mouseClick(MouseClickAction(button: click.button, clickCount: new))
                    }
                )) {
                    Text("Single").tag(1)
                    Text("Double").tag(2)
                    Text("Triple").tag(3)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
                .help("Double-click emits a real macOS double-click gesture (e.g. select word, open folder in Finder). Single click preserves click-and-hold for dragging.")
            }
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
    /// Used to invoke `calibrateCenter` / `resetCalibration` against the right device.
    /// Not observed with `@ObservedObject` here because the containing `LiveInputSection`
    /// already observes it — re-observing would just double up re-renders.
    let joyConManager: JoyConManager

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

                CalibrationControls(device: device, state: s, joyConManager: joyConManager)
            } else {
                Text("Waiting for first report…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Calibration panel shown underneath each device's live input preview.
///
/// Guided two-phase capture:
///   1. **Rest** (~0.8 s) — user leaves both sticks alone. We average the raw
///      readings to establish a provisional center, which the roll phase needs
///      in order to classify incoming samples into rotation octants.
///   2. **Roll** (up to 5 s, auto-completes on full coverage) — user rotates
///      each stick in full circles. We track min/max per axis AND the set of
///      octants visited, so the UI can show the user exactly which arcs of the
///      rotation they still need to sweep through.
///
/// Final calibration:
///   - Center = midpoint of observed min/max on each axis **if** the user
///     rotated enough to produce a plausible span (≥ 500 raw LSB on either
///     axis). Otherwise we fall back to the rest-phase average — the user
///     gets a cleaner "center" than the factory default, just without a
///     recomputed range.
///   - Range = half-span of the observed bounds, clamped to a sensible
///     minimum so tiny wobbles don't produce a hair-trigger normalized output.
///
/// Single physical stick controllers (Left Joy-Con, Right Joy-Con) naturally
/// only produce raw data for the side they have; the other side's existing
/// calibration is preserved untouched.
private struct CalibrationControls: View {
    let device: JoyConDevice
    let state: JoyConInputState
    let joyConManager: JoyConManager

    private enum Phase: Equatable {
        case idle
        case resting(progress: Double)
        case rolling(progress: Double, leftOctants: UInt8, rightOctants: UInt8)
        case done(at: Date, summary: String)
        case failed(reason: String)
    }

    @State private var phase: Phase = .idle
    @State private var samplingTimer: Timer?

    /// Rest-phase duration. Short; we only need enough samples (~25 at 30 Hz)
    /// to average out the 1-2 LSB of noise Joy-Cons produce at rest.
    private let restWindow: TimeInterval = 0.8
    /// Maximum roll-phase duration. Users who cover all 8 octants finish earlier.
    private let rollWindow: TimeInterval = 5.0
    /// Minimum roll duration before auto-complete fires — prevents a momentary
    /// thumb sweep at the start of the phase from ending calibration instantly.
    private let rollMinDuration: TimeInterval = 1.2
    /// Sample every ~33 ms (~30 Hz). Matches the UI live-input refresh rate.
    private let sampleTick: TimeInterval = 1.0 / 30.0
    /// Minimum raw-LSB displacement from provisional center required to count a
    /// sample as "entered the outer ring" and mark its octant visited. Well
    /// above resting noise, well below full deflection.
    private let octantEntryThreshold: Double = 500.0
    /// Minimum per-axis span (in raw LSB) observed across the roll phase below
    /// which we consider the user's rotation insufficient and fall back to the
    /// rest-averaged center.
    private let minAcceptableSpan: Int = 500
    /// Minimum normalized range to persist. Prevents a half-hearted rotation
    /// from producing an over-saturated mapping where a gentle push reads ±1.0.
    private let minAcceptableRange: Int = 900

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if device.side.supportsHorizontalOrientation {
                orientationRow
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Calibration")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                centerReadoutView

                Spacer()

                switch phase {
                case .idle, .failed, .done:
                    Button(action: startCalibration) {
                        Label("Calibrate…", systemImage: "scope")
                    }
                    .controlSize(.small)
                    .help("Two-step calibration: hold both sticks at rest, then roll them in full circles while Joyride captures the true center and range.")

                    Button(action: resetCalibration) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help("Reset this controller's stick calibration to factory defaults.")

                case .resting, .rolling:
                    Button(action: cancelSampling) {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }

            guidanceView
        }
        .onDisappear {
            samplingTimer?.invalidate()
            samplingTimer = nil
        }
    }

    /// Orientation picker shown above the calibration row. Switching to
    /// "Horizontal" rotates the stick vector 90° (so pushing "up" from the
    /// user's rotated point of view moves the cursor up) and aliases the
    /// `SL` / `SR` rail buttons to the `L` / `ZL` (or `R` / `ZR`) bindings
    /// so that "trigger" mappings keep firing under the index fingers.
    @ViewBuilder
    private var orientationRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Orientation")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Picker("Orientation", selection: Binding<DeviceOrientation>(
                get: { device.orientation },
                set: { new in joyConManager.setOrientation(deviceID: device.identifier, orientation: new) }
            )) {
                ForEach(DeviceOrientation.allCases, id: \.self) { o in
                    Text(o.displayName).tag(o)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 280)
            .help("Pick 'Horizontal' when you're holding the Joy-Con sideways (rail on top, SL/SR under your index fingers). Rotates the stick 90° and aliases SL/SR to the L/ZL or R/ZR trigger bindings so existing profiles keep working.")

            Spacer()
        }
    }

    @ViewBuilder
    private var guidanceView: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .resting(let progress):
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 140)
                Text("Step 1 of 2 — Leave both sticks at rest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .rolling(let progress, let leftOct, let rightOct):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 140)
                    Text("Step 2 of 2 — Roll each stick in full circles.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(spacing: 18) {
                    if showsLeftStick {
                        OctantCoverage(label: "Left", visited: leftOct)
                    }
                    if showsRightStick {
                        OctantCoverage(label: "Right", visited: rightOct)
                    }
                    Spacer()
                }
            }
        case .done(let at, let summary):
            VStack(alignment: .leading, spacing: 2) {
                Text("Calibrated at \(Self.timeFormatter.string(from: at)).")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private var showsLeftStick: Bool {
        device.side == .left || device.side == .proController || device.side == .unknown
    }

    private var showsRightStick: Bool {
        device.side == .right || device.side == .proController || device.side == .unknown
    }

    /// Shows the current raw stick values alongside the saved calibration center so the
    /// user can see how far off-center the stick is before/after calibrating. Updates
    /// whenever `state` changes (which is ~30 Hz via the live-input flush).
    @ViewBuilder
    private var centerReadoutView: some View {
        let cal = device.currentCalibration
        HStack(spacing: 14) {
            if showsLeftStick, let raw = state.rawLeftStick {
                RawVsCenter(label: "L", raw: raw, center: SIMD2<Int>(cal.leftStick.centerX, cal.leftStick.centerY))
            }
            if showsRightStick, let raw = state.rawRightStick {
                RawVsCenter(label: "R", raw: raw, center: SIMD2<Int>(cal.rightStick.centerX, cal.rightStick.centerY))
            }
        }
    }

    // MARK: - Capture state machine

    private func startCalibration() {
        samplingTimer?.invalidate()

        // Rest-phase accumulators; yield the provisional center at the end of phase 1.
        var restLeftSum = SIMD2<Double>(0, 0)
        var restLeftCount = 0
        var restRightSum = SIMD2<Double>(0, 0)
        var restRightCount = 0

        // Roll-phase accumulators; reset at the start of phase 2 once we have a center.
        var leftProvCenter = SIMD2<Double>(0, 0)
        var rightProvCenter = SIMD2<Double>(0, 0)
        var leftMin = SIMD2<Int>(Int.max, Int.max)
        var leftMax = SIMD2<Int>(Int.min, Int.min)
        var rightMin = SIMD2<Int>(Int.max, Int.max)
        var rightMax = SIMD2<Int>(Int.min, Int.min)
        var leftOctants: UInt8 = 0
        var rightOctants: UInt8 = 0
        var leftSaw = false
        var rightSaw = false

        enum Stage { case rest, roll }
        var stage: Stage = .rest
        let restStart = Date()
        var rollStart = Date()

        phase = .resting(progress: 0)

        let timer = Timer.scheduledTimer(withTimeInterval: sampleTick, repeats: true) { timer in
            guard let latest = joyConManager.currentStates[device.identifier] else { return }

            switch stage {
            case .rest:
                if let raw = latest.rawLeftStick {
                    restLeftSum.x += Double(raw.x); restLeftSum.y += Double(raw.y); restLeftCount += 1
                }
                if let raw = latest.rawRightStick {
                    restRightSum.x += Double(raw.x); restRightSum.y += Double(raw.y); restRightCount += 1
                }

                let elapsed = Date().timeIntervalSince(restStart)
                let progress = min(1.0, elapsed / restWindow)
                DispatchQueue.main.async {
                    phase = .resting(progress: progress)
                }

                if elapsed >= restWindow {
                    // Lock in the provisional center used for octant classification.
                    // Fall back to factory defaults if one side never produced data —
                    // a Left Joy-Con's right-stick readings genuinely never appear.
                    let cal = device.currentCalibration
                    if restLeftCount > 0 {
                        leftProvCenter = SIMD2<Double>(restLeftSum.x / Double(restLeftCount),
                                                       restLeftSum.y / Double(restLeftCount))
                    } else {
                        leftProvCenter = SIMD2<Double>(Double(cal.leftStick.centerX), Double(cal.leftStick.centerY))
                    }
                    if restRightCount > 0 {
                        rightProvCenter = SIMD2<Double>(restRightSum.x / Double(restRightCount),
                                                        restRightSum.y / Double(restRightCount))
                    } else {
                        rightProvCenter = SIMD2<Double>(Double(cal.rightStick.centerX), Double(cal.rightStick.centerY))
                    }
                    stage = .roll
                    rollStart = Date()
                    DispatchQueue.main.async {
                        phase = .rolling(progress: 0, leftOctants: 0, rightOctants: 0)
                    }
                }

            case .roll:
                if let raw = latest.rawLeftStick {
                    leftSaw = true
                    let xi = Int(raw.x), yi = Int(raw.y)
                    leftMin.x = min(leftMin.x, xi); leftMin.y = min(leftMin.y, yi)
                    leftMax.x = max(leftMax.x, xi); leftMax.y = max(leftMax.y, yi)
                    if let bit = octantBit(raw: raw, center: leftProvCenter, threshold: octantEntryThreshold) {
                        leftOctants |= bit
                    }
                }
                if let raw = latest.rawRightStick {
                    rightSaw = true
                    let xi = Int(raw.x), yi = Int(raw.y)
                    rightMin.x = min(rightMin.x, xi); rightMin.y = min(rightMin.y, yi)
                    rightMax.x = max(rightMax.x, xi); rightMax.y = max(rightMax.y, yi)
                    if let bit = octantBit(raw: raw, center: rightProvCenter, threshold: octantEntryThreshold) {
                        rightOctants |= bit
                    }
                }

                let elapsed = Date().timeIntervalSince(rollStart)
                let progress = min(1.0, elapsed / rollWindow)
                let capturedLeft = leftOctants
                let capturedRight = rightOctants
                DispatchQueue.main.async {
                    phase = .rolling(progress: progress, leftOctants: capturedLeft, rightOctants: capturedRight)
                }

                // Auto-complete: all relevant sticks have fully-covered rotations
                // AND we've given the user enough time to not cancel accidentally.
                let leftComplete = !showsLeftStick || leftSaw == false || leftOctants == 0xFF
                let rightComplete = !showsRightStick || rightSaw == false || rightOctants == 0xFF
                let enoughTime = elapsed >= rollMinDuration
                if (leftComplete && rightComplete && enoughTime) || elapsed >= rollWindow {
                    timer.invalidate()
                    finalize(restLeftSum: restLeftSum, restLeftCount: restLeftCount,
                             restRightSum: restRightSum, restRightCount: restRightCount,
                             leftMin: leftMin, leftMax: leftMax, leftSaw: leftSaw,
                             rightMin: rightMin, rightMax: rightMax, rightSaw: rightSaw,
                             leftOctants: leftOctants, rightOctants: rightOctants)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        samplingTimer = timer
    }

    private func cancelSampling() {
        samplingTimer?.invalidate()
        samplingTimer = nil
        phase = .failed(reason: "Calibration cancelled.")
    }

    private func resetCalibration() {
        joyConManager.resetCalibration(deviceID: device.identifier)
        phase = .done(at: Date(), summary: "Reverted to factory defaults.")
    }

    // MARK: - Finalization

    // swiftlint:disable:next function_parameter_count
    private func finalize(restLeftSum: SIMD2<Double>, restLeftCount: Int,
                          restRightSum: SIMD2<Double>, restRightCount: Int,
                          leftMin: SIMD2<Int>, leftMax: SIMD2<Int>, leftSaw: Bool,
                          rightMin: SIMD2<Int>, rightMax: SIMD2<Int>, rightSaw: Bool,
                          leftOctants: UInt8, rightOctants: UInt8) {
        var cal = device.currentCalibration
        var anyChanged = false
        var summaryParts: [String] = []

        if leftSaw {
            let outcome = resolveStick(min: leftMin, max: leftMax,
                                       restSum: restLeftSum, restCount: restLeftCount,
                                       octants: leftOctants,
                                       existing: cal.leftStick)
            cal.leftStick = outcome.calibration
            summaryParts.append("Left: \(outcome.description)")
            anyChanged = true
        }
        if rightSaw {
            let outcome = resolveStick(min: rightMin, max: rightMax,
                                       restSum: restRightSum, restCount: restRightCount,
                                       octants: rightOctants,
                                       existing: cal.rightStick)
            cal.rightStick = outcome.calibration
            summaryParts.append("Right: \(outcome.description)")
            anyChanged = true
        }

        DispatchQueue.main.async {
            if anyChanged {
                device.applyCalibration(cal)
                joyConManager.calibrationStore.save(cal, serial: device.serialNumber, side: device.side)
                phase = .done(at: Date(), summary: summaryParts.joined(separator: "  ·  "))
            } else {
                phase = .failed(reason: "No raw stick data seen during calibration. Try again after the controller is producing reports.")
            }
            samplingTimer = nil
        }
    }

    private struct StickOutcome {
        let calibration: StickCalibration
        let description: String
    }

    /// Turn the collected min/max + rest data into a concrete `StickCalibration`.
    /// Picks between "use observed bounds" (ideal) and "rest-average only"
    /// (fallback) based on how much the user actually rotated.
    private func resolveStick(min lo: SIMD2<Int>,
                              max hi: SIMD2<Int>,
                              restSum: SIMD2<Double>,
                              restCount: Int,
                              octants: UInt8,
                              existing: StickCalibration) -> StickOutcome {
        let spanX = hi.x - lo.x
        let spanY = hi.y - lo.y
        let rotatedEnough = spanX >= minAcceptableSpan || spanY >= minAcceptableSpan

        if rotatedEnough {
            let centerX = (lo.x + hi.x) / 2
            let centerY = (lo.y + hi.y) / 2
            // Half-span per axis, clamped up so a partial rotation doesn't yield a
            // hyper-sensitive mapping. A full Joy-Con rotation typically produces a
            // half-span of ~1400-1600 LSB.
            let rangeX = max(minAcceptableRange, spanX / 2)
            let rangeY = max(minAcceptableRange, spanY / 2)
            let covered = octantCount(octants)
            let coverageNote = covered == 8
                ? "full rotation (8/8)"
                : "partial rotation (\(covered)/8 arcs)"
            let cal = StickCalibration(centerX: centerX, centerY: centerY,
                                       rangeX: rangeX, rangeY: rangeY)
            return StickOutcome(
                calibration: cal,
                description: "center (\(centerX),\(centerY)) · range ±\(rangeX)/\(rangeY) · \(coverageNote)"
            )
        } else if restCount > 0 {
            let centerX = Int((restSum.x / Double(restCount)).rounded())
            let centerY = Int((restSum.y / Double(restCount)).rounded())
            // Keep existing range — we didn't learn anything new about it.
            let cal = StickCalibration(centerX: centerX, centerY: centerY,
                                       rangeX: existing.rangeX, rangeY: existing.rangeY)
            return StickOutcome(
                calibration: cal,
                description: "rest-only center (\(centerX),\(centerY)) — stick wasn't rotated; range unchanged"
            )
        } else {
            return StickOutcome(
                calibration: existing,
                description: "no samples captured; left unchanged"
            )
        }
    }

    // MARK: - Geometry helpers

    /// Returns a bit in 0x01..0x80 identifying which of the 8 octants this raw
    /// reading falls in, or `nil` if the sample is still inside the "dead zone"
    /// around the provisional center. Octants are indexed clockwise from 12 o'clock
    /// (bit 0 = up, bit 2 = right, bit 4 = down, bit 6 = left).
    private func octantBit(raw: SIMD2<UInt16>, center: SIMD2<Double>, threshold: Double) -> UInt8? {
        let dx = Double(raw.x) - center.x
        let dy = Double(raw.y) - center.y
        if (dx * dx + dy * dy).squareRoot() < threshold { return nil }
        // atan2 returns radians in (-π, π]. The stick's Y axis in raw HID is
        // "up = larger value" (same as our normalized convention before Quartz
        // flipping), so +dy points upward. We shift the origin to 12-o'clock
        // and wrap into [0, 2π), then bucket into 8 × 45° slices.
        var angle = atan2(dy, dx) // 0 rad = right
        // Convert so 0 rad = up, increasing clockwise — matches the labels on
        // the OctantCoverage dots and intuition ("top = bit 0, right = bit 2").
        angle = (Double.pi / 2) - angle
        if angle < 0 { angle += 2 * Double.pi }
        if angle >= 2 * Double.pi { angle -= 2 * Double.pi }
        // Centered bucketing: rotate by half a slice so the first slice straddles
        // 12 o'clock instead of starting from it. Keeps "straight up" inside bit 0
        // even with small wobbles.
        let slice = (2 * Double.pi) / 8
        let bucket = Int((angle + slice / 2) / slice) & 0x7
        return UInt8(1 << bucket)
    }

    private func octantCount(_ bits: UInt8) -> Int {
        bits.nonzeroBitCount
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// 8-dot circular coverage indicator. Each dot corresponds to a 45° octant of
/// the stick's rotation; dots light up as the user sweeps through that arc.
/// Gives unambiguous visual feedback on "where do I still need to roll?".
private struct OctantCoverage: View {
    let label: String
    let visited: UInt8

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.3), lineWidth: 1)
                    .frame(width: 38, height: 38)
                ForEach(0..<8, id: \.self) { i in
                    let lit = (visited & UInt8(1 << i)) != 0
                    Circle()
                        .fill(lit ? Color.green : Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                        .offset(offsetForOctant(i, radius: 19))
                }
            }
            .frame(width: 38, height: 38)
            Text("\(visited.nonzeroBitCount)/8")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(visited == 0xFF ? .green : .secondary)
        }
    }

    private func offsetForOctant(_ index: Int, radius: CGFloat) -> CGSize {
        // Match CalibrationControls.octantBit: bit 0 = up, clockwise.
        let slice = (2 * Double.pi) / 8.0
        let angle = Double(index) * slice // 0 = up
        // Convert "clockwise from up" to Cartesian dx/dy (SwiftUI y-down).
        let dx = sin(angle)
        let dy = -cos(angle)
        return CGSize(width: CGFloat(dx) * radius, height: CGFloat(dy) * radius)
    }
}

/// Tiny read-only badge showing "raw – center" for a single stick. Highlights in orange
/// when the difference exceeds ~120 LSB (a rule-of-thumb threshold for visible drift
/// relative to the ±1500 default range, which is ~8%).
private struct RawVsCenter: View {
    let label: String
    let raw: SIMD2<UInt16>
    let center: SIMD2<Int>

    var body: some View {
        let dx = Int(raw.x) - center.x
        let dy = Int(raw.y) - center.y
        let drifting = abs(dx) > 120 || abs(dy) > 120
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text("raw \(raw.x),\(raw.y)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Δ \(dx > 0 ? "+" : "")\(dx),\(dy > 0 ? "+" : "")\(dy)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(drifting ? .orange : .secondary)
        }
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
            return .mouseClick(MouseClickAction(button: .left))
        case 3:
            if case .scroll(let s) = previous { return .scroll(s) }
            return .scroll(ScrollAction(direction: .down))
        default: return .none
        }
    }
}
