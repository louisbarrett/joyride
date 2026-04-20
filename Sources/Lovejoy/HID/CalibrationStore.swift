import Foundation
import Combine

/// Per-axis stick calibration applied by `HIDReportParser` when converting raw
/// 12-bit stick readings into the normalized `[-1, 1]` values the rest of the
/// app operates on. Real Joy-Cons ship per-unit calibration in SPI flash, but
/// those values drift over time and reading them over HID is finicky, so we let
/// the user recalibrate the center on demand from the UI.
///
/// Only `centerX` / `centerY` are changed by the "Calibrate center" flow — the
/// `rangeX` / `rangeY` stay at the factory defaults, which are tuned to give a
/// useful deflection before saturation without needing the user to rotate the
/// stick through its full travel.
struct StickCalibration: Codable, Equatable, Hashable {
    var centerX: Int
    var centerY: Int
    var rangeX: Int
    var rangeY: Int

    static let defaultLeft = StickCalibration(centerX: 2100, centerY: 2100, rangeX: 1500, rangeY: 1500)
    static let defaultRight = StickCalibration(centerX: 2100, centerY: 2100, rangeX: 1500, rangeY: 1500)

    /// Convert a raw 12-bit stick reading into a normalized [-1, 1] pair.
    /// The Y axis stays in the stick's native orientation (positive = up for the
    /// physical stick); downstream code (cursor motion, UI) decides how to map it.
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

/// Paired calibration for both sticks on a controller. Stored per-device so a
/// Left Joy-Con and a Right Joy-Con get distinct calibration even though they
/// only each have one physical stick — the unused side sticks to the default.
struct DeviceCalibration: Codable, Equatable, Hashable {
    var leftStick: StickCalibration
    var rightStick: StickCalibration

    static let `default` = DeviceCalibration(
        leftStick: .defaultLeft,
        rightStick: .defaultRight
    )
}

/// Persists user-captured stick calibration to
/// `~/Library/Application Support/Lovejoy/calibration.json`.
///
/// Two lookup layers:
///   1. Per serial number — stable across relaunches for the same physical
///      Joy-Con. This is the authoritative key when we have it.
///   2. Per side (left / right / pro) — fallback when a device has no serial
///      or when a freshly-paired same-side Joy-Con should pick up a sensible
///      starting point before the user calibrates it explicitly.
///
/// Writes are debounced on a utility queue so rapid saves (e.g. live-tweaking
/// raw values during calibration capture) never hit disk more than once per
/// `persistDelay`. `flushPendingWrites()` is called from `applicationWillTerminate`.
final class CalibrationStore: ObservableObject {
    struct PersistedData: Codable {
        var perSerial: [String: DeviceCalibration]
        /// Keyed by `JoyConSide.rawValue` for stable JSON.
        var perSide: [String: DeviceCalibration]
    }

    @Published private(set) var perSerial: [String: DeviceCalibration] = [:]
    @Published private(set) var perSide: [JoyConSide: DeviceCalibration] = [:]

    private let fileURL: URL
    private let io = DispatchQueue(label: "com.lovejoy.calibrationstore", qos: .utility)

    private let persistDelay: TimeInterval = 0.3
    private var pendingPersist: DispatchWorkItem?
    private let pendingLock = NSLock()

    init(storageDirectory: URL? = nil) {
        let base = storageDirectory ?? ProfileStore.defaultStorageDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("calibration.json")
        load()
    }

    // MARK: - Lookup

    /// Returns the best-available calibration for this device: exact serial match
    /// first, then same-side default, then factory default.
    func calibration(serial: String?, side: JoyConSide) -> DeviceCalibration {
        if let serial = serial, let exact = perSerial[serial] { return exact }
        if let sideDefault = perSide[side] { return sideDefault }
        return .default
    }

    // MARK: - Updates

    /// Persist a calibration for this device. Writes to *both* the serial map
    /// (if known) and the side map, so a future controller on the same side
    /// inherits these values until it gets calibrated in turn.
    func save(_ calibration: DeviceCalibration, serial: String?, side: JoyConSide) {
        if let serial = serial, !serial.isEmpty {
            perSerial[serial] = calibration
        }
        perSide[side] = calibration
        schedulePersist()
    }

    /// Forget calibration for this device and its side, reverting to factory defaults.
    func reset(serial: String?, side: JoyConSide) {
        if let serial = serial, !serial.isEmpty {
            perSerial.removeValue(forKey: serial)
        }
        perSide.removeValue(forKey: side)
        schedulePersist()
    }

    /// Synchronously write any pending changes. Invoked from `applicationWillTerminate`.
    func flushPendingWrites() {
        pendingLock.lock()
        let item = pendingPersist
        pendingPersist = nil
        pendingLock.unlock()
        item?.cancel()
        persistNow()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PersistedData.self, from: data) else {
            return
        }
        perSerial = decoded.perSerial
        var sideDict: [JoyConSide: DeviceCalibration] = [:]
        for (key, value) in decoded.perSide {
            if let side = JoyConSide(rawValue: key) {
                sideDict[side] = value
            }
        }
        perSide = sideDict
    }

    private func schedulePersist() {
        pendingLock.lock()
        pendingPersist?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.persistNow()
        }
        pendingPersist = item
        pendingLock.unlock()
        io.asyncAfter(deadline: .now() + persistDelay, execute: item)
    }

    private func persistNow() {
        let serialSnap = perSerial
        let sideSnap = Dictionary(uniqueKeysWithValues: perSide.map { ($0.key.rawValue, $0.value) })
        let snapshot = PersistedData(perSerial: serialSnap, perSide: sideSnap)
        let url = fileURL
        io.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("Lovejoy: failed to persist calibration: %@", error.localizedDescription)
            }
        }
    }
}
