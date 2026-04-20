import Foundation

/// Parses raw HID reports coming off a Joy-Con into a `JoyConInputState`.
///
/// We primarily consume the standard full input report (ID 0x30), which provides
/// 12-bit analog stick resolution and a 3-byte button state. We also handle the
/// simple HID report (0x3F) as a safety net in case the device hasn't yet been
/// flipped to full mode.
struct HIDReportParser {
    let side: JoyConSide
    let leftStickCalibration: StickCalibration
    let rightStickCalibration: StickCalibration

    init(side: JoyConSide,
         leftStickCalibration: StickCalibration = .defaultLeft,
         rightStickCalibration: StickCalibration = .defaultRight) {
        self.side = side
        self.leftStickCalibration = leftStickCalibration
        self.rightStickCalibration = rightStickCalibration
    }

    /// Parse a report into a state, or return nil if the report is not one we understand.
    ///
    /// IOKit on macOS is inconsistent about whether the report buffer begins with the
    /// report ID: Apple's header claims it is stripped, but in practice for the Joy-Con
    /// HID stack it often is NOT. We detect this per-report by combining two signals:
    ///   - byte 0 equals the reported ID, AND
    ///   - the length matches the "with-ID" expected size for this report type.
    /// Either condition alone is not reliable (timer can briefly equal 0x30; lengths
    /// vary by firmware), but together they're robust.
    func parse(reportID: UInt8, data: UnsafePointer<UInt8>, length: Int) -> JoyConInputState? {
        guard length > 0 else { return nil }

        // Heuristic: for the Joy-Con standard full report, the canonical length is
        // 49 bytes with report ID, 48 bytes without. Simple HID 0x3F is 12 bytes
        // with ID, 11 without. If the length is in the "with-ID" column AND the
        // first byte matches the ID, treat the first byte as the report ID and skip.
        let idIncluded: Bool
        switch reportID {
        case JoyConProtocol.InputReportID.standardFull.rawValue,
             JoyConProtocol.InputReportID.subcommandReply.rawValue:
            idIncluded = (length >= 49) && (data[0] == reportID)
        case JoyConProtocol.InputReportID.simpleHID.rawValue:
            idIncluded = (length >= 12) && (data[0] == reportID)
        default:
            idIncluded = data[0] == reportID
        }

        let payload: UnsafePointer<UInt8> = idIncluded ? data.advanced(by: 1) : data
        let payloadLength = idIncluded ? (length - 1) : length

        switch reportID {
        case JoyConProtocol.InputReportID.standardFull.rawValue,
             JoyConProtocol.InputReportID.subcommandReply.rawValue:
            return parseStandardFull(data: payload, length: payloadLength)
        case JoyConProtocol.InputReportID.simpleHID.rawValue:
            return parseSimpleHID(data: payload, length: payloadLength)
        default:
            return nil
        }
    }

    // MARK: - Standard Full Report (0x30 / 0x21)

    private func parseStandardFull(data: UnsafePointer<UInt8>, length: Int) -> JoyConInputState? {
        // Byte layout when the report ID has been stripped by IOKit callback:
        //   [0]    timer
        //   [1]    battery/connection
        //   [2]    right buttons  (Y, X, B, A, SR, SL, R, ZR)
        //   [3]    shared buttons (-, +, RS, LS, Home, Capture, --, ChargingGrip)
        //   [4]    left buttons   (Down, Up, Right, Left, SR, SL, L, ZL)
        //   [5..7] left stick (little-endian 12-bit X, 12-bit Y packed across 3 bytes)
        //   [8..10] right stick (same layout)
        guard length >= 11 else { return nil }

        var state = JoyConInputState()
        state.timestamp = Date().timeIntervalSinceReferenceDate
        state.batteryLevel = (data[1] >> 4) & 0x0F

        let rightBtns = data[2]
        let sharedBtns = data[3]
        let leftBtns = data[4]

        // Only trust the button bytes that correspond to the physical Joy-Con side.
        // On a single Joy-Con the other side's byte is undefined and will register
        // phantom presses if we parse it. Pro Controllers populate both.
        let readRight = (side == .right) || (side == .proController) || (side == .unknown)
        let readLeft = (side == .left) || (side == .proController) || (side == .unknown)

        if readRight {
            if rightBtns & 0x01 != 0 { state.pressedButtons.insert(.y) }
            if rightBtns & 0x02 != 0 { state.pressedButtons.insert(.x) }
            if rightBtns & 0x04 != 0 { state.pressedButtons.insert(.b) }
            if rightBtns & 0x08 != 0 { state.pressedButtons.insert(.a) }
            if rightBtns & 0x10 != 0 { state.pressedButtons.insert(.srRight) }
            if rightBtns & 0x20 != 0 { state.pressedButtons.insert(.slRight) }
            if rightBtns & 0x40 != 0 { state.pressedButtons.insert(.r) }
            if rightBtns & 0x80 != 0 { state.pressedButtons.insert(.zr) }
        }

        // Shared byte: each bit only applies to the side that physically owns that button.
        //   - minus / capture live on the Left Joy-Con.
        //   - plus / home live on the Right Joy-Con.
        //   - the stick-click bits only fire on the side whose stick is actually present.
        if readLeft {
            if sharedBtns & 0x01 != 0 { state.pressedButtons.insert(.minus) }
            if sharedBtns & 0x08 != 0 { state.pressedButtons.insert(.leftStickClick) }
            if sharedBtns & 0x20 != 0 { state.pressedButtons.insert(.capture) }
        }
        if readRight {
            if sharedBtns & 0x02 != 0 { state.pressedButtons.insert(.plus) }
            if sharedBtns & 0x04 != 0 { state.pressedButtons.insert(.rightStickClick) }
            if sharedBtns & 0x10 != 0 { state.pressedButtons.insert(.home) }
        }

        if readLeft {
            if leftBtns & 0x01 != 0 { state.pressedButtons.insert(.dpadDown) }
            if leftBtns & 0x02 != 0 { state.pressedButtons.insert(.dpadUp) }
            if leftBtns & 0x04 != 0 { state.pressedButtons.insert(.dpadRight) }
            if leftBtns & 0x08 != 0 { state.pressedButtons.insert(.dpadLeft) }
            if leftBtns & 0x10 != 0 { state.pressedButtons.insert(.srLeft) }
            if leftBtns & 0x20 != 0 { state.pressedButtons.insert(.slLeft) }
            if leftBtns & 0x40 != 0 { state.pressedButtons.insert(.l) }
            if leftBtns & 0x80 != 0 { state.pressedButtons.insert(.zl) }
        }

        // Packed stick decode: 3 bytes per stick, little-endian nibbles.
        //   x = b0 | ((b1 & 0x0F) << 8)
        //   y = (b1 >> 4) | (b2 << 4)
        if readLeft {
            let lx = UInt16(data[5]) | (UInt16(data[6] & 0x0F) << 8)
            let ly = (UInt16(data[6]) >> 4) | (UInt16(data[7]) << 4)
            state.leftStick = leftStickCalibration.normalize(x: lx, y: ly)
        }
        if readRight {
            let rx = UInt16(data[8]) | (UInt16(data[9] & 0x0F) << 8)
            let ry = (UInt16(data[9]) >> 4) | (UInt16(data[10]) << 4)
            state.rightStick = rightStickCalibration.normalize(x: rx, y: ry)
        }

        return state
    }

    // MARK: - Simple HID Report (0x3F)

    private func parseSimpleHID(data: UnsafePointer<UInt8>, length: Int) -> JoyConInputState? {
        // Simple HID report 0x3F. Layout (after report ID stripped):
        //   [0]      Buttons 1
        //   [1]      Buttons 2
        //   [2]      HAT (D-pad)
        //   [3..4]   Left stick X  (16-bit LE, center ~ 0x8000)
        //   [5..6]   Left stick Y
        //   [7..8]   Right stick X
        //   [9..10]  Right stick Y
        guard length >= 11 else { return nil }

        var state = JoyConInputState()
        state.timestamp = Date().timeIntervalSinceReferenceDate

        let b0 = data[0]
        let b1 = data[1]

        if side == .right {
            if b0 & 0x01 != 0 { state.pressedButtons.insert(.a) }
            if b0 & 0x02 != 0 { state.pressedButtons.insert(.x) }
            if b0 & 0x04 != 0 { state.pressedButtons.insert(.b) }
            if b0 & 0x08 != 0 { state.pressedButtons.insert(.y) }
            if b0 & 0x10 != 0 { state.pressedButtons.insert(.slRight) }
            if b0 & 0x20 != 0 { state.pressedButtons.insert(.srRight) }
            if b0 & 0x40 != 0 { state.pressedButtons.insert(.r) }
            if b0 & 0x80 != 0 { state.pressedButtons.insert(.zr) }
            if b1 & 0x02 != 0 { state.pressedButtons.insert(.plus) }
            if b1 & 0x08 != 0 { state.pressedButtons.insert(.rightStickClick) }
            if b1 & 0x10 != 0 { state.pressedButtons.insert(.home) }
        } else if side == .left {
            if b0 & 0x01 != 0 { state.pressedButtons.insert(.dpadDown) }
            if b0 & 0x02 != 0 { state.pressedButtons.insert(.dpadRight) }
            if b0 & 0x04 != 0 { state.pressedButtons.insert(.dpadLeft) }
            if b0 & 0x08 != 0 { state.pressedButtons.insert(.dpadUp) }
            if b0 & 0x10 != 0 { state.pressedButtons.insert(.slLeft) }
            if b0 & 0x20 != 0 { state.pressedButtons.insert(.srLeft) }
            if b0 & 0x40 != 0 { state.pressedButtons.insert(.l) }
            if b0 & 0x80 != 0 { state.pressedButtons.insert(.zl) }
            if b1 & 0x01 != 0 { state.pressedButtons.insert(.minus) }
            if b1 & 0x04 != 0 { state.pressedButtons.insert(.leftStickClick) }
            if b1 & 0x20 != 0 { state.pressedButtons.insert(.capture) }
        }

        // 16-bit little-endian sticks, center ~ 0x8000, range ~ 0x8000.
        func stick(_ offset: Int) -> SIMD2<Double> {
            let x = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            let y = UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8)
            let nx = (Double(x) - 32768.0) / 32768.0
            let ny = (Double(y) - 32768.0) / 32768.0
            return SIMD2<Double>(max(-1.0, min(1.0, nx)), max(-1.0, min(1.0, -ny)))
        }

        state.leftStick = stick(3)
        state.rightStick = stick(7)

        return state
    }
}

/// Analog stick calibration. Real Joy-Cons ship per-unit calibration in SPI flash,
/// but for scroll/cursor use the factory defaults are adequate. Advanced users can
/// tune these via Settings; for now we bake in reasonable defaults.
struct StickCalibration {
    let centerX: Int
    let centerY: Int
    let rangeX: Int
    let rangeY: Int

    static let defaultLeft = StickCalibration(centerX: 2100, centerY: 2100, rangeX: 1500, rangeY: 1500)
    static let defaultRight = StickCalibration(centerX: 2100, centerY: 2100, rangeX: 1500, rangeY: 1500)

    /// Convert a raw 12-bit stick reading into a normalized [-1, 1] pair.
    /// The Y axis is inverted so that positive = up (matches screen coordinates where
    /// we invert again when moving the cursor).
    func normalize(x: UInt16, y: UInt16) -> SIMD2<Double> {
        let nx = clampUnit(Double(Int(x) - centerX) / Double(rangeX))
        let ny = clampUnit(Double(Int(y) - centerY) / Double(rangeY))
        return SIMD2<Double>(nx, ny)
    }

    private func clampUnit(_ v: Double) -> Double {
        if v.isNaN { return 0 }
        return max(-1.0, min(1.0, v))
    }
}
