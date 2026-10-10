import Foundation
import NativeTemperature

struct TemperatureReading: Identifiable, Sendable {
    let id: String
    let name: String
    let celsius: Double
}

enum TemperatureSensorAvailability: Sendable {
    case available
    case unavailable(String)
    case excluded(String)
}

struct TemperatureSensorState: Identifiable, Sendable {
    let id: String
    let name: String
    let celsius: Double?
    let status: TemperatureSensorAvailability
}

struct TemperatureSnapshot: Sendable {
    let timestamp: Date
    let readings: [TemperatureReading]
    let sensors: [TemperatureSensorState]

    var hottest: TemperatureReading? {
        readings.max { $0.celsius < $1.celsius }
    }
}

enum TemperatureReadError: Error, LocalizedError {
    case interfacesUnavailable
    case sensorsUnavailable
    case allocationFailed
    case noCurrentReadings(TemperatureSnapshot)
    case nativeDiscoveryFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .interfacesUnavailable:
            "macOS did not allow access to the native temperature interfaces, or those interfaces are no longer available."
        case .sensorsUnavailable:
            "macOS exposed no supported physical internal temperature sensors."
        case .allocationFailed:
            "The native temperature reader could not allocate its sensor storage."
        case .noCurrentReadings:
            "No current physical internal temperature readings are available from macOS."
        case .nativeDiscoveryFailed(let code):
            "Native temperature sensor discovery failed (code \(code))."
        }
    }

    var snapshot: TemperatureSnapshot? {
        if case .noCurrentReadings(let snapshot) = self { return snapshot }
        return nil
    }
}

// Temperature events are already Celsius. Do not scale them, synthesize averages,
// or use ProcessInfo.thermalState as a numerical temperature.
enum TemperatureDecoder {
    static func isPhysicalSensor(name: String) -> Bool {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !label.isEmpty else { return false }
        return label != "tcal" && !label.hasSuffix(" tcal") &&
            !label.contains("calibration") && !label.contains("dummy") &&
            !label.contains("sentinel")
    }

    static func isUsableCelsius(_ value: Double) -> Bool {
        // Zero/negative PMU channels include disconnected-sensor sentinels on
        // this Mac. Outside this usable laptop-internal range, fail honestly.
        value.isFinite && value > 0 && value <= 150
    }

    static func exclusionReason(name: String, physical: Bool) -> String? {
        if !isPhysicalSensor(name: name) {
            return "Calibration or dummy channel; not a physical temperature reading."
        }
        if !physical {
            return "Unclassified SMC channel; it may be virtual and is not established as a physical temperature sensor."
        }
        return nil
    }

    static func sensorState(id: String, name: String, value: Double?, exclusionReason: String?) -> TemperatureSensorState {
        let status: TemperatureSensorAvailability
        var celsius: Double?
        if let exclusionReason {
            status = .excluded(exclusionReason)
        } else if let value, isUsableCelsius(value) {
            celsius = value
            status = .available
        } else if let value {
            status = .unavailable("Invalid or disconnected sensor value (\(value)); not a usable internal temperature.")
        } else {
            status = .unavailable("The native sensor read failed or macOS returned no temperature event.")
        }
        return TemperatureSensorState(id: id, name: name, celsius: celsius, status: status)
    }
}

private struct TemperatureSensorDescriptor {
    let index: Int
    let id: String
    let name: String
    let exclusionReason: String?
}

// Only TemperatureReader accesses this connection. The annotation allows its
// final release/deinit on any executor; it does not make native reads concurrent.
// Native destruction owns all retained CF objects, the dlopen handle and SMC port.
private final class NativeTemperatureConnection: @unchecked Sendable {
    let handle: OpaquePointer
    let sensors: [TemperatureSensorDescriptor]

    init() throws {
        var status: Int32 = 0
        guard let handle = UMTemperatureClientCreate(&status) else {
            switch status {
            case 1: throw TemperatureReadError.interfacesUnavailable
            case 2: throw TemperatureReadError.sensorsUnavailable
            case 3: throw TemperatureReadError.allocationFailed
            default: throw TemperatureReadError.nativeDiscoveryFailed(status)
            }
        }
        self.handle = handle
        let count = UMTemperatureClientGetSensorCount(handle)
        var sensors: [TemperatureSensorDescriptor] = []
        sensors.reserveCapacity(count)
        for index in 0..<count {
            guard let nativeName = UMTemperatureClientGetSensorName(handle, index),
                  let nativeID = UMTemperatureClientGetSensorID(handle, index) else { continue }
            let name = String(cString: nativeName)
            sensors.append(TemperatureSensorDescriptor(
                index: index,
                id: String(cString: nativeID),
                name: name,
                exclusionReason: TemperatureDecoder.exclusionReason(
                    name: name, physical: UMTemperatureClientIsPhysicalSensor(handle, index)
                )
            ))
        }
        self.sensors = sensors
    }

    deinit {
        UMTemperatureClientDestroy(handle)
    }
}

actor TemperatureReader {
    private var connection: NativeTemperatureConnection?

    func read() throws -> TemperatureSnapshot {
        try Task.checkCancellation()
        let connection: NativeTemperatureConnection
        if let existing = self.connection {
            connection = existing
        } else {
            connection = try NativeTemperatureConnection()
            self.connection = connection
        }
        var readings: [TemperatureReading] = []
        readings.reserveCapacity(connection.sensors.count)
        var states: [TemperatureSensorState] = []
        states.reserveCapacity(connection.sensors.count)
        for sensor in connection.sensors {
            // A native call cannot be interrupted mid-call. Checking on both
            // sides ensures cancellation never publishes a partial snapshot.
            try Task.checkCancellation()
            var value = 0.0
            let shouldRead = sensor.exclusionReason == nil
            let available = shouldRead && UMTemperatureClientReadSensor(connection.handle, sensor.index, &value)
            try Task.checkCancellation()
            let state = TemperatureDecoder.sensorState(
                id: sensor.id, name: sensor.name, value: available ? value : nil, exclusionReason: sensor.exclusionReason
            )
            states.append(state)
            if let celsius = state.celsius {
                readings.append(TemperatureReading(id: sensor.id, name: sensor.name, celsius: celsius))
            }
        }
        try Task.checkCancellation()
        let snapshot = TemperatureSnapshot(timestamp: Date(), readings: readings, sensors: states)
        guard !readings.isEmpty else {
            // Re-discover next sample after sleep or service replacement instead
            // of retaining a permanently dead set of services or stale values.
            self.connection = nil
            throw TemperatureReadError.noCurrentReadings(snapshot)
        }
        return snapshot
    }
}
