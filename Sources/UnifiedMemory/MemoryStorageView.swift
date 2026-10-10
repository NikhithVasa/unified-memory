import SwiftUI

struct MemoryStorageView: View {
    let snapshot: MemorySnapshot
    @ObservedObject var sensors: SensorMonitor

    private func value(_ id: String) -> Double? { sensors.readings.first { $0.id == id }?.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Memory & storage pools").font(.headline)
            capacityRow("Physical unified memory", icon: "memorychip", used: Double(snapshot.used), total: Double(snapshot.total), suffix: "App + wired + compressed. Cache is reclaimable, not permanently used.")
            if let used = snapshot.swapUsed, let total = snapshot.swapTotal {
                if total > 0 {
                    capacityRow("Swap on disk", icon: "arrow.left.arrow.right", used: Double(used), total: Double(total), suffix: "Disk-backed virtual memory, not additional RAM.")
                } else {
                    HStack {
                        Label("Swap on disk", systemImage: "arrow.left.arrow.right")
                        Spacer()
                        Text("0 GiB allocated").foregroundStyle(.secondary)
                    }.font(.callout)
                }
            }
            if let total = value("system:disk-total"), let free = value("system:disk-free"), total > 0 {
                capacityRow("Boot disk / APFS storage", icon: "internaldrive", used: (total - free) * 1_073_741_824, total: total * 1_073_741_824, suffix: "\(String(format: "%.1f", free)) GiB left. APFS volumes share the same storage pool.")
            } else {
                Label("Disk capacity unavailable", systemImage: "internaldrive").foregroundStyle(.secondary)
            }
            let gpuMemory = sensors.readings.filter { $0.name.hasPrefix("GPU ·") && $0.unit == "GiB" && $0.name.localizedCaseInsensitiveContains("memory") }
            if !gpuMemory.isEmpty {
                Divider()
                ForEach(gpuMemory) { reading in
                    HStack {
                        Label(reading.name, systemImage: "cpu")
                        Spacer()
                        Text(reading.value.map { String(format: "%.2f GiB", $0) } ?? "Unavailable")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }.font(.caption)
                }
            }
            Text("This Apple M5 uses one physical RAM pool for CPU and GPU; no separate dedicated VRAM is exposed. GPU driver allocations above are part of that pool, not extra memory. CPU cache sizes, when exposed, are listed in Sensors.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private func capacityRow(_ title: String, icon: String, used: Double, total: Double, suffix: String) -> some View {
        let safeUsed = min(total, max(0, used))
        let fraction = total > 0 ? safeUsed / total : 0
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text("\(String(format: "%.1f", safeUsed / 1_073_741_824)) / \(String(format: "%.1f", total / 1_073_741_824)) GiB · \(String(format: "%.1f", fraction * 100))% used")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }.font(.callout)
            ProgressView(value: fraction)
                .tint(fraction >= 0.9 ? .red : fraction >= 0.7 ? .orange : .green)
                .accessibilityLabel(title)
                .accessibilityValue("\(String(format: "%.1f", fraction * 100)) percent used")
            Text(suffix).font(.caption).foregroundStyle(.secondary)
        }
    }
}
