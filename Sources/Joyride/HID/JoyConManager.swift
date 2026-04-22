import Foundation
import IOKit
import IOKit.hid
import Combine

/// Dedicated observable for high-frequency live input data (per-device state and report counts).
///
/// Joy-Cons produce 60+ reports per second per device. If this were published directly from
/// `JoyConManager`, every SwiftUI view that observes the manager would rebuild its body at
/// HID rate — which saturates the main thread once the Mapping Editor (with dozens of Pickers)
/// is on screen. By keeping live state on a separate observable with coalesced flushes we:
///   1. Let the mapping Form observe only `JoyConManager` (device add/remove, low frequency).
///   2. Let the small "Live Input Preview" and device-row subviews observe `JoyConLiveInput`
///      at a bounded ~30 Hz refresh rate.
///
/// All mutating entry points must be called on the main thread.
final class JoyConLiveInput: ObservableObject {
    @Published private(set) var states: [UUID: JoyConInputState] = [:]
    @Published private(set) var reportCounts: [UUID: Int] = [:]

    /// Pending (unpublished) state. These are the authoritative, always-fresh values; the
    /// `@Published` counterparts above lag behind by up to `flushInterval` so SwiftUI
    /// doesn't rebuild on every single HID report.
    private var pendingStates: [UUID: JoyConInputState] = [:]
    private var pendingCounts: [UUID: Int] = [:]
    private var flushScheduled = false

    /// 30 Hz UI refresh rate. Fast enough that stick-visualiser dots look smooth, slow enough
    /// that the Form doesn't diff itself to death.
    private let flushInterval: TimeInterval = 1.0 / 30.0

    func record(deviceID: UUID, state: JoyConInputState, reportCount: Int) {
        pendingStates[deviceID] = state
        pendingCounts[deviceID] = reportCount
        scheduleFlush()
    }

    func forget(deviceID: UUID) {
        pendingStates.removeValue(forKey: deviceID)
        pendingCounts.removeValue(forKey: deviceID)
        // Publish removal immediately — device teardown is rare and users shouldn't see
        // ghost rows for a device that just unpaired.
        states.removeValue(forKey: deviceID)
        reportCounts.removeValue(forKey: deviceID)
    }

    func reset() {
        pendingStates.removeAll()
        pendingCounts.removeAll()
        states = [:]
        reportCounts = [:]
    }

    /// Sum of all report counts. Computed from the pending (up-to-date) counts so UI
    /// labels like "HID reports: 12345" tick up smoothly even between flushes.
    var totalReports: Int {
        pendingCounts.values.reduce(0, +)
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
            guard let self = self else { return }
            self.flushScheduled = false
            // Only publish if anything actually changed — avoids spurious rebuilds of the
            // live preview when a device is idle.
            if self.states != self.pendingStates { self.states = self.pendingStates }
            if self.reportCounts != self.pendingCounts { self.reportCounts = self.pendingCounts }
        }
    }
}

/// Owns the IOHIDManager and the set of live `JoyConDevice` instances. Publishes device
/// add/remove events at low frequency and delegates high-frequency state to `liveInput`.
final class JoyConManager: ObservableObject {
    @Published private(set) var devices: [JoyConDevice] = []
    @Published private(set) var isRunning: Bool = false
    /// Running log of significant HID events, exposed to the UI for diagnostics.
    @Published private(set) var diagnostics: [String] = []
    /// Set of physical sides of currently-connected controllers. Only re-published when
    /// the set actually changes, so views gating on "is a Right Joy-Con attached?" don't
    /// re-render on unrelated manager updates.
    @Published private(set) var connectedSides: Set<JoyConSide> = []

    /// High-frequency live input data. Updated internally at HID rate but `@Published`
    /// fields on this object are coalesced to ~30 Hz.
    let liveInput = JoyConLiveInput()

    /// Persistent per-device stick calibration. Owned here so device-match callbacks
    /// can synchronously look up the right calibration to hand to a fresh `JoyConDevice`.
    /// Exposed so UI views can observe calibration changes (e.g. to show "calibrated"
    /// state per device).
    let calibrationStore: CalibrationStore

    /// Invoked for every button press/release delta and every stick update, so the
    /// `MappingEngine` can react. Fires on the main queue.
    var onInputEvent: ((UUID, JoyConInputStateDelta) -> Void)?

    /// Fired on the main queue whenever we successfully recalibrate a device's stick
    /// center. The UI listens so it can show a transient "Calibrated" confirmation.
    var onCalibrationChanged: ((UUID) -> Void)?

    /// Always-fresh (non-coalesced) per-device state. Read by the cursor-move timer so
    /// mouse motion remains smooth at the timer's rate rather than stepping to the
    /// liveInput flush interval. Reads and writes both happen on the main thread.
    private(set) var currentStates: [UUID: JoyConInputState] = [:]

    private var hidManager: IOHIDManager?
    private var previousStates: [UUID: JoyConInputState] = [:]
    private var totalReportCounts: [UUID: Int] = [:]
    private let diagnosticsLimit: Int = 50

    init(calibrationStore: CalibrationStore = CalibrationStore()) {
        self.calibrationStore = calibrationStore
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        guard hidManager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = manager

        // We match on Nintendo VID + each known Joy-Con/Pro PID. We *also* add a
        // broad generic-desktop GamePad/Joystick match for Nintendo's VID so we pick
        // up variants (e.g. NSO controllers, revised Joy-Cons with different PIDs)
        // without needing to enumerate every product.
        let matching: [[String: Any]] = [
            [kIOHIDVendorIDKey: JoyConProtocol.vendorIDNintendo,
             kIOHIDProductIDKey: JoyConProtocol.productIDLeftJoyCon],
            [kIOHIDVendorIDKey: JoyConProtocol.vendorIDNintendo,
             kIOHIDProductIDKey: JoyConProtocol.productIDRightJoyCon],
            [kIOHIDVendorIDKey: JoyConProtocol.vendorIDNintendo,
             kIOHIDProductIDKey: JoyConProtocol.productIDProController],
            [kIOHIDVendorIDKey: JoyConProtocol.vendorIDNintendo,
             kIOHIDProductIDKey: JoyConProtocol.productIDChargingGrip],
            // Catch-all: any Nintendo Generic-Desktop GamePad.
            [kIOHIDVendorIDKey: JoyConProtocol.vendorIDNintendo,
             kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDVendorIDKey: JoyConProtocol.vendorIDNintendo,
             kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, JoyConManager.matchingCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, JoyConManager.removalCallback, context)

        // `.commonModes` ensures the callbacks keep firing while a menu / popover is
        // being tracked — otherwise reports stall whenever the user opens our menu bar.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            log("IOHIDManagerOpen failed (0x\(String(openResult, radix: 16))). Input Monitoring permission may be missing.")
        } else {
            log("HID manager started; scanning for Nintendo controllers.")
        }

        // Log how many devices we've picked up immediately after opening so users
        // can see discovery status right away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, let manager = self.hidManager else { return }
            let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>
            let count = set?.count ?? 0
            if count == 0 {
                self.log("No Nintendo HID devices found. Pair a Joy-Con via Bluetooth, or grant Input Monitoring if already paired.")
            } else {
                self.log("HID manager sees \(count) Nintendo device(s).")
            }
        }

        isRunning = true
    }

    func stop() {
        isRunning = false
        for device in devices {
            device.stop()
        }
        devices.removeAll()
        currentStates.removeAll()
        previousStates.removeAll()
        totalReportCounts.removeAll()
        liveInput.reset()
        updateConnectedSides()

        if let manager = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            hidManager = nil
        }
        log("HID manager stopped.")
    }

    /// Manually rescan. Closing/reopening forces IOKit to re-enumerate all matching devices,
    /// which is useful after granting Input Monitoring in System Settings.
    func restart() {
        log("Restarting HID manager.")
        stop()
        start()
    }

    // MARK: - Diagnostics

    private func log(_ message: String) {
        NSLog("Joyride: %@", message)
        let stamped = "\(Self.timestamp()) — \(message)"
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.diagnostics.append(stamped)
            if self.diagnostics.count > self.diagnosticsLimit {
                self.diagnostics.removeFirst(self.diagnostics.count - self.diagnosticsLimit)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func timestamp() -> String {
        return timeFormatter.string(from: Date())
    }

    // MARK: - IOKit callbacks

    private static let matchingCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context = context else { return }
        let manager = Unmanaged<JoyConManager>.fromOpaque(context).takeUnretainedValue()
        manager.handleDeviceMatch(device)
    }

    private static let removalCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context = context else { return }
        let manager = Unmanaged<JoyConManager>.fromOpaque(context).takeUnretainedValue()
        manager.handleDeviceRemoval(device)
    }

    private func handleDeviceMatch(_ hidDevice: IOHIDDevice) {
        let serial = IOHIDDeviceGetProperty(hidDevice, kIOHIDSerialNumberKey as CFString) as? String
        let product = IOHIDDeviceGetProperty(hidDevice, kIOHIDProductKey as CFString) as? String ?? "Unknown"
        let productID = (IOHIDDeviceGetProperty(hidDevice, kIOHIDProductIDKey as CFString) as? Int) ?? 0

        if let serial = serial, devices.contains(where: { $0.serialNumber == serial }) {
            log("Device re-matched (ignored duplicate): \(product) [\(serial)]")
            return
        }

        log("Device matched: \(product) (PID 0x\(String(productID, radix: 16))) serial=\(serial ?? "n/a")")

        let side = JoyConSide(productID: productID)
        let calibration = calibrationStore.calibration(serial: serial, side: side)
        let device = JoyConDevice(device: hidDevice, initialCalibration: calibration)
        device.onStateUpdate = { [weak self, weak device] state in
            guard let self = self, let device = device else { return }
            self.handleStateUpdate(deviceID: device.identifier, state: state)
        }
        device.onDisconnect = { [weak self, weak device] in
            guard let self = self, let device = device else { return }
            self.log("Device disconnected: \(device.side.displayName)")
            self.removeDevice(id: device.identifier)
        }
        device.onRawReport = { [weak self, weak device] reportID, bytes in
            guard let self = self, let device = device else { return }
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            self.log("\(device.side.displayName) raw 0x\(String(reportID, radix: 16)) [\(bytes.count)B]: \(hex)")
        }
        device.onReportIDFirstSeen = { [weak self, weak device] reportID, length in
            guard let self = self, let device = device else { return }
            let label: String
            switch reportID {
            case JoyConProtocol.InputReportID.standardFull.rawValue:
                label = "0x30 standard-full"
            case JoyConProtocol.InputReportID.subcommandReply.rawValue:
                label = "0x21 subcommand-reply"
            case JoyConProtocol.InputReportID.simpleHID.rawValue:
                label = "0x3F simple-HID (analog stick WILL NOT work in this mode)"
            default:
                label = "0x\(String(reportID, radix: 16))"
            }
            self.log("\(device.side.displayName): first \(label) report (\(length) bytes)")
        }

        devices.append(device)
        totalReportCounts[device.identifier] = 0
        updateConnectedSides()
        device.start()
    }

    private func handleDeviceRemoval(_ hidDevice: IOHIDDevice) {
        let serial = IOHIDDeviceGetProperty(hidDevice, kIOHIDSerialNumberKey as CFString) as? String
        if let match = devices.first(where: { $0.serialNumber == serial }) {
            removeDevice(id: match.identifier)
        }
    }

    private func removeDevice(id: UUID) {
        if let idx = devices.firstIndex(where: { $0.identifier == id }) {
            devices[idx].stop()
            devices.remove(at: idx)
        }
        currentStates.removeValue(forKey: id)
        previousStates.removeValue(forKey: id)
        totalReportCounts.removeValue(forKey: id)
        liveInput.forget(deviceID: id)
        updateConnectedSides()
    }

    private func updateConnectedSides() {
        let sides = Set(devices.map { $0.side })
        if sides != connectedSides {
            connectedSides = sides
        }
    }

    // MARK: - State diffing

    private func handleStateUpdate(deviceID: UUID, state: JoyConInputState) {
        let previous = previousStates[deviceID] ?? JoyConInputState()
        let delta = JoyConInputStateDelta(previous: previous, current: state)
        previousStates[deviceID] = state
        currentStates[deviceID] = state

        let newCount = (totalReportCounts[deviceID] ?? 0) + 1
        totalReportCounts[deviceID] = newCount
        if newCount == 1, let device = devices.first(where: { $0.identifier == deviceID }) {
            log("First input report from \(device.side.displayName) — device is live.")
        }

        // UI-facing (coalesced) update. Main-thread only; we're already on main here.
        liveInput.record(deviceID: deviceID, state: state, reportCount: newCount)

        // Engine callback fires on every actionable change (presses, releases, stick deltas).
        // The engine reads `currentStates` directly for cursor motion, so it never suffers
        // from the UI-side throttle.
        if delta.hasAnyChange {
            onInputEvent?(deviceID, delta)
        }
    }

    // MARK: - Calibration

    /// Sample the current raw stick readings on the given device and persist them as
    /// the new "center" for both sticks. The caller is expected to prompt the user to
    /// hold both sticks at rest before invoking this.
    ///
    /// Returns `true` if calibration was captured, `false` if we have no raw data yet
    /// (device only just connected, or it's in simple-HID mode where we don't emit
    /// raw 12-bit readings). On success, `onCalibrationChanged(deviceID)` fires.
    @discardableResult
    func calibrateCenter(deviceID: UUID) -> Bool {
        guard let device = devices.first(where: { $0.identifier == deviceID }),
              let state = currentStates[deviceID] else {
            return false
        }

        var calibration = device.currentCalibration

        // Only rewrite the side that actually produced a raw reading this tick. This
        // keeps a Left Joy-Con's unused right-stick calibration alone (and vice versa).
        var updated = false
        if let raw = state.rawLeftStick {
            calibration.leftStick.centerX = Int(raw.x)
            calibration.leftStick.centerY = Int(raw.y)
            updated = true
        }
        if let raw = state.rawRightStick {
            calibration.rightStick.centerX = Int(raw.x)
            calibration.rightStick.centerY = Int(raw.y)
            updated = true
        }
        guard updated else { return false }

        device.applyCalibration(calibration)
        calibrationStore.save(calibration, serial: device.serialNumber, side: device.side)

        let lx = state.rawLeftStick.map { "(\($0.x),\($0.y))" } ?? "—"
        let rx = state.rawRightStick.map { "(\($0.x),\($0.y))" } ?? "—"
        log("Calibrated \(device.side.displayName): left center=\(lx) right center=\(rx)")

        onCalibrationChanged?(deviceID)
        return true
    }

    /// Discard any user-captured calibration for this device and revert to the
    /// factory defaults. Calibration for other devices (same serial or same side
    /// elsewhere) is unaffected.
    func resetCalibration(deviceID: UUID) {
        guard let device = devices.first(where: { $0.identifier == deviceID }) else { return }
        calibrationStore.reset(serial: device.serialNumber, side: device.side)
        device.applyCalibration(.default)
        log("Reset calibration for \(device.side.displayName).")
        onCalibrationChanged?(deviceID)
    }

    /// Update the orientation (vertical / horizontal) for a single device and
    /// persist it. A no-op on form factors that don't have a sideways pose.
    ///
    /// The new orientation applies to the very next HID report — the user sees
    /// the cursor-motion fix instantly without needing to reconnect the
    /// controller. Persistence piggy-backs on `CalibrationStore`, so the
    /// setting survives relaunches and is keyed by serial like calibration.
    func setOrientation(deviceID: UUID, orientation: DeviceOrientation) {
        guard let device = devices.first(where: { $0.identifier == deviceID }) else { return }
        guard device.side.supportsHorizontalOrientation || orientation == .vertical else { return }

        device.setOrientation(orientation)

        var cal = device.currentCalibration
        cal.orientation = orientation
        calibrationStore.save(cal, serial: device.serialNumber, side: device.side)

        log("Orientation for \(device.side.displayName) → \(orientation.displayName)")
        onCalibrationChanged?(deviceID)
    }
}

/// Describes the change between two consecutive input states. Consumers like `MappingEngine`
/// use this to know when a button was pressed, released, or when a stick changed.
struct JoyConInputStateDelta {
    let previous: JoyConInputState
    let current: JoyConInputState

    var pressed: Set<JoyConButton> { current.pressedButtons.subtracting(previous.pressedButtons) }
    var released: Set<JoyConButton> { previous.pressedButtons.subtracting(current.pressedButtons) }
    var held: Set<JoyConButton> { current.pressedButtons.intersection(previous.pressedButtons) }

    var leftStickChanged: Bool { previous.leftStick != current.leftStick }
    var rightStickChanged: Bool { previous.rightStick != current.rightStick }

    var hasAnyChange: Bool {
        !pressed.isEmpty || !released.isEmpty || leftStickChanged || rightStickChanged
    }
}
