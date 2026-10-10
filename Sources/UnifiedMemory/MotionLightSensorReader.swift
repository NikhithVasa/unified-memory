import Foundation
import NativeHardware

// These angles describe the acceleration vector in HID sensor coordinates, not
// an undocumented chassis-axis transform. Motion can include nongravitational acceleration.
enum MotionLightDecoder {
    static func vectorAngles(x: Double, y: Double, z: Double) -> (pitch: Double, roll: Double)? {
        guard x.isFinite, y.isFinite, z.isFinite else { return nil }
        let scale = max(abs(x), max(abs(y), abs(z)))
        guard scale > 0 else { return nil }
        let nx = x / scale, ny = y / scale, nz = z / scale
        return (atan2(-nx, hypot(ny, nz)) * 180 / .pi, atan2(ny, nz) * 180 / .pi)
    }
}

private struct MotionLightChannel {
    let index: Int
    let id: String
    let name: String
    let kind: UInt32
}

private struct MotionLightHIDChannel {
    let index: Int
    let id: String
    let name: String
    let usage: UInt32
    let restricted: Bool
}

// Actor serialization owns synchronous reads. The separate motion stream owns
// one native thread/run loop, a locked latest-sample cache and joined teardown.
private final class MotionLightConnection: @unchecked Sendable {
    let native: OpaquePointer?
    let hid: OpaquePointer?
    let motion: OpaquePointer?
    let motionStatus: Int32
    let nativeStatus: Int32
    let hidStatus: Int32
    let channels: [MotionLightChannel]
    let hidChannels: [MotionLightHIDChannel]

    init() {
        var nativeStatus: Int32 = 0, hidStatus: Int32 = 0
        native = UMMotionLightClientCreate(&nativeStatus)
        hid = UMHIDSensorClientCreate(&hidStatus)
        var motionStatus: Int32 = 0
        motion = UMHIDMotionStreamCreate(&motionStatus)
        self.motionStatus = motionStatus
        self.nativeStatus = nativeStatus
        self.hidStatus = hidStatus
        var channels: [MotionLightChannel] = []
        if let native {
            channels.reserveCapacity(UMMotionLightClientGetCount(native))
            for index in 0..<UMMotionLightClientGetCount(native) {
                guard let name = UMMotionLightClientGetName(native, index),
                      let id = UMMotionLightClientGetID(native, index) else { continue }
                channels.append(MotionLightChannel(index: index, id: String(cString: id), name: String(cString: name),
                                                   kind: UMMotionLightClientGetKind(native, index)))
            }
        }
        self.channels = channels
        var hidChannels: [MotionLightHIDChannel] = []
        if let hid {
            for index in 0..<UMHIDSensorClientGetSensorCount(hid) {
                let page = UMHIDSensorClientGetUsagePage(hid, index), usage = UMHIDSensorClientGetUsage(hid, index)
                guard page == 0xff00, [UInt32(3), 4, 9].contains(usage),
                      let name = UMHIDSensorClientGetSensorName(hid, index),
                      let id = UMHIDSensorClientGetSensorID(hid, index) else { continue }
                hidChannels.append(MotionLightHIDChannel(index: index, id: String(cString: id), name: String(cString: name),
                                                         usage: usage, restricted: UMHIDSensorClientIsMotionRestricted(hid, index)))
            }
        }
        self.hidChannels = hidChannels
    }

    deinit {
        if let motion { UMHIDMotionStreamDestroy(motion) }
        if let native { UMMotionLightClientDestroy(native) }
        if let hid { UMHIDSensorClientDestroy(hid) }
    }
}

actor MotionLightSensorReader {
    private var connection: MotionLightConnection?
    private let axes = ["X", "Y", "Z"]
    private let ambientFields: [UInt32] = [12 << 16, (12 << 16) + 1, (12 << 16) + 2, (12 << 16) + 3, (12 << 16) + 4]

    func read() -> [HardwareSensorReading] {
        let connection: MotionLightConnection
        if let existing = self.connection { connection = existing }
        else {
            connection = MotionLightConnection()
            self.connection = connection
        }
        let timestamp = Date()
        var readings: [HardwareSensorReading] = []
        readings.reserveCapacity(connection.channels.count + connection.hidChannels.count * 7 + 4)
        for channel in connection.channels {
            let kind = channel.kind
            let category: HardwareSensorCategory = kind == UInt32(UMMotionLightLidAngle) ? .motion : kind == UInt32(UMMotionLightOpaqueService) ? .diagnostics : .display
            let source: String
            let detail: String
            let unit: String
            switch kind {
            case UInt32(UMMotionLightLidAngle):
                source = "Public IOHIDDevice input report"
                detail = "Sensor page 0x20 / device orientation 0x8A. Descriptor verified: Tilt X 0x047F, report ID 1, nine bits, logical/physical 0–360. Read-only polling; no reporting-state or power-state writes."
                unit = "°"
            case UInt32(UMMotionLightDisplayBrightness):
                source = "DisplayServicesGetBrightness / IODisplayGetFloatParameter"
                detail = "Actual display brightness setting, normalized API 0–1 × 100; not panel luminance in nits. Private DisplayServices has a read-only public IODisplay fallback."
                unit = "%"
            case UInt32(UMMotionLightKeyboardBrightness):
                source = "CoreBrightness KeyboardBrightnessClient"
                detail = "Built-in keyboard ID enumerated by copyKeyboardBacklightIDs; brightnessForKeyboard: float ABI validated at runtime. Actual backlight brightness setting 0–1 × 100; no keyboard reports or setting writes."
                unit = "%"
            case UInt32(UMMotionLightAmbientLux):
                source = "AppleSPUVD6286 CurrentLux"
                detail = "Native ambient-light driver CurrentLux property; units explicitly named by the driver. Changes with ambient illumination."
                unit = "lx"
            default:
                source = "AppleSPUHIDDevice IORegistry metadata"
                detail = "Detected vendor-defined SPU service. Report payload semantics and physical purpose are not established; payload is deliberately not opened or decoded."
                unit = ""
            }
            var value = Double.nan
            let result = connection.native.map { UMMotionLightClientRead($0, channel.index, &value) } ?? connection.nativeStatus
            let status: HardwareSensorStatus
            if kind == UInt32(UMMotionLightOpaqueService) { status = .present("Opaque sensor-processor service; metadata only, not a physical scalar measurement.") }
            else if result == 0 && value.isFinite { status = .available }
            else { status = .unavailable("Native read failed or API/descriptor unsupported (IOReturn \(Self.hex(result))). No value substituted.") }
            readings.append(HardwareSensorReading(id: "motion-light:\(channel.id)", name: channel.name, category: category,
                                                   value: result == 0 && value.isFinite ? value : nil, unit: unit, status: status,
                                                   source: source, detail: detail, timestamp: timestamp))
        }
        if let hid = connection.hid {
            for channel in connection.hidChannels {
                if channel.usage == 4 {
                    var values = [Int64](repeating: 0, count: 5)
                    let available = ambientFields.withUnsafeBufferPointer { fields in
                        values.withUnsafeMutableBufferPointer { buffer in
                            UMHIDSensorClientReadIntegers(hid, channel.index, 12, fields.baseAddress!, fields.count, buffer.baseAddress!)
                        }
                    }
                    for index in 0..<5 {
                        let name = index == 0 ? "Ambient light level (HID)" : "Ambient light raw channel \(index - 1)"
                        readings.append(HardwareSensorReading(
                            id: "motion-light:\(channel.id):ambient:\(index)", name: name,
                            category: index == 0 ? .display : .diagnostics,
                            value: available ? Double(values[index]) : nil, unit: index == 0 ? "lx" : "raw",
                            status: available ? (index == 0 ? .available : .unclassified("Native raw channel; wavelength, gain and physical conversion are not exposed.")) : .unavailable("macOS returned no ambient-light event."),
                            source: "IOHID ambient-light event 12", detail: "Integer level field0 and raw channels fields1–4 per Apple IOHIDEventTypes.h. On this M5, event level agrees with the driver's explicit CurrentLux property; raw channels are not guessed as lux or color temperatures.",
                            timestamp: timestamp, metadata: ["service": channel.name, "field": String(ambientFields[index])]))
                    }
                    continue
                }
                let accel = channel.usage == 3
                let type: UInt32 = accel ? 13 : 20
                var values = [Double](repeating: .nan, count: 3)
                var sampleTime = Double.nan, age = Double.nan
                let motionResult = connection.motion.map { motion in
                    channel.id.withCString { id in
                        values.withUnsafeMutableBufferPointer { buffer in
                            UMHIDMotionStreamRead(motion, id, buffer.baseAddress!, &sampleTime, &age)
                        }
                    }
                } ?? connection.motionStatus
                let available = motionResult == 0 && sampleTime.isFinite && values.allSatisfy(\.isFinite)
                let sampleTimestamp = sampleTime.isFinite ? Date(timeIntervalSince1970: sampleTime) : timestamp
                let unavailable = "No fresh process-owned motion event (IOReturn \(Self.hex(motionResult)), age \(age.isFinite ? String(format: "%.2f s", age) : "unknown")). Rate-controlled client matches only built-in accelerometer/gyro and requests a 200 ms interval; no global reporting-state/power-state writes. Private monitor permissions or initial reporting may prevent delivery."
                let label = accel ? "Accelerometer" : "Gyroscope"
                for axis in 0..<3 {
                    readings.append(HardwareSensorReading(id: "motion-light:\(channel.id):axis:\(axis)", name: "\(label) \(axes[axis])",
                                                           category: .motion, value: available ? values[axis] : nil, unit: "raw",
                                                           status: available ? .unclassified("Native axis scalar; this service's physical units and chassis-axis mapping are not established.") : .unavailable(unavailable),
                                                           source: "IOHID motion event \(type), rate-controlled subscription", detail: "Actual axis fields0–2 and LP64 double getter per Apple's event ABI. Process-owned interval restored when client is released. Native fixed-point is already decoded by IOHID; physical units and sensor mounting are not guessed. Events older than 1 s become unavailable.",
                                                           timestamp: sampleTimestamp, metadata: ["service": channel.name, "motionRestrictedService": String(channel.restricted), "eventAgeSeconds": age.isFinite ? String(age) : "unknown"]))
                }
                if accel {
                    let angles = available ? MotionLightDecoder.vectorAngles(x: values[0], y: values[1], z: values[2]) : nil
                    for (name, value) in [("pitch", angles?.pitch), ("roll", angles?.roll)] {
                        readings.append(HardwareSensorReading(id: "motion-light:\(channel.id):vector:\(name)", name: "Acceleration-vector \(name) (sensor frame)", category: .motion,
                                                               value: value, unit: "°", status: value != nil ? .unclassified("Derived acceleration-vector direction, not calibrated laptop attitude; chassis orientation and nongravitational acceleration are not resolved.") : .unavailable(available ? "No nonzero finite acceleration vector." : unavailable),
                                                               source: "Derived from native accelerometer axes", detail: "pitch=atan2(−x,hypot(y,z)); roll=atan2(y,z). Common scalar normalization cancels; no guessed sensor mounting transform.", timestamp: sampleTimestamp))
                    }
                }
            }
        }
        let expected: [(UInt32, String, HardwareSensorCategory)] = [
            (UInt32(UMMotionLightLidAngle), "Lid angle", .motion),
            (UInt32(UMMotionLightDisplayBrightness), "Display brightness", .display),
            (UInt32(UMMotionLightKeyboardBrightness), "Keyboard backlight brightness", .display),
            (UInt32(UMMotionLightAmbientLux), "Ambient illuminance", .display)
        ]
        for (kind, name, category) in expected where !connection.channels.contains(where: { $0.kind == kind }) {
            readings.append(HardwareSensorReading(id: "motion-light:missing:\(kind)", name: name, category: category,
                                                   status: .unavailable("Native service or compatible read-only API not exposed (discovery status \(Self.hex(connection.nativeStatus)))."),
                                                   source: "Native motion/light discovery", timestamp: timestamp))
        }
        for usage in [UInt32(3), 9] where !connection.hidChannels.contains(where: { $0.usage == usage }) {
            readings.append(HardwareSensorReading(id: "motion-light:missing:hid:\(usage)", name: usage == 3 ? "Accelerometer / tilt" : "Gyroscope", category: .motion,
                                                   status: .unavailable("No compatible built-in HID service (discovery status \(Self.hex(connection.hidStatus)))."),
                                                   source: "IOHID built-in sensor discovery", timestamp: timestamp))
        }
        return readings
    }

    private static func hex(_ status: Int32) -> String { String(format: "0x%08X", UInt32(bitPattern: status)) }
}
