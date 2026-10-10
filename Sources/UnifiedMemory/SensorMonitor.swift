import Combine
import Foundation

@MainActor
final class SensorMonitor: ObservableObject {
    @Published private(set) var readings: [HardwareSensorReading] = []
    @Published private(set) var lastUpdated: Date?
    private var power: [HardwareSensorReading] = []
    private var motion: [HardwareSensorReading] = []
    private var system: [HardwareSensorReading] = []
    private var thermal: [HardwareSensorReading] = []
    private let powerReader = HardwarePowerSensorReader()
    private let motionReader = MotionLightSensorReader()
    private let systemReader = SystemSensorReader()
    private var hardwareTask: Task<Void, Never>?
    private var motionTask: Task<Void, Never>?
    private var visible = false
    private var paused = false
    private var interval = 1

    deinit {
        hardwareTask?.cancel()
        motionTask?.cancel()
    }

    func configure(visible: Bool, paused: Bool, interval: Int) {
        guard self.visible != visible || self.paused != paused || self.interval != interval else { return }
        self.visible = visible
        self.paused = paused
        self.interval = interval
        hardwareTask?.cancel()
        motionTask?.cancel()
        hardwareTask = nil
        motionTask = nil
        guard !paused else { return }
        startMotionSampling()
    }

    func refresh() {
        hardwareTask?.cancel()
        let powerReader = powerReader
        let systemReader = systemReader
        let motionReader = motionReader
        let sampleMotion = paused || !visible
        hardwareTask = Task { [weak self] in
            async let power = powerReader.read()
            async let system = systemReader.read()
            let nextPower = await power
            let nextSystem = await system
            let nextMotion = sampleMotion ? await motionReader.read() : nil
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.power = nextPower
            self.system = nextSystem
            if let nextMotion { self.motion = nextMotion }
            self.publish()
        }
    }

    func updateTemperature(_ snapshot: TemperatureSnapshot?, error: String?) {
        if let snapshot {
            thermal = snapshot.sensors.map { sensor in
                let status: HardwareSensorStatus
                let category: HardwareSensorCategory
                switch sensor.status {
                case .available:
                    status = .available
                    category = .temperature
                case .unavailable(let reason):
                    status = .unavailable(reason)
                    category = .temperature
                case .excluded(let reason):
                    status = .unclassified(reason)
                    category = .diagnostics
                }
                return HardwareSensorReading(id: sensor.id, name: sensor.name, category: category,
                    value: sensor.celsius, unit: sensor.celsius != nil ? "°C" : "", status: status,
                    source: sensor.id.hasPrefix("smc:") ? "AppleSMC" : "IOHID temperature event",
                    detail: "Internal hardware channel. Product/key names are reported as supplied by macOS; no CPU-core or chassis-temperature identity is guessed.",
                    timestamp: snapshot.timestamp)
            }
        }
        thermal.removeAll { $0.id == "temperature:reader-status" }
        if let error {
            thermal.append(HardwareSensorReading(id: "temperature:reader-status", name: "Temperature reader status", category: .temperature,
                status: .unavailable(error), source: "Native sensor interfaces"))
        }
        publish()
    }

    private func startMotionSampling() {
        guard visible else { return }
        let reader = motionReader
        motionTask = Task { [weak self] in
            while !Task.isCancelled {
                let next = await reader.read()
                guard !Task.isCancelled else { return }
                self?.motion = next
                self?.publish()
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch { return }
            }
        }
    }

    private func publish() {
        var merged: [String: HardwareSensorReading] = [:]
        merged.reserveCapacity(power.count + motion.count + system.count + thermal.count)
        for sensor in power + motion + system { merged[sensor.id] = sensor }
        for sensor in thermal {
            if !sensor.status.isAvailable, let raw = merged[sensor.id], raw.value != nil {
                let knownTemperature = sensor.category == .temperature && raw.status.isAvailable && raw.unit == "°C"
                merged[sensor.id] = HardwareSensorReading(id: sensor.id, name: sensor.name,
                    category: knownTemperature ? .temperature : .diagnostics,
                    value: raw.value, unit: knownTemperature ? raw.unit : "raw", textValue: raw.textValue,
                    status: knownTemperature ? .available : (raw.status.isAvailable ? sensor.status : raw.status), source: raw.source,
                    detail: [sensor.status.explanation, raw.detail].compactMap { $0 }.joined(separator: " "),
                    timestamp: raw.timestamp, metadata: raw.metadata)
            } else {
                merged[sensor.id] = sensor
            }
        }
        readings = merged.values.sorted {
            if $0.category != $1.category {
                return HardwareSensorCategory.allCases.firstIndex(of: $0.category)! < HardwareSensorCategory.allCases.firstIndex(of: $1.category)!
            }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        lastUpdated = readings.map(\.timestamp).max()
    }
}
