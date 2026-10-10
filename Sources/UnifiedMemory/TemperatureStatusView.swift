import SwiftUI

struct TemperatureStatusView: View {
    let snapshot: TemperatureSnapshot?
    let error: String?
    @State private var showingSensors = false

    var body: some View {
        let hottest = snapshot?.hottest
        Button {
            showingSensors.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: error == nil ? "thermometer.medium" : "exclamationmark.triangle")
                if let hottest {
                    Text("Internal \(hottest.celsius, specifier: "%.1f") °C\(error == nil ? "" : " · stale")")
                        .monospacedDigit()
                } else {
                    Text(error == nil ? "Reading temperature…" : "Temperature unavailable")
                }
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(error == nil ? Color.primary : Color.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.primary.opacity(0.04), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Internal temperature")
        .accessibilityValue(hottest.map { String(format: "%.1f degrees Celsius%@", $0.celsius, error == nil ? "" : ", stale") } ?? (error == nil ? "Reading sensors" : "Unavailable"))
        .help(hottest.map { "Hottest exposed internal sensor: \($0.name). Click for all sensor readings." } ?? "Click for temperature sensor status.")
        .popover(isPresented: $showingSensors, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Temperature sensors")
                    .font(.headline)
                Text("The header shows the hottest exposed internal sensor, not the laptop’s surface or room temperature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let snapshot, !snapshot.readings.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(snapshot.readings) { reading in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(reading.name)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 12)
                                    Text("\(reading.celsius, specifier: "%.1f") °C")
                                        .font(.callout.weight(.semibold))
                                        .monospacedDigit()
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                    Text("Sampled \(snapshot.timestamp.formatted(date: .omitted, time: .standard))\(error == nil ? "" : " · stale")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if error == nil {
                    ProgressView("Reading available hardware sensors…")
                }
                Text("Sensors vary by Mac model and macOS version. Sampling pauses with the memory monitor; Refresh Now takes a new reading even while paused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(width: 370)
        }
    }
}
