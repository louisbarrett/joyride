import Foundation
import Combine
import CoreGraphics

/// Translates Joy-Con input events into output (key/mouse/scroll) events according to the
/// currently active `MappingProfile`. Owns and drives timers for scroll-repeat and stick-to-cursor.
final class MappingEngine: ObservableObject {
    private let profileStore: ProfileStore
    private let joyConManager: JoyConManager
    private let keyboard = KeyboardInjector()
    private let mouse = MouseInjector()
    private let scroll = ScrollInjector()

    /// Active scroll-repeat timers, keyed by the button that triggered them, per device.
    private var scrollTimers: [UUID: [JoyConButton: DispatchSourceTimer]] = [:]
    /// Currently-held keys, so we emit keyUp cleanly when the button releases.
    private var heldKeys: [UUID: [JoyConButton: KeyBinding]] = [:]
    /// Currently-held mouse buttons (for drag-style bindings).
    private var heldMouseButtons: [UUID: [JoyConButton: MouseButton]] = [:]

    /// High-frequency timer that moves the cursor based on stick deflection. Lives on
    /// the main queue because it reads `joyConManager.currentStates` which is mutated on
    /// main by the HID callbacks — reading from any other thread would race.
    private var cursorTimer: DispatchSourceTimer?
    private var lastCursorTickTime: CFAbsoluteTime = 0

    /// Dedicated queue for scroll-repeat timers. `CGEvent.post(tap:)` is thread-safe, so
    /// moving these ticks off the main queue keeps hold-to-scroll ticking smoothly even
    /// when SwiftUI is busy laying out the Mapping Editor. Before this change, a busy
    /// main thread would coalesce the scroll repeats and the user would see long pauses
    /// or missing scroll events ("input not being sent").
    private let outputQueue = DispatchQueue(label: "com.lovejoy.engine.output", qos: .userInitiated)

    private var isEnabled: Bool = true

    /// Running totals surfaced to the UI so users can see whether the pipeline is
    /// actually dispatching events vs silently dropping them (the classic "Accessibility
    /// permission missing" symptom).
    @Published private(set) var buttonEventCount: Int = 0
    @Published private(set) var cursorMoveCount: Int = 0
    @Published private(set) var dispatchedActions: [String] = []
    private let dispatchedLogLimit = 30

    /// Internal counter — incremented on every cursor move tick, but only flushed to the
    /// `@Published` mirror above at `cursorPublishInterval`. Without this throttle the
    /// menu-bar popover (which observes us) would rebuild at 120 Hz whenever a stick is
    /// deflected.
    private var internalCursorMoveCount: Int = 0
    private var lastCursorPublishTime: CFAbsoluteTime = 0
    private let cursorPublishInterval: TimeInterval = 0.25  // 4 Hz

    init(profileStore: ProfileStore, joyConManager: JoyConManager) {
        self.profileStore = profileStore
        self.joyConManager = joyConManager
    }

    /// Synthesize a short visible scroll burst so the user can verify CGEvent injection
    /// actually reaches the foreground app. If this does nothing, Accessibility is missing.
    func injectTestScroll() {
        for _ in 0..<10 {
            scroll.scrollPixels(direction: .down, magnitude: 30)
        }
        logDispatch("Test scroll injected (10 × 30px down)")
    }

    private func logDispatch(_ message: String) {
        let stamped = "\(Self.timeFormatter.string(from: Date())) — \(message)"
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.dispatchedActions.append(stamped)
            if self.dispatchedActions.count > self.dispatchedLogLimit {
                self.dispatchedActions.removeFirst(self.dispatchedActions.count - self.dispatchedLogLimit)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Lifecycle

    func start() {
        joyConManager.onInputEvent = { [weak self] deviceID, delta in
            self?.handleInputEvent(deviceID: deviceID, delta: delta)
        }
        startCursorTimerIfNeeded()
        if !AccessibilityPermission.isGranted() {
            logDispatch("WARNING: Accessibility not granted — CGEvent.post() will silently do nothing.")
        } else {
            logDispatch("Engine started, Accessibility OK.")
        }
    }

    func stop() {
        joyConManager.onInputEvent = nil
        cursorTimer?.cancel()
        cursorTimer = nil
        for (_, perDevice) in scrollTimers {
            for (_, timer) in perDevice {
                timer.cancel()
            }
        }
        scrollTimers.removeAll()
        // Release any still-held keys / mouse buttons to avoid sticky input.
        for (_, bindings) in heldKeys {
            for (_, binding) in bindings {
                keyboard.keyUp(key: binding.key, modifiers: binding.modifiers)
            }
        }
        heldKeys.removeAll()
        for (_, bindings) in heldMouseButtons {
            for (_, btn) in bindings {
                mouse.mouseUp(btn)
            }
        }
        heldMouseButtons.removeAll()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled == isEnabled { return }
        isEnabled = enabled
        if !enabled {
            // Release everything immediately when disabled.
            for (_, bindings) in heldKeys {
                for (_, binding) in bindings {
                    keyboard.keyUp(key: binding.key, modifiers: binding.modifiers)
                }
            }
            heldKeys.removeAll()
            for (_, bindings) in heldMouseButtons {
                for (_, btn) in bindings { mouse.mouseUp(btn) }
            }
            heldMouseButtons.removeAll()
            for (_, perDevice) in scrollTimers {
                for (_, timer) in perDevice { timer.cancel() }
            }
            scrollTimers.removeAll()
        }
    }

    // MARK: - Event handling

    private func handleInputEvent(deviceID: UUID, delta: JoyConInputStateDelta) {
        guard isEnabled else { return }
        let profile = profileStore.activeProfile

        for button in delta.pressed {
            buttonEventCount += 1
            let action = profile.action(for: button)
            logDispatch("Press \(button.displayName) → \(action.displayName)")
            handlePress(deviceID: deviceID, button: button, action: action)
        }
        for button in delta.released {
            handleRelease(deviceID: deviceID, button: button, action: profile.action(for: button))
        }
    }

    private func handlePress(deviceID: UUID, button: JoyConButton, action: ButtonAction) {
        switch action {
        case .none:
            break
        case .key(let binding):
            keyboard.keyDown(key: binding.key, modifiers: binding.modifiers)
            heldKeys[deviceID, default: [:]][button] = binding
        case .mouseClick(let m):
            mouse.mouseDown(m)
            heldMouseButtons[deviceID, default: [:]][button] = m
        case .scroll(let cfg):
            scroll.scrollPixels(direction: cfg.direction, magnitude: cfg.pixelsPerTick)
            if cfg.repeatWhileHeld {
                startScrollTimer(deviceID: deviceID, button: button, config: cfg)
            }
        }
    }

    private func handleRelease(deviceID: UUID, button: JoyConButton, action: ButtonAction) {
        switch action {
        case .none:
            break
        case .key(let binding):
            let held = heldKeys[deviceID]?[button] ?? binding
            keyboard.keyUp(key: held.key, modifiers: held.modifiers)
            heldKeys[deviceID]?[button] = nil
        case .mouseClick:
            if let m = heldMouseButtons[deviceID]?[button] {
                mouse.mouseUp(m)
                heldMouseButtons[deviceID]?[button] = nil
            }
        case .scroll:
            stopScrollTimer(deviceID: deviceID, button: button)
        }
    }

    // MARK: - Scroll repeat

    private func startScrollTimer(deviceID: UUID, button: JoyConButton, config: ScrollAction) {
        stopScrollTimer(deviceID: deviceID, button: button)

        // Ticking on a dedicated high-priority queue insulates scroll repeats from main-
        // thread contention caused by SwiftUI layout or HID storms.
        let timer = DispatchSource.makeTimerSource(queue: outputQueue)
        let interval = max(0.008, config.tickInterval)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        let direction = config.direction
        let magnitude = config.pixelsPerTick
        let scroller = scroll
        timer.setEventHandler {
            scroller.scrollPixels(direction: direction, magnitude: magnitude)
        }
        timer.resume()
        scrollTimers[deviceID, default: [:]][button] = timer
    }

    private func stopScrollTimer(deviceID: UUID, button: JoyConButton) {
        if let timer = scrollTimers[deviceID]?[button] {
            timer.cancel()
            scrollTimers[deviceID]?[button] = nil
        }
    }

    // MARK: - Stick → Cursor

    private func startCursorTimerIfNeeded() {
        guard cursorTimer == nil else { return }
        // Must stay on main: reads `joyConManager.currentStates`, which is mutated on main
        // by HID callbacks. Running the tick off-main would be a data race.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // ~120 Hz update — plenty smooth, very low CPU.
        let interval: TimeInterval = 1.0 / 120.0
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.tickCursor()
        }
        timer.resume()
        cursorTimer = timer
        lastCursorTickTime = CFAbsoluteTimeGetCurrent()
    }

    private func tickCursor() {
        guard isEnabled else { return }

        let profile = profileStore.activeProfile

        // Fast-path: if neither stick is mapped to the cursor, do nothing. Avoids per-tick
        // dict iteration and SIMD math when the active profile has no cursor binding.
        let hasCursorBinding: Bool
        switch (profile.leftStick, profile.rightStick) {
        case (.mouseCursor, _), (_, .mouseCursor):
            hasCursorBinding = true
        default:
            hasCursorBinding = false
        }
        if !hasCursorBinding { return }

        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(0.001, min(0.05, now - lastCursorTickTime))
        lastCursorTickTime = now

        var totalDX: Double = 0
        var totalDY: Double = 0

        // A single Joy-Con only has ONE physical stick, but the 0x30 HID report
        // has fields for *both* sticks. The unused stick's bytes are undefined and
        // often saturate to extreme values (e.g. (-1, -1)), which used to bleed
        // into cursor motion. We now pick the stick that actually exists on each
        // device based on its side.
        //
        // `currentStates` is the always-fresh (non-coalesced) mirror maintained by
        // JoyConManager — reading the published throttled copy here would cause
        // visible cursor stepping at the flush rate.
        for device in joyConManager.devices {
            guard let state = joyConManager.currentStates[device.identifier] else { continue }
            switch device.side {
            case .left:
                let (dx, dy) = cursorDelta(stick: state.leftStick, config: profile.leftStick, dt: dt)
                totalDX += dx; totalDY += dy
            case .right:
                let (dx, dy) = cursorDelta(stick: state.rightStick, config: profile.rightStick, dt: dt)
                totalDX += dx; totalDY += dy
            case .proController:
                let (dx1, dy1) = cursorDelta(stick: state.leftStick, config: profile.leftStick, dt: dt)
                let (dx2, dy2) = cursorDelta(stick: state.rightStick, config: profile.rightStick, dt: dt)
                totalDX += dx1 + dx2
                totalDY += dy1 + dy2
            case .unknown:
                break
            }
        }

        if totalDX != 0 || totalDY != 0 {
            mouse.moveCursor(byDX: CGFloat(totalDX), dy: CGFloat(totalDY))
            internalCursorMoveCount += 1
            // Publish at most every `cursorPublishInterval` so we don't rebuild the
            // popover's pipeline stats at 120 Hz.
            if now - lastCursorPublishTime >= cursorPublishInterval {
                lastCursorPublishTime = now
                cursorMoveCount = internalCursorMoveCount
            }
        }
    }

    private func cursorDelta(stick: SIMD2<Double>, config: StickAction, dt: Double) -> (Double, Double) {
        guard case .mouseCursor(let cfg) = config else { return (0, 0) }
        let magnitude = (stick.x * stick.x + stick.y * stick.y).squareRoot()
        if magnitude < cfg.deadzone { return (0, 0) }

        // Re-scale so that deadzone output is 0 and full deflection is 1.
        let adjustedMag = (magnitude - cfg.deadzone) / max(0.0001, 1.0 - cfg.deadzone)
        let curved = pow(min(1.0, max(0.0, adjustedMag)), cfg.responseCurve)
        let direction: SIMD2<Double>
        if magnitude > 0 {
            direction = SIMD2<Double>(stick.x / magnitude, stick.y / magnitude)
        } else {
            direction = .zero
        }

        let speed = cfg.pixelsPerSecond * curved * dt
        // Quartz coordinates are y-down — invert Y so pushing the stick up moves the cursor up.
        let yFactor: Double = cfg.invertY ? 1.0 : -1.0
        return (direction.x * speed, direction.y * speed * yFactor)
    }
}
