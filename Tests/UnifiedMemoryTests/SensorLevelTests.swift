import XCTest
@testable import UnifiedMemory

final class SensorLevelTests: XCTestCase {
    func testTemperatureThresholdsRespectSensorTypeAndUnknownChannels() {
        let internalSensor = HardwareSensorReading(id: "die", name: "Die sensor", category: .temperature, value: 85, unit: "°C", source: "native")
        let battery = HardwareSensorReading(id: "battery", name: "Battery temperature", category: .temperature, value: 44, unit: "°C", source: "native")
        let raw = HardwareSensorReading(id: "raw", name: "Opaque", category: .diagnostics, value: 200, unit: "raw", status: .unclassified("Unknown units"), source: "native")
        XCTAssertEqual(SensorLevel.forReading(internalSensor).band, .high)
        XCTAssertEqual(SensorLevel.forReading(battery).band, .medium)
        XCTAssertEqual(SensorLevel.forReading(raw).band, .neutral)
    }

    func testHighUtilizationAndLowBatteryUseDifferentDirection() {
        let cpu = HardwareSensorReading(id: "system:cpu-usage", name: "CPU utilization", category: .system, value: 90, unit: "%", source: "native")
        let battery = HardwareSensorReading(id: "charge", name: "Battery charge", category: .battery, value: 10, unit: "%", source: "native")
        XCTAssertEqual(SensorLevel.forReading(cpu).band, .high)
        XCTAssertEqual(SensorLevel.forReading(battery).band, .high)
    }
}
