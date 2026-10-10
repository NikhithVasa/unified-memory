import Foundation

struct SensorLevel {
    enum Band { case normal, medium, high, neutral }
    let band: Band
    let label: String
    let explanation: String

    static func forReading(_ reading: HardwareSensorReading) -> SensorLevel {
        let neutral = SensorLevel(band: .neutral, label: reading.status.label, explanation: reading.status.explanation ?? "No meaningful low/normal/high range is established for this channel.")
        guard reading.status.isAvailable, let value = reading.value, value.isFinite else { return neutral }
        if reading.id == "system:thermal-pressure" {
            if value >= 2 { return SensorLevel(band: .high, label: "High", explanation: "macOS reports serious or critical thermal pressure.") }
            return SensorLevel(band: value == 1 ? .medium : .normal, label: value == 1 ? "Medium" : "Normal", explanation: "macOS's native thermal-pressure classification.")
        }
        if reading.unit == "°C" {
            let battery = reading.name.localizedCaseInsensitiveContains("battery") || reading.name.localizedCaseInsensitiveContains("gas gauge")
            let storage = reading.name.localizedCaseInsensitiveContains("nand")
            let medium = battery ? 40.0 : storage ? 60.0 : 70.0
            let high = battery ? 45.0 : storage ? 75.0 : 85.0
            let band: Band = value >= high ? .high : value >= medium ? .medium : .normal
            return SensorLevel(band: band, label: band == .high ? "High" : band == .medium ? "Medium" : "Normal",
                explanation: "Display guideline, not a manufacturer safety limit: medium at \(Int(medium)) °C and high at \(Int(high)) °C. The actual sensor and workload determine safe operating temperature.")
        }
        if reading.id == "system:cpu-usage" || reading.name.contains("Utilization %") || reading.id == "system:disk-used-percent" {
            let band: Band = value >= 90 ? .high : value >= 70 ? .medium : .normal
            return SensorLevel(band: band, label: band == .high ? "High" : band == .medium ? "Medium" : "Normal", explanation: "Usage guideline: medium at 70%, high at 90%. High utilization is not itself a hardware fault.")
        }
        if reading.unit == "%", reading.category == .display {
            let band: Band = value >= 80 ? .high : value >= 40 ? .medium : .normal
            return SensorLevel(band: band, label: band == .high ? "High setting" : band == .medium ? "Medium setting" : "Low / normal setting", explanation: "Brightness setting band, not a health warning: medium 40%, high 80%.")
        }
        if reading.unit == "%", reading.name.localizedCaseInsensitiveContains("charge"), !reading.name.localizedCaseInsensitiveContains("health") {
            let band: Band = value <= 10 ? .high : value <= 25 ? .medium : .normal
            return SensorLevel(band: band, label: band == .high ? "Very low charge" : band == .medium ? "Low charge" : "Normal", explanation: "Battery reserve guideline: amber at 25% or lower, red at 10% or lower.")
        }
        return neutral
    }

    static func icon(for reading: HardwareSensorReading) -> String {
        let name = reading.name.lowercased()
        if name.contains("lid") || name.contains("hinge") { return "laptopcomputer" }
        if name.contains("keyboard") { return "keyboard" }
        if name.contains("battery") || name.contains("gas gauge") || name.contains("cell voltage") || name.contains("charge") { return "battery.100percent" }
        if name.contains("fan") { return "fan" }
        if name.contains("disk") || name.contains("volume") || name.contains("nand") { return "internaldrive" }
        if name.contains("wi-fi") { return "wifi" }
        if name.contains("touch id") { return "touchid" }
        if name.contains("acceler") || name.contains("pitch") || name.contains("roll") { return "move.3d" }
        if name.contains("gyro") { return "rotate.3d" }
        if name.contains("gpu") || name.contains("renderer") || name.contains("tiler") { return "cpu" }
        if name.contains("memory") || name.contains("swap") || name.contains("ram") || name.contains("cache") { return "memorychip" }
        if name.contains("ambient") { return "sun.max" }
        if name.contains("brightness") || name.contains("display") { return "display" }
        if reading.unit == "°C" || reading.category == .temperature { return "thermometer.medium" }
        if reading.unit == "W" || reading.unit == "A" || reading.unit == "V" || reading.category == .power { return "bolt" }
        if reading.category == .system { return "desktopcomputer" }
        return "waveform.path"
    }
}
