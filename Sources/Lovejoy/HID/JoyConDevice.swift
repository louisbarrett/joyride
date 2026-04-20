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

    init(device: IOHIDDevice) {
        self.device = device
        self.identifier = UUID()

        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        let vendorID = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String

        self.productID = productID
        self.vendorID = vendorID
        self.serialNumber = serial
        self.side = JoyConSide(productID: productID)
        self.parser = HIDReportParser(side: JoyConSide(productID: productID))
        self.inputReportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputReportBufferSize)
        self.inputReportBuffer.initialize(repeating: 0, count: inputReportBufferSize)
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
            NSLog("Lovejoy: IOHIDDeviceOpen(%@) failed: 0x%x", side.displayName, openResult)
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
            NSLog("Lovejoy: handshake partial (%@): vibration=%@, mode=%@, led=%@",
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

        guard let state = parser.parse(reportID: reportID, data: report, length: length) else { return }
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
