import Foundation
import IOKit
import IOKit.hid
import Combine

/// Owns the IOHIDManager and the set of live `JoyConDevice` instances. Publishes device
/// add/remove events and latest input state to SwiftUI.
final class JoyConManager: ObservableObject {
    @Published private(set) var devices: [JoyConDevice] = []
    @Published private(set) var latestStates: [UUID: JoyConInputState] = [:]
    @Published private(set) var isRunning: Bool = false
    /// Running log of significant HID events, exposed to the UI for diagnostics.
    @Published private(set) var diagnostics: [String] = []
    /// Count of input reports received per device — lets the UI show "silent" devices.
    @Published private(set) var reportCounts: [UUID: Int] = [:]

    /// Invoked for every button press/release delta and every stick update, so the
    /// `MappingEngine` can react. Fires on the main queue.
    var onInputEvent: ((UUID, JoyConInputStateDelta) -> Void)?

    private var hidManager: IOHIDManager?
    private var previousStates: [UUID: JoyConInputState] = [:]
    private let diagnosticsLimit: Int = 50

    init() {}

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
        latestStates.removeAll()
        previousStates.removeAll()
        reportCounts.removeAll()

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
        NSLog("Lovejoy: %@", message)
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

        let device = JoyConDevice(device: hidDevice)
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

        devices.append(device)
        reportCounts[device.identifier] = 0
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
        latestStates.removeValue(forKey: id)
        previousStates.removeValue(forKey: id)
        reportCounts.removeValue(forKey: id)
    }

    // MARK: - State diffing

    private func handleStateUpdate(deviceID: UUID, state: JoyConInputState) {
        let previous = previousStates[deviceID] ?? JoyConInputState()
        let delta = JoyConInputStateDelta(previous: previous, current: state)
        previousStates[deviceID] = state
        latestStates[deviceID] = state

        let newCount = (reportCounts[deviceID] ?? 0) + 1
        reportCounts[deviceID] = newCount
        if newCount == 1, let device = devices.first(where: { $0.identifier == deviceID }) {
            log("First input report from \(device.side.displayName) — device is live.")
        }

        if delta.hasAnyChange {
            onInputEvent?(deviceID, delta)
        }
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
