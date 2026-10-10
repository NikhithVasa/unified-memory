import Charts
import SwiftUI

private enum MemoryCategory: String, CaseIterable, Identifiable {
    case app = "App memory"
    case wired = "Wired"
    case compressed = "Compressed"
    case cached = "Cached files"
    case free = "Free"
    case other = "Other"

    var id: String { rawValue }
    var color: Color {
        switch self {
        case .app: .blue
        case .wired: .indigo
        case .compressed: .purple
        case .cached: .teal
        case .free: .green
        case .other: .gray
        }
    }
    var explanation: String {
        switch self {
        case .app: "Resident anonymous memory, excluding purgeable pages."
        case .wired: "Memory macOS keeps in RAM and cannot compress or swap."
        case .compressed: "Physical RAM occupied by the memory compressor."
        case .cached: "File-backed and purgeable memory that macOS can reclaim."
        case .free: "Free and speculative pages, ready to be used."
        case .other: "Installed RAM not attributed by these VM counters, including reserved memory. Counters are approximate."
        }
    }
    func bytes(in sample: MemorySnapshot) -> UInt64 {
        switch self {
        case .app: sample.app
        case .wired: sample.wired
        case .compressed: sample.compressed
        case .cached: sample.cached
        case .free: sample.free
        case .other: sample.other
        }
    }
}

struct ContentView: View {
    @ObservedObject var monitor: MemoryMonitor
    @State private var selectedPage = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                header
                Picker("Memory view", selection: $selectedPage) {
                    Text("Memory overview").tag(0)
                    Text("Memory by process").tag(1)
                    Text("Sensors").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 20)

            if selectedPage == 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let error = monitor.error {
                            Label("\(error) Readings below are stale. Retrying while live.", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if let sample = monitor.snapshot {
                            HStack(alignment: .top, spacing: 16) {
                                usageCard(sample)
                                pressureCard(sample)
                            }
                            composition(sample)
                            historyCard(sample)
                            MemoryStorageView(snapshot: sample, sensors: monitor.sensorMonitor)
                            footer(sample)
                        } else {
                            ContentUnavailableView(
                                "Memory readings unavailable",
                                systemImage: "memorychip",
                                description: Text(monitor.error ?? "Waiting for macOS memory counters…")
                            )
                            .frame(height: 440)
                            Button("Try again") { monitor.refresh() }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
                .defaultScrollAnchor(.top)
            } else if selectedPage == 1 {
                ProcessMemoryView(monitor: monitor)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            } else {
                SensorsView(monitor: monitor.sensorMonitor, paused: monitor.isPaused, interval: monitor.interval)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, minHeight: 660)
        .onAppear { monitor.setSensorsVisible(selectedPage == 2) }
        .onChange(of: selectedPage) { _, page in monitor.setSensorsVisible(page == 2) }
        .onDisappear { monitor.setSensorsVisible(false) }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Menu {
                    ForEach([1, 2, 5], id: \.self) { seconds in
                        Button {
                            monitor.setInterval(seconds)
                        } label: {
                            if monitor.interval == seconds {
                                Label("Every \(seconds) second\(seconds == 1 ? "" : "s")", systemImage: "checkmark")
                            } else {
                                Text("Every \(seconds) second\(seconds == 1 ? "" : "s")")
                            }
                        }
                    }
                } label: {
                    Label("Refresh interval", systemImage: "timer")
                }
                .help("Change the sampling interval")
                Button {
                    monitor.togglePause()
                } label: {
                    Label(monitor.isPaused ? "Resume" : "Pause", systemImage: monitor.isPaused ? "play.fill" : "pause.fill")
                }
                .help(monitor.isPaused ? "Resume live readings (⌘P)" : "Pause live readings (⌘P)")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "memorychip")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 52, height: 52)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text("Unified Memory")
                    .font(.system(size: 26, weight: .bold))
                Text("One memory pool. Your entire Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TemperatureStatusView(snapshot: monitor.temperature, error: monitor.temperatureError)
            Label(
                monitor.error != nil ? "Read error" : monitor.isPaused ? "Paused" : "Live · \(monitor.interval)s",
                systemImage: monitor.error != nil ? "exclamationmark.circle.fill" : monitor.isPaused ? "pause.circle.fill" : "circle.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(monitor.error != nil ? .orange : monitor.isPaused ? .secondary : .green)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.primary.opacity(0.04), in: Capsule())
        }
    }

    private func usageCard(_ sample: MemorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MEMORY USED")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(String(format: "%.2f", Double(sample.used) / 1_073_741_824))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                Text("GiB")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(sample.usedFraction, format: .percent.precision(.fractionLength(1)))
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .monospacedDigit()
            ProgressView(value: sample.usedFraction)
                .tint(.blue)
                .accessibilityLabel("Memory used")
                .accessibilityValue("\(memoryAmount(sample.used)) of \(memoryAmount(sample.total))")
            HStack {
                Label("\(memoryAmount(sample.total)) installed", systemImage: "desktopcomputer")
                Spacer()
                Text("\(memoryAmount(sample.available)) reclaimable / free")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .cardSurface()
    }

    private func pressureCard(_ sample: MemorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MEMORY PRESSURE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Label(sample.pressureName, systemImage: pressureSymbol(sample))
                .font(.title2.weight(.semibold))
                .foregroundStyle(pressureColor(sample))
            Text(sample.pressureDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Text("Swap used")
                Spacer()
                Text(sample.swapUsed.map(memoryAmount) ?? "Unavailable")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.callout)
            .help(sample.swapTotal.map { "\(memoryAmount($0)) of swap allocated on disk. Swap is not physical RAM." } ?? "macOS swap counters unavailable.")
        }
        .padding(20)
        .frame(width: 230, height: 150, alignment: .topLeading)
        .cardSurface()
    }

    private func composition(_ sample: MemorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Physical memory")
                    .font(.headline)
                Spacer()
                Text("App + wired + compressed = memory used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let denominator = Double(max(sample.total, sample.used + sample.available))
                HStack(spacing: 0) {
                    ForEach(MemoryCategory.allCases) { category in
                        category.color
                            .frame(width: geometry.size.width * Double(category.bytes(in: sample)) / denominator)
                            .help("\(category.rawValue): \(memoryAmount(category.bytes(in: sample)))")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(height: 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Physical memory composition")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
                ForEach(MemoryCategory.allCases) { category in
                    HStack(spacing: 9) {
                        Circle().fill(category.color).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(category.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(memoryAmount(category.bytes(in: sample)))
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                        }
                        Spacer(minLength: 0)
                    }
                    .help(category.explanation)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(20)
        .cardSurface()
    }

    private func historyCard(_ sample: MemorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Usage history")
                    .font(.headline)
                Spacer()
                Text("Last 5 minutes · GiB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Chart {
                ForEach(0..<monitor.sampleCount, id: \.self) { index in
                    if let point = monitor.sample(at: index) {
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Used", Double(point.used) / 1_073_741_824)
                        )
                        .foregroundStyle(.linearGradient(colors: [.blue.opacity(0.2), .blue.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Used", Double(point.used) / 1_073_741_824)
                        )
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                PointMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Used", Double(sample.used) / 1_073_741_824)
                )
                .foregroundStyle(.blue)
                .symbolSize(26)
            }
            .chartXScale(domain: sample.timestamp.addingTimeInterval(-300)...sample.timestamp)
            .chartYScale(domain: 0...Double(sample.total) / 1_073_741_824)
            .chartXAxis {
                AxisMarks(values: .stride(by: .minute)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 140)
            .accessibilityLabel("Memory usage over the last five minutes")
            .accessibilityValue("Current usage: \(memoryAmount(sample.used))")
        }
        .padding(20)
        .cardSurface()
    }

    private func footer(_ sample: MemorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Read directly from macOS", systemImage: "checkmark.shield")
                Spacer()
                Text("Updated \(sample.timestamp.formatted(date: .omitted, time: .standard))")
                    .monospacedDigit()
            }
            Text("CPU and GPU share physical RAM. GPU driver allocations are part of this pool, not extra VRAM. Cached files are reclaimable. GiB = 1,024³ bytes.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func pressureColor(_ sample: MemorySnapshot) -> Color {
        switch sample.pressureLevel {
        case 1: .green
        case 2: .orange
        case 4: .red
        default: .secondary
        }
    }

    private func pressureSymbol(_ sample: MemorySnapshot) -> String {
        switch sample.pressureLevel {
        case 1: "checkmark.circle.fill"
        case 2: "exclamationmark.circle.fill"
        case 4: "exclamationmark.triangle.fill"
        default: "questionmark.circle"
        }
    }
}

private extension View {
    func cardSurface() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
            }
    }
}
