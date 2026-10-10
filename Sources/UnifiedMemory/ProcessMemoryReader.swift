import Darwin
import Foundation

struct ProcessMemoryItem: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let pid: pid_t
        let startTime: UInt64?
    }

    let pid: pid_t
    let name: String
    let footprint: UInt64?
    // Mach absolute start time identifies this instance of a possibly reused PID.
    let startTime: UInt64?

    // Native table selection must not migrate when macOS reuses a PID.
    var id: ID { ID(pid: pid, startTime: startTime) }
}

struct ProcessMemorySnapshot: Sendable {
    let timestamp: Date
    let items: [ProcessMemoryItem]
    let unavailableCount: Int
}

// Process enumeration runs off the UI actor. Scratch buffers are reused.
actor ProcessMemoryReader {
    private var pids = [pid_t](repeating: 0, count: 1024)
    private var nameBuffer = [CChar](repeating: 0, count: 1024)

    func read() throws -> ProcessMemorySnapshot {
        try Task.checkCancellation()
        let required = Int(proc_listallpids(nil, 0))
        guard required > 0 else { throw EnumerationError() }
        if required + 128 > pids.count {
            pids = [pid_t](repeating: 0, count: required + 128)
        }
        let count = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { throw EnumerationError() }

        var items = [ProcessMemoryItem]()
        items.reserveCapacity(Int(count))
        var unavailableCount = 0
        for index in 0..<min(Int(count), pids.count) {
            try Task.checkCancellation()
            let pid = pids[index]
            guard pid > 0 else { continue }
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            // Processes that exit during the sample are not current consumers.
            if result != 0 && errno == ESRCH { continue }
            nameBuffer[0] = 0
            let nameResult = nameBuffer.withUnsafeMutableBytes {
                proc_name(pid, $0.baseAddress, UInt32($0.count))
            }
            let name = nameResult > 0
                ? nameBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                : "PID \(pid)"
            let footprint = result == 0 ? usage.ri_phys_footprint : nil
            if footprint == nil { unavailableCount += 1 }
            let startTime = result == 0 && usage.ri_proc_start_abstime != 0
                ? usage.ri_proc_start_abstime : nil
            items.append(ProcessMemoryItem(pid: pid, name: name, footprint: footprint, startTime: startTime))
        }
        items.sort { lhs, rhs in
            if (lhs.footprint != nil) != (rhs.footprint != nil) {
                return lhs.footprint != nil
            }
            if lhs.footprint != rhs.footprint {
                return (lhs.footprint ?? 0) > (rhs.footprint ?? 0)
            }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.pid < rhs.pid : order == .orderedAscending
        }
        return ProcessMemorySnapshot(timestamp: Date(), items: items, unavailableCount: unavailableCount)
    }

    struct EnumerationError: LocalizedError {
        var errorDescription: String? { "macOS could not enumerate running processes." }
    }
}
