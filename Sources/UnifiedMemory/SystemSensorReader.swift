import CoreWLAN
import Darwin
import Foundation
import IOKit

private struct GPUService: Sendable {
    let service: io_service_t
    let id: UInt64
    let name: String
}

private final class SystemSensorResources: @unchecked Sendable {
    let host = mach_host_self()
    let gpus: [GPUService]

    init() {
        var devices: [GPUService] = []
        var seen: Set<UInt64> = []
        for className in ["IOAccelerator", "IOGPU"] {
            var iterator: io_iterator_t = 0
            guard let matching = IOServiceMatching(className),
                  IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { continue }
            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 { break }
                var id: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(service, &id)
                guard seen.insert(id).inserted else { IOObjectRelease(service); continue }
                let model = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                devices.append(GPUService(service: service, id: id, name: model as? String ?? "GPU"))
            }
            IOObjectRelease(iterator)
        }
        gpus = devices
    }

    deinit {
        for gpu in gpus { IOObjectRelease(gpu.service) }
        mach_port_deallocate(mach_task_self_, host)
    }
}

actor SystemSensorReader {
    private let resources = SystemSensorResources()
    private var previousCPU: (UInt32, UInt32, UInt32, UInt32)?
    private let volume = URL(fileURLWithPath: "/")

    func read() -> [HardwareSensorReading] {
        let now = Date()
        var readings: [HardwareSensorReading] = []
        readings.reserveCapacity(30)
        let info = ProcessInfo.processInfo
        let thermalText: String
        switch info.thermalState {
        case .nominal: thermalText = "Nominal"
        case .fair: thermalText = "Fair"
        case .serious: thermalText = "Serious"
        case .critical: thermalText = "Critical"
        @unknown default: thermalText = "Unknown"
        }
        readings.append(HardwareSensorReading(id: "system:thermal-pressure", name: "Thermal pressure", category: .system,
            value: Double(info.thermalState.rawValue), textValue: thermalText, source: "ProcessInfo.thermalState",
            detail: "macOS thermal-pressure status, not a Celsius temperature. Numeric state is 0 nominal, 1 fair, 2 serious, 3 critical.", timestamp: now))
        readings.append(HardwareSensorReading(id: "system:cpu-count", name: "Logical CPU cores", category: .system,
            value: Double(info.processorCount), unit: "cores", source: "ProcessInfo.processorCount", timestamp: now))
        readings.append(HardwareSensorReading(id: "system:active-cpu-count", name: "Active CPU cores", category: .system,
            value: Double(info.activeProcessorCount), unit: "cores", source: "ProcessInfo.activeProcessorCount", timestamp: now))
        readings.append(HardwareSensorReading(id: "system:uptime", name: "System uptime", category: .system,
            value: info.systemUptime, unit: "s", source: "ProcessInfo.systemUptime", detail: "Native system uptime counter.", timestamp: now))
        for (key, name) in [("hw.l1icachesize", "CPU L1 instruction cache"), ("hw.l1dcachesize", "CPU L1 data cache"), ("hw.l2cachesize", "CPU L2 cache"), ("hw.l3cachesize", "CPU L3 cache")] {
            var bytes: UInt64 = 0
            var size = MemoryLayout<UInt64>.size
            let result = sysctlbyname(key, &bytes, &size, nil, 0)
            readings.append(HardwareSensorReading(id: "system:cache:\(key)", name: name, category: .system,
                value: result == 0 && bytes > 0 ? Double(bytes) / 1_048_576 : nil, unit: "MiB",
                status: result == 0 && bytes > 0 ? .available : .unavailable("This cache size is not exposed separately by macOS."),
                source: "sysctl \(key)", detail: "CPU hardware cache, not additional app-allocatable RAM. The reported size is not multiplied by core count.", timestamp: now))
        }

        var cpu = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(resources.host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if cpuResult == KERN_SUCCESS {
            let current = cpu.cpu_ticks
            if let previousCPU, let percent = CPUCounterUsage.percent(previous: previousCPU, current: current) {
                readings.append(HardwareSensorReading(id: "system:cpu-usage", name: "CPU utilization", category: .system,
                    value: percent, unit: "%", source: "Mach HOST_CPU_LOAD_INFO", detail: "Busy tick delta across all CPUs since the previous sample.", timestamp: now))
            } else {
                readings.append(HardwareSensorReading(id: "system:cpu-usage", name: "CPU utilization", category: .system,
                    status: .present("Waiting for the next CPU tick delta."), source: "Mach HOST_CPU_LOAD_INFO", timestamp: now))
            }
            previousCPU = current
        } else {
            readings.append(HardwareSensorReading(id: "system:cpu-usage", name: "CPU utilization", category: .system,
                status: .unavailable("Mach CPU counter read failed (code \(cpuResult))."), source: "Mach HOST_CPU_LOAD_INFO", timestamp: now))
        }

        for gpu in resources.gpus {
            let prefix = "system:gpu:\(gpu.id)"
            if let cores = property(gpu.service, "gpu-core-count") as? NSNumber {
                readings.append(HardwareSensorReading(id: "\(prefix):cores", name: "\(gpu.name) GPU cores", category: .system,
                    value: cores.doubleValue, unit: "cores", source: "IORegistry gpu-core-count", timestamp: now))
            }
            guard let stats = property(gpu.service, "PerformanceStatistics") as? [String: Any] else {
                readings.append(HardwareSensorReading(id: "\(prefix):stats", name: "\(gpu.name) GPU telemetry", category: .system,
                    status: .unavailable("The GPU driver did not publish PerformanceStatistics."), source: "IORegistry", timestamp: now))
                continue
            }
            for key in stats.keys.sorted() {
                guard let value = stats[key] as? NSNumber, value.doubleValue.isFinite else { continue }
                let percent = key.contains("Utilization %")
                let bytes = key.lowercased().contains("memory") || key.lowercased().contains("bytes") || key.contains("PB Size")
                let category: HardwareSensorCategory = percent || bytes ? .system : .diagnostics
                let unit = percent ? "%" : bytes ? "GiB" : "raw"
                readings.append(HardwareSensorReading(id: "\(prefix):\(key)", name: "GPU · \(key)", category: category,
                    value: bytes ? value.doubleValue / 1_073_741_824 : value.doubleValue, unit: unit,
                    status: category == .diagnostics ? .unclassified("Driver counter units are not established; shown as the reported raw number.") : .available,
                    source: "IORegistry PerformanceStatistics", detail: "\(gpu.name). Driver counters are not separate dedicated VRAM; this Mac uses unified memory.",
                    timestamp: now, metadata: ["Driver field": key, "Registry ID": String(gpu.id), "Raw number": value.stringValue]))
            }
        }
        if resources.gpus.isEmpty {
            readings.append(HardwareSensorReading(id: "system:gpu", name: "GPU telemetry", category: .system,
                status: .unavailable("No readable IOAccelerator/IOGPU service was discovered."), source: "IORegistry", timestamp: now))
        }

        do {
            let values = try volume.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            if let total = values.volumeTotalCapacity {
                readings.append(HardwareSensorReading(id: "system:disk-total", name: "Boot volume capacity", category: .system,
                    value: Double(total) / 1_073_741_824, unit: "GiB", source: "Filesystem volume capacity", detail: "APFS volume/pool capacity reported for /, not a separate physical-sensor measurement.", timestamp: now))
            }
            if let free = values.volumeAvailableCapacity {
                readings.append(HardwareSensorReading(id: "system:disk-free", name: "Boot volume free space", category: .system,
                    value: Double(free) / 1_073_741_824, unit: "GiB", source: "Filesystem available capacity", detail: "Free space reported for /. APFS volumes may share the same pool.", timestamp: now))
            }
            if let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity, total > 0 {
                readings.append(HardwareSensorReading(id: "system:disk-used-percent", name: "Boot volume used space", category: .system,
                    value: Double(total - free) / Double(total) * 100, unit: "%", source: "Filesystem capacity counters", timestamp: now))
            }
        } catch {
            readings.append(HardwareSensorReading(id: "system:disk-free", name: "Boot volume free space", category: .system,
                status: .unavailable(error.localizedDescription), source: "Filesystem", timestamp: now))
        }

        if let wifi = CWWiFiClient.shared().interface() {
            let name = wifi.interfaceName ?? "Wi-Fi"
            let powered = wifi.powerOn()
            readings.append(HardwareSensorReading(id: "system:wifi:power", name: "Wi-Fi radio", category: .system,
                value: powered ? 1 : 0, textValue: powered ? "On" : "Off", source: "CoreWLAN", timestamp: now, metadata: ["Interface": name]))
            let rssi = wifi.rssiValue()
            readings.append(HardwareSensorReading(id: "system:wifi:rssi", name: "Wi-Fi signal strength", category: .system,
                value: powered && rssi != 0 ? Double(rssi) : nil, unit: "dBm",
                status: powered && rssi != 0 ? .available : .unavailable("No current RSSI is exposed; radio may be off or unassociated."),
                source: "CoreWLAN rssiValue", detail: "No SSID/location information or network traffic is collected.", timestamp: now))
            let noise = wifi.noiseMeasurement()
            readings.append(HardwareSensorReading(id: "system:wifi:noise", name: "Wi-Fi noise", category: .system,
                value: powered && noise != 0 ? Double(noise) : nil, unit: "dBm",
                status: powered && noise != 0 ? .available : .unavailable("No current radio-noise value is exposed."), source: "CoreWLAN noiseMeasurement", timestamp: now))
            let rate = wifi.transmitRate()
            readings.append(HardwareSensorReading(id: "system:wifi:rate", name: "Wi-Fi link rate", category: .system,
                value: powered && rate > 0 ? rate : nil, unit: "Mbps", status: powered && rate > 0 ? .available : .unavailable("No associated transmit-link rate is exposed."),
                source: "CoreWLAN transmitRate", detail: "Reported link speed, not measured download throughput.", timestamp: now))
        } else {
            readings.append(HardwareSensorReading(id: "system:wifi:power", name: "Wi-Fi radio", category: .system,
                status: .unavailable("No CoreWLAN interface is accessible."), source: "CoreWLAN", timestamp: now))
        }

        if let matching = IOServiceMatching("AppleMesaShim") {
            let touchID = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            if touchID != 0 {
                IOObjectRelease(touchID)
                readings.append(HardwareSensorReading(id: "system:touch-id", name: "Touch ID hardware", category: .system,
                    status: .present("Biometric hardware is present. Biometric payloads are deliberately not accessed."), source: "IORegistry service presence", timestamp: now))
            }
        }
        return readings
    }

    private func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

enum CPUCounterUsage {
    static func percent(previous: (UInt32, UInt32, UInt32, UInt32), current: (UInt32, UInt32, UInt32, UInt32)) -> Double? {
        let user = UInt64(current.0 &- previous.0)
        let system = UInt64(current.1 &- previous.1)
        let idle = UInt64(current.2 &- previous.2)
        let nice = UInt64(current.3 &- previous.3)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return Double(user + system + nice) / Double(total) * 100
    }
}
