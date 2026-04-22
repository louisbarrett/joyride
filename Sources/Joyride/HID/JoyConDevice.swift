import Foundation
import IOKit
import IOKit.hid

/// Represents a single connected Joy-Con (or Pro Controller). Owns its IOHIDDevice reference,
/// performs the subcommand handshake required to get useful input reports, and emits parsed
/// state deltas via the `onStateUpdate` callback.
final class JoyConDevice {
    let identifier: UUID
    let side: JoyConSide
    let serialNumber: String?
    let productID: Int
    let vendorID: Int

    /// Invoked on the main queue whenever we have a freshly parsed state.
    var onStateUpdate: ((JoyConInputState) -> Void)?

    /// Invoked on the main queue when the device disconnects.
    var onDisconnect: (() -> Void)?

    private let device: IOHIDDevice
    private var parser: HIDReportParser
    /// How the user is holding this Joy-Con. Applied to the parsed input state
    /// before the rest of the app sees it — see `applyOrientation(to:)`. Mutated
    /// on the main thread, read from the HID callback which also runs on main,
    /// so no synchronization is needed beyond that invariant.
    private var orientationState: DeviceOrientation
    private var inputReportBuffer: UnsafeMutablePointer<UInt8>
    private let inputReportBufferSize = JoyConProtocol.maxInputReportSize
    private var packetCounter: UInt8 = 0
    private var isClosing: Bool = false
    private var handshakeComplete: Bool = false
    private var retainedSelf: Unmanaged<JoyConDevice>?

    /// Count of reports received. Used to decide whether to dump raw bytes for
    /// early-stage diagnostics (we dump only the first 5 to avoid spamming).
    private var rawDumpCount: Int = 0
    /// Callback for raw-byte diagnostics. Set by JoyConManager so we can push into
    /// its shared diagnostics log (which is already surfaced in the UI).
    var onRawReport: ((UInt8, [UInt8]) -> Void)?

    /// Per-reportID running count of how many reports of each type we've
    /// ever seen on this device. Used to log a one-time breadcrumb the first
    /// time an unexpected report-ID shows up (e.g. if the device flips from
    /// 0x30 to 0x3F behind our back), without ever sending subcommands in
    /// response — writing to the device is the thing that seems to upset the
    /// BT link, so this diagnostic stays strictly read-only.
    private var reportIDCounts: [UInt8: Int] = [:]
    /// Callback invoked the first time each distinct report-ID is observed.
    /// Hook the diagnostics log into this to track mode changes without
    /// flooding it on every frame.
    var onReportIDFirstSeen: ((UInt8, Int) -> Void)?

    init(device: IOHIDDevice, initialCalibration: DeviceCalibration = .default) {
        self.device = device
        self.identifier = UUID()

        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        let vendorID = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String

        self.productID = productID
        self.vendorID = vendorID
        self.serialNumber = serial
        let side = JoyConSide(productID: productID)
        self.side = side
        self.parser = HIDReportParser(
            side: side,
            leftStickCalibration: initialCalibration.leftStick,
            rightStickCalibration: initialCalibration.rightStick
        )
        // Only honour persisted horizontal orientation on form factors that
        // physically have a sideways pose — a stray .horizontal on a Pro
        // Controller would silently misrotate both sticks for no benefit.
        self.orientationState = side.supportsHorizontalOrientation
            ? initialCalibration.orientation
            : .vertical
        self.inputReportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputReportBufferSize)
        self.inputReportBuffer.initialize(repeating: 0, count: inputReportBufferSize)
    }

    /// Replace the parser's calibration at runtime. Must be called on the main thread
    /// since the parser is read from there by the HID input callback.
    func applyCalibration(_ calibration: DeviceCalibration) {
        parser.leftStickCalibration = calibration.leftStick
        parser.rightStickCalibration = calibration.rightStick
        orientationState = side.supportsHorizontalOrientation
            ? calibration.orientation
            : .vertical
    }

    /// Change just the orientation without touching stick calibration. Same
    /// threading rules as `applyCalibration`.
    func setOrientation(_ orientation: DeviceOrientation) {
        guard side.supportsHorizontalOrientation || orientation == .vertical else { return }
        orientationState = orientation
    }

    /// Current orientation, for UI display.
    var orientation: DeviceOrientation { orientationState }

    /// Snapshot of the current calibration + orientation, for UI display and persistence.
    var currentCalibration: DeviceCalibration {
        DeviceCalibration(
            leftStick: parser.leftStickCalibration,
            rightStick: parser.rightStickCalibration,
            orientation: orientationState
        )
    }

    deinit {
        inputReportBuffer.deinitialize(count: inputReportBufferSize)
        inputReportBuffer.deallocate()
    }

    // MARK: - Lifecycle

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        retainedSelf = Unmanaged.passUnretained(self)

        // Open explicitly. `IOHIDManagerOpen` is supposed to open all matching devices but
        // on recent macOS versions it sometimes doesn't — so we belt-and-braces open here.
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            NSLog("Joyride: IOHIDDeviceOpen(%@) failed: 0x%x", side.displayName, openResult)
        }

        IOHIDDeviceRegisterInputReportCallback(
            device,
            inputReportBuffer,
            inputReportBufferSize,
            JoyConDevice.inputReportCallback,
            context
        )

        IOHIDDeviceRegisterRemovalCallback(
            device,
            JoyConDevice.removalCallback,
            context
        )

        // The IOHIDManager already scheduled this device on the main runloop when we opened it.
        // Kick off the handshake asynchronously so IO has a chance to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.performHandshake()
        }
    }

    func stop() {
        isClosing = true
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        retainedSelf = nil
    }

    private func performHandshake() {
        guard !isClosing else { return }

        // 1. Enable vibration (required on some firmware to accept further subcommands reliably).
        let vibOK = sendSubcommand(.enableVibration, arguments: [0x01])

        // 2. Switch into standard full input report mode (0x30).
        let modeOK = sendSubcommand(.setInputReportMode, arguments: [JoyConProtocol.InputReportMode.standardFull.rawValue])

        // 3. Light the first player LED so the user can see we're connected.
        let ledOK = sendSubcommand(.setPlayerLights, arguments: [0x01])

        if !vibOK || !modeOK || !ledOK {
            NSLog("Joyride: handshake partial (%@): vibration=%@, mode=%@, led=%@",
                  side.displayName,
                  vibOK ? "ok" : "FAIL",
                  modeOK ? "ok" : "FAIL",
                  ledOK ? "ok" : "FAIL")
        }

        handshakeComplete = true
    }

    // MARK: - Subcommands

    /// Build and send an output report containing a subcommand.
    @discardableResult
    private func sendSubcommand(_ subcommand: JoyConProtocol.Subcommand, arguments: [UInt8]) -> Bool {
        var payload = [UInt8]()
        payload.reserveCapacity(10 + arguments.count)
        payload.append(packetCounter & 0x0F)
        payload.append(contentsOf: JoyConProtocol.neutralRumble)
        payload.append(subcommand.rawValue)
        payload.append(contentsOf: arguments)
        packetCounter = packetCounter &+ 1

        return payload.withUnsafeBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            let result = IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(JoyConProtocol.OutputReportID.rumbleAndSubcommand.rawValue),
                base,
                buf.count
            )
            return result == kIOReturnSuccess
        }
    }

    // MARK: - Callbacks (C function pointers, because IOKit is a C API)

    private static let inputReportCallback: IOHIDReportCallback = { context, _, _, _, reportID, report, reportLength in
        guard let context = context else { return }
        let device = Unmanaged<JoyConDevice>.fromOpaque(context).takeUnretainedValue()
        device.handleInputReport(reportID: UInt8(truncatingIfNeeded: reportID), report: report, length: reportLength)
    }

    private static let removalCallback: IOHIDCallback = { context, _, _ in
        guard let context = context else { return }
        let device = Unmanaged<JoyConDevice>.fromOpaque(context).takeUnretainedValue()
        device.handleRemoval()
    }

    private func handleInputReport(reportID: UInt8, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard !isClosing, length > 0 else { return }

        // Dump the first handful of raw reports so the diagnostics log shows exactly
        // what we're receiving. This is the only way to debug parser-offset bugs
        // reliably across macOS versions where IOKit's report-ID stripping is
        // inconsistent.
        if rawDumpCount < 5 {
            rawDumpCount += 1
            let previewLen = min(Int(length), 16)
            var bytes = [UInt8](repeating: 0, count: previewLen)
            for i in 0..<previewLen { bytes[i] = report[i] }
            let cb = onRawReport
            let capturedID = reportID
            if Thread.isMainThread {
                cb?(capturedID, bytes)
            } else {
                DispatchQueue.main.async { cb?(capturedID, bytes) }
            }
        }

        // Pure observer: bump the per-reportID counter and, the first time a
        // given reportID is ever seen on this device, ping the diagnostics
        // log. No subcommands get sent from here — writing to the device
        // while it's mid-negotiation with the OS is what previously caused
        // the rumble-and-drop loop.
        let existing = reportIDCounts[reportID] ?? 0
        let nextCount = existing + 1
        reportIDCounts[reportID] = nextCount
        if existing == 0 {
            let cb = onReportIDFirstSeen
            let capturedID = reportID
            if Thread.isMainThread {
                cb?(capturedID, Int(length))
            } else {
                DispatchQueue.main.async { cb?(capturedID, Int(length)) }
            }
        }

        guard let parsed = parser.parse(reportID: reportID, data: report, length: length) else { return }
        let state = applyOrientation(to: parsed)
        // Callback runs on whatever runloop IOHIDManager was scheduled on. We schedule on main,
        // so we're already on main here — but guard anyway for safety.
        if Thread.isMainThread {
            onStateUpdate?(state)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onStateUpdate?(state)
            }
        }
    }

    /// Re-expresses a parsed `JoyConInputState` from the controller's native
    /// frame into the user's frame based on how the Joy-Con is physically held.
    ///
    /// Two separate transforms happen in `.horizontal`:
    ///
    /// **Stick rotation.** The HID stick fields report in the controller's own
    /// coordinate system; when the user rotates the controller 90° to hold it
    /// sideways, the stick's axes rotate with it. The app's cursor-mapping math
    /// assumes a canonical "stick up means cursor up" convention, so we rotate
    /// the vector back into that convention here. The rotation direction
    /// depends on which side of the pair is connected — the Switch's sideways
    /// pose has Left Joy-Cons rotated CCW and Right Joy-Cons CW, which works
    /// out to opposite matrix rotations on the reported vector.
    ///
    /// **Side-rail trigger aliasing.** When held sideways, the Joy-Con's
    /// rear triggers (`L` / `ZL` / `R` / `ZR`) are awkward to reach, while the
    /// rail buttons (`SL` / `SR`) naturally sit under the user's index fingers.
    /// Rather than force the user to rebind, we insert a "virtual" press of
    /// the corresponding rear trigger whenever a rail button is held. The
    /// original `slLeft` / `srLeft` / `slRight` / `srRight` stay in the set,
    /// so explicit bindings on them keep working alongside the aliases.
    private func applyOrientation(to state: JoyConInputState) -> JoyConInputState {
        guard orientationState == .horizontal else { return state }

        var out = state

        switch side {
        case .left:
            // Left Joy-Con sideways = controller rotated 90° CCW in the user's
            // frame. Transform stick reading (x, y) → (-y, x) to undo the
            // rotation so "user-up" = stick-pushed-up.
            let v = state.leftStick
            out.leftStick = SIMD2<Double>(-v.y, v.x)
            if state.pressedButtons.contains(.slLeft)  { out.pressedButtons.insert(.l) }
            if state.pressedButtons.contains(.srLeft)  { out.pressedButtons.insert(.zl) }
        case .right:
            // Right Joy-Con sideways = rotated 90° CW in user's frame.
            // Transform stick reading (x, y) → (y, -x).
            let v = state.rightStick
            out.rightStick = SIMD2<Double>(v.y, -v.x)
            if state.pressedButtons.contains(.slRight) { out.pressedButtons.insert(.zr) }
            if state.pressedButtons.contains(.srRight) { out.pressedButtons.insert(.r)  }
        case .proController, .unknown:
            // No canonical sideways pose — orientation is ignored at init time
            // for these, so we should never actually reach here. Left as a
            // no-op for safety.
            break
        }

        return out
    }

    private func handleRemoval() {
        isClosing = true
        if Thread.isMainThread {
            onDisconnect?()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onDisconnect?()
            }
        }
    }
}
