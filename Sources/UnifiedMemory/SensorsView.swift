import SwiftUI

struct SensorsView: View {
    @ObservedObject var monitor: SensorMonitor
    let paused: Bool
    let interval: Int
    @State private var query = ""
    @State private var category: HardwareSensorCategory?
    @State private var selectedID: String?
    @State private var showingDetails = false
    @AppStorage("favoriteSensorIDs") private var favoriteData = Data()

    private var favoriteIDs: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: favoriteData)) ?? [])
    }

    private func toggleFavorite(_ id: String) {
        var favorites = favoriteIDs
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        favoriteData = (try? JSONEncoder().encode(favorites.sorted())) ?? Data()
    }

    private var filtered: [HardwareSensorReading] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return monitor.readings.filter { reading in
            (category == nil || reading.category == category) &&
            (search.isEmpty || [reading.name, reading.id, reading.source, reading.status.label].contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }
    private var selected: HardwareSensorReading? {
        monitor.readings.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hardware sensors")
                        .font(.title3.weight(.semibold))
                    let available = monitor.readings.filter { $0.status.isAvailable }.count
                    Text("\(monitor.readings.count) channels · \(available) live · \(monitor.readings.count - available) unavailable / raw")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search sensor, key, or status", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search sensors")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .help("Clear sensor search")
                    }
                }
                .padding(8)
                .frame(width: 250)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Picker("Category", selection: $category) {
                    Text("All sensors & statuses").tag(Optional<HardwareSensorCategory>.none)
                    ForEach(HardwareSensorCategory.allCases) { item in
                        Text(item.rawValue).tag(Optional(item))
                    }
                }
                .frame(width: 240)
                Spacer()
                Text(paused ? "Paused · readings retained" : "Motion / light: 5 Hz · Other sensors: \(interval)s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Click a card for its source, numeric value, units, and availability. Raw/unclassified firmware channels are not labeled as physical sensor measurements. Temperature means internal sensor temperature, not the laptop’s surface.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    let favorites = filtered.filter { favoriteIDs.contains($0.id) }
                    if !favorites.isEmpty {
                        Label("Favorites", systemImage: "star.fill").font(.headline).foregroundStyle(.yellow)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                            ForEach(favorites) { reading in sensorTile(reading) }
                        }
                    }
                    ForEach(HardwareSensorCategory.allCases) { group in
                        let items = filtered.filter { $0.category == group && !favoriteIDs.contains($0.id) }
                        if !items.isEmpty {
                            HStack {
                                Label(group.rawValue, systemImage: icon(group))
                                    .font(.headline)
                                Text(String(items.count))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                                ForEach(items) { reading in
                                    sensorTile(reading)
                                }
                            }
                        }
                    }
                    if monitor.readings.isEmpty {
                        ProgressView("Discovering hardware sensor channels…")
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if filtered.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .padding(.bottom, 10)
            }
            .defaultScrollAnchor(.top)
            .onChange(of: query) { _, _ in showingDetails = false }
            if let timestamp = monitor.lastUpdated {
                Text("Latest sample \(timestamp.formatted(date: .omitted, time: .standard)). Unavailable means macOS did not expose a usable value; detected hardware does not guarantee a readable sensor API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 16) {
                if let reading = selected {
                    HStack {
                        Label(reading.name, systemImage: icon(reading.category))
                            .font(.headline)
                        Spacer()
                        Button("Done") { showingDetails = false }
                            .keyboardShortcut(.defaultAction)
                    }
                    Text(formattedValue(reading))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    LabeledContent("Status", value: reading.status.label)
                    LabeledContent("Source", value: reading.source)
                    LabeledContent("Channel ID", value: reading.id)
                    LabeledContent("Sample time", value: reading.timestamp.formatted(date: .omitted, time: .standard))
                    let level = SensorLevel.forReading(reading)
                    LabeledContent("Display level", value: level.label)
                    Text(level.explanation).font(.caption).foregroundStyle(.secondary)
                    if let value = reading.value {
                        LabeledContent("Numeric value", value: String(format: "%.9g %@", value, reading.unit))
                    }
                    if let reason = reading.status.explanation {
                        Text(reason).foregroundStyle(reading.status.isAvailable ? Color.secondary : Color.orange)
                    }
                    if !reading.detail.isEmpty { Text(reading.detail).foregroundStyle(.secondary) }
                    if !reading.metadata.isEmpty {
                        Divider()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(reading.metadata.keys.sorted(), id: \.self) { key in
                                    LabeledContent(key, value: reading.metadata[key] ?? "")
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                    }
                    Text("Values continue updating here while the monitor is live. Pause applies to this view too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("Sensor no longer exposed", systemImage: "sensor", description: Text("The selected channel was removed or is no longer discovered."))
                    Button("Done") { showingDetails = false }
                }
            }
            .textSelection(.enabled)
            .padding(24)
            .frame(width: 530)
        }
    }

    private func sensorTile(_ reading: HardwareSensorReading) -> some View {
        Button {
            selectedID = reading.id
            showingDetails = true
        } label: {
            sensorCard(reading)
        }
        .buttonStyle(.plain)
        .help("\(reading.name): \(formattedValue(reading)); \(reading.status.label). Click for source and status.")
        .accessibilityLabel(reading.name)
        .accessibilityValue("\(formattedValue(reading)), \(reading.status.label)")
        .overlay(alignment: .topTrailing) {
            Button { toggleFavorite(reading.id) } label: {
                Image(systemName: favoriteIDs.contains(reading.id) ? "star.fill" : "star")
                    .foregroundStyle(favoriteIDs.contains(reading.id) ? Color.yellow : Color.secondary)
                    .padding(9)
                    .background(Color(nsColor: .controlBackgroundColor), in: Circle())
            }
            .buttonStyle(.plain)
            .help(favoriteIDs.contains(reading.id) ? "Remove from favorites" : "Pin to favorites")
            .accessibilityLabel("\(favoriteIDs.contains(reading.id) ? "Unfavorite" : "Favorite") \(reading.name)")
            .padding(.top, 13)
            .padding(.trailing, 5)
        }
    }

    private func levelColor(_ band: SensorLevel.Band) -> Color {
        switch band {
        case .normal: .green
        case .medium: .orange
        case .high: .red
        case .neutral: .secondary
        }
    }

    private func sensorCard(_ reading: HardwareSensorReading) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let level = SensorLevel.forReading(reading)
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(levelColor(level.band)).frame(height: 4)
                Text(level.label).font(.caption2.weight(.medium)).foregroundStyle(levelColor(level.band))
            }
            .help(level.explanation)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: SensorLevel.icon(for: reading))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(reading.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 26)
            }
            Text(formattedValue(reading))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack {
                Text(reading.status.label)
                Spacer()
                Text(reading.source)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func formattedValue(_ reading: HardwareSensorReading) -> String {
        if let text = reading.textValue, !text.isEmpty { return text }
        guard let value = reading.value, value.isFinite else { return "—" }
        let precision = reading.unit == "RPM" || reading.unit == "cycles" || reading.unit == "cores" || reading.unit == "mAh" ? 0 : reading.unit == "A" || reading.unit == "V" || reading.unit == "W" ? 3 : 1
        return String(format: "%.*f%@%@", precision, value, reading.unit.isEmpty ? "" : " ", reading.unit)
    }

    private func icon(_ category: HardwareSensorCategory) -> String {
        switch category {
        case .motion: "rotate.3d"
        case .display: "sun.max"
        case .temperature: "thermometer.medium"
        case .power: "bolt"
        case .battery: "battery.100percent"
        case .system: "desktopcomputer"
        case .diagnostics: "waveform.path"
        }
    }
}
