import Darwin
import Foundation

struct MemorySnapshot: Sendable {
    let timestamp: Date
    let total: UInt64
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    let cached: UInt64
    let free: UInt64
    let swapUsed: UInt64?
    let swapTotal: UInt64?
    let pressureLevel: Int32?

    init(
        timestamp: Date,
        total: UInt64,
        statistics: vm_statistics64_data_t,
        pageBytes: UInt64,
        swapUsed: UInt64?,
        swapTotal: UInt64?,
        pressureLevel: Int32?
    ) {
        self.timestamp = timestamp
        self.total = total
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressureLevel = pressureLevel
        let internalPages = UInt64(statistics.internal_page_count)
        let purgeablePages = UInt64(statistics.purgeable_count)
        let externalPages = UInt64(statistics.external_page_count)
        let speculativePages = UInt64(statistics.speculative_count)
        // Speculative pages appear in BOTH free_count and external_page_count.
        // Count them as free, not cached, to keep the categories disjoint.
        let cachedPages = externalPages > speculativePages ? externalPages - speculativePages : 0
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        app = appPages * pageBytes
        wired = UInt64(statistics.wire_count) * pageBytes
        compressed = UInt64(statistics.compressor_page_count) * pageBytes
        cached = (cachedPages + purgeablePages) * pageBytes
        free = UInt64(statistics.free_count) * pageBytes
    }

    var used: UInt64 { app + wired + compressed }
    var available: UInt64 { cached + free }
    var other: UInt64 {
        let accounted = used + available
        return total > accounted ? total - accounted : 0
    }
    var usedFraction: Double { min(Double(used) / Double(total), 1) }

    var pressureName: String {
        switch pressureLevel {
        case 1: "Normal"
        case 2: "Warning"
        case 4: "Critical"
        case nil: "Unavailable"
        default: "Unknown"
        }
    }

    var pressureDescription: String {
        switch pressureLevel {
        case 1: "macOS reports normal memory pressure."
        case 2: "Memory is under pressure. Closing unused apps may help."
        case 4: "Memory pressure is critical. Reduce active workloads."
        case nil: "macOS could not provide its memory pressure level."
        default: "macOS reported an unrecognized pressure level."
        }
    }
}

// One host-port send right for the lifetime of this reader, not one per poll.
final class MemoryReader {
    private let host = mach_host_self()
    private let total = ProcessInfo.processInfo.physicalMemory

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    func read() throws -> MemorySnapshot {
        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(host, &pageSize)
        guard pageResult == KERN_SUCCESS, pageSize > 0, total > 0 else {
            throw ReadError(operation: "Page size", code: pageResult)
        }

        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw ReadError(operation: "Memory statistics", code: result)
        }

        var pressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        let pressureResult = sysctlbyname(
            "kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0
        )
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        return MemorySnapshot(
            timestamp: Date(),
            total: total,
            statistics: statistics,
            pageBytes: UInt64(pageSize),
            swapUsed: swapResult == 0 ? swap.xsu_used : nil,
            swapTotal: swapResult == 0 ? swap.xsu_total : nil,
            pressureLevel: pressureResult == 0 ? pressure : nil
        )
    }

    struct ReadError: LocalizedError {
        let operation: String
        let code: kern_return_t
        var errorDescription: String? {
            "\(operation) could not be read (Mach error \(code))."
        }
    }
}

func memoryAmount(_ bytes: UInt64) -> String {
    if bytes == 0 { return "0 GiB" }
    let gib = Double(bytes) / 1_073_741_824
    if gib >= 1 { return String(format: "%.2f GiB", gib) }
    return String(format: "%.0f MiB", Double(bytes) / 1_048_576)
}
