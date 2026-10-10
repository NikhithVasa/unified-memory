import Foundation
import NativeTemperature
import XCTest
@testable import UnifiedMemory

final class HardwarePowerDecoderTests: XCTestCase {
    private func decode(_ type: String, _ bytes: [UInt8]) -> Double? {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return nil }
            var value = 0.0
            return UMSMCDecodeNumber(HardwarePowerDecoder.fourCC(type), base, buffer.count, &value) ? value : nil
        }
    }

    func testElectricalIntegerAndFixedPointDecodersPreserveSignednessAndFractions() throws {
        XCTAssertEqual(try XCTUnwrap(decode("ui16", [0x12, 0x34])), 4660)
        XCTAssertEqual(try XCTUnwrap(decode("si16", [0xff, 0x9c])), -100)
        XCTAssertEqual(try XCTUnwrap(decode("si32", [0xff, 0xff, 0xf4, 0x8e])), -2930)
        XCTAssertEqual(try XCTUnwrap(decode("ui32", [0xff, 0xff, 0xff, 0xff])), 4_294_967_295)
        XCTAssertEqual(try XCTUnwrap(decode("fpe2", [0x1f, 0x42])), 2000.5)
        XCTAssertEqual(try XCTUnwrap(decode("sp5a", [0xf6, 0x00])), -2.5)
        XCTAssertEqual(try XCTUnwrap(decode("flag", [0])), 0)
        XCTAssertNil(decode("fpe2", [0x1f]))
        XCTAssertNil(decode("fpZZ", [0x1f, 0x42]))
        XCTAssertNil(decode("ui64", [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]))
        XCTAssertNil(decode("ioft", [0, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertNil(decode("flt ", [0, 0, 0x80, 0x7f]))
    }

    func testKnownFanMappingKeepsActualZeroAndFractionalRPM() {
        let zero = HardwarePowerDecoder.smcReading(key: "F0Ac", type: "fpe2", size: 2, value: 0)
        let fractional = HardwarePowerDecoder.smcReading(key: "F0Tg", type: "fpe2", size: 2, value: 2000.5)
        XCTAssertEqual(zero.unit, "RPM")
        XCTAssertEqual(zero.value, 0)
        XCTAssertEqual(zero.status, .available)
        XCTAssertEqual(fractional.value, 2000.5)
        XCTAssertEqual(fractional.status, .available)
        let invalid = HardwarePowerDecoder.smcReading(key: "F0Ac", type: "flt ", size: 4, value: -1)
        XCTAssertEqual(invalid.value, -1)
        XCTAssertEqual(invalid.unit, "raw")
        guard case .unclassified = invalid.status else { return XCTFail("Negative fan speed must not be labeled live RPM.") }
    }

    func testSMCInventoryAccountingRetainsUnknownUnsupportedAndBlockedChannels() {
        let timestamp = Date(timeIntervalSince1970: 0)
        let channels = [
            HardwarePowerDecoder.smcReading(key: "PSTR", type: "flt ", size: 4, value: 33.5, timestamp: timestamp),
            HardwarePowerDecoder.smcReading(key: "PZC0", type: "si32", size: 4, value: 0, timestamp: timestamp),
            HardwarePowerDecoder.smcReading(key: "TVMD", type: "ui32", size: 4, value: 1, timestamp: timestamp),
            HardwarePowerDecoder.smcReading(key: "TG0B", type: "ioft", size: 8, value: nil, failure: "Unsupported/non-scalar firmware format; payload is not read.", timestamp: timestamp),
            HardwarePowerDecoder.smcReading(key: "VABC", type: "flt ", size: 4, value: nil, failure: "Permission denied.", timestamp: timestamp),
            HardwarePowerDecoder.smcReading(key: "IABC", type: "flt ", size: 4, value: .nan, timestamp: timestamp)
        ]
        XCTAssertEqual(channels.count, 6)
        XCTAssertEqual(Set(channels.map(\.id)).count, 6)
        XCTAssertEqual(channels.filter { $0.status.isAvailable }.count, 1)
        XCTAssertEqual(channels[0].unit, "W")
        XCTAssertEqual(channels[1].value, 0)
        XCTAssertEqual(channels[1].unit, "raw")
        XCTAssertEqual(channels[2].category, .diagnostics)
        XCTAssertEqual(channels[2].unit, "raw")
        XCTAssertTrue(channels.allSatisfy { $0.timestamp == timestamp })
        for channel in channels.suffix(3) {
            XCTAssertNil(channel.value)
            guard case .unavailable = channel.status else { return XCTFail("All discovered failures must remain visible.") }
        }
        XCTAssertTrue(HardwarePowerDecoder.isSensorKey("F0Ac"))
        XCTAssertFalse(HardwarePowerDecoder.isSensorKey("OSK0"))
        XCTAssertFalse(HardwarePowerDecoder.isSensorKey("$Num"))
        XCTAssertFalse(HardwarePowerDecoder.isNumericFormat("ch8*", size: 4))
        XCTAssertFalse(HardwarePowerDecoder.isNumericFormat("ioft", size: 8))
        XCTAssertFalse(HardwarePowerDecoder.isNumericFormat("flt ", size: 8))
    }

    func testHIDElectricalTypeDoesNotInventUnitScaleOrDropZero() {
        let current = HardwarePowerDecoder.hidReading(id: "hid:1", name: "PMU ildo5", value: 0, measurementType: 1, subtype: 0)
        let voltage = HardwarePowerDecoder.hidReading(id: "hid:2", name: "PMU vldo1", value: 16_466.9, measurementType: 2, subtype: 0)
        let cumulative = HardwarePowerDecoder.hidReading(id: "hid:3", name: "Electrical", value: 123, measurementType: 0, subtype: 1)
        let blocked = HardwarePowerDecoder.hidReading(id: "hid:4", name: "Electrical", value: nil, measurementType: nil, subtype: nil)
        XCTAssertEqual(current.value, 0)
        XCTAssertEqual(voltage.value, 16_466.9)
        for reading in [current, voltage, cumulative] {
            XCTAssertEqual(reading.unit, "raw")
            XCTAssertEqual(reading.category, .diagnostics)
            guard case .unclassified = reading.status else { return XCTFail("The event type does not establish a voltage/current scale.") }
        }
        XCTAssertNil(blocked.value)
        XCTAssertEqual(blocked.id, "hid:4")
        guard case .unavailable = blocked.status else { return XCTFail("Unavailable electrical service must keep its card.") }
    }

    func testBatteryConversionUsesMilliUnitsDeciKelvinAndRawHealthCapacities() throws {
        let properties: [String: Any] = [
            "BatteryInstalled": true, "Voltage": 12_836, "Amperage": -2930, "InstantAmperage": -2900,
            "AppleRawCurrentCapacity": 5708, "AppleRawMaxCapacity": 5798, "DesignCapacity": 5760,
            "CurrentCapacity": 100, "MaxCapacity": 100, "CycleCount": 2, "Temperature": 2955,
            "ExternalConnected": false, "IsCharging": false, "VirtualTemperature": 2229
        ]
        let readings = HardwarePowerDecoder.batteryReadings(properties: properties)
        let byID = Dictionary(uniqueKeysWithValues: readings.map { ($0.id, $0) })
        XCTAssertEqual(try XCTUnwrap(byID["battery:internal:Voltage"]?.value), 12.836, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(byID["battery:internal:Amperage"]?.value), -2.930, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(byID["battery:internal:Temperature"]?.value), 22.35, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(byID["battery:internal:capacity-health"]?.value), 5798.0 / 5760 * 100, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(byID["battery:internal:raw-charge-percent"]?.value), 5708.0 / 5798 * 100, accuracy: 0.000001)
        XCTAssertEqual(byID["battery:internal:MaxCapacity"]?.unit, "raw")
        XCTAssertEqual(byID["battery:internal:VirtualTemperature"]?.value, 2229)
        XCTAssertEqual(byID["battery:internal:ExternalConnected"]?.textValue, "No")
        XCTAssertNil(byID["battery:internal:NominalChargeCapacity"]?.value)
        XCTAssertFalse(byID["battery:internal:NominalChargeCapacity"]!.status.isAvailable)
    }

    func testBatteryAbsentInvalidAndUnavailableStatesKeepEveryKnownCard() {
        let empty = HardwarePowerDecoder.batteryReadings(properties: [:])
        let blocked = HardwarePowerDecoder.batteryReadings(properties: [:], unavailableReason: "Permission blocked.")
        let absent = HardwarePowerDecoder.batteryReadings(properties: ["BatteryInstalled": false, "Voltage": 0, "Amperage": 0, "CycleCount": 0])
        XCTAssertEqual(Set(empty.map(\.id)), Set(blocked.map(\.id)))
        XCTAssertEqual(Set(empty.map(\.id)), Set(absent.map(\.id)))
        XCTAssertEqual(Set(empty.map(\.id)).count, empty.count)
        XCTAssertTrue(empty.allSatisfy { $0.value == nil })
        XCTAssertTrue(blocked.allSatisfy { $0.value == nil && !$0.status.isAvailable })
        XCTAssertNil(absent.first { $0.id == "battery:internal:Voltage" }?.value)
        XCTAssertEqual(absent.first { $0.id == "battery:internal:BatteryInstalled" }?.textValue, "No")
        XCTAssertNil(HardwarePowerDecoder.number(true))
        XCTAssertNil(HardwarePowerDecoder.number("12836"))
        XCTAssertNil(HardwarePowerDecoder.number(Double.infinity))
        XCTAssertNil(HardwarePowerDecoder.boolean(1))
        XCTAssertNil(HardwarePowerDecoder.percentage(current: 10, maximum: 0))
        XCTAssertNil(HardwarePowerDecoder.batteryCelsius(deciKelvin: 65_535))
        XCTAssertNil(HardwarePowerDecoder.batteryCelsius(deciKelvin: 0))
    }

    func testLargeCountersRemainExactTextInsteadOfRoundedDoubles() {
        let counter = NSNumber(value: UInt64.max)
        XCTAssertNil(HardwarePowerDecoder.number(counter))
        XCTAssertEqual(HardwarePowerDecoder.exactIntegerText(counter), "18446744073709551615")
        let descriptor = HardwarePowerDecoder.BatteryNestedDescriptor(dictionary: "BatteryData", key: "PackCurrentAccumulatorCount", index: nil)
        let reading = HardwarePowerDecoder.nestedBatteryReading(descriptor,
            dictionaries: ["BatteryData": ["PackCurrentAccumulatorCount": counter]])
        XCTAssertNil(reading.value)
        XCTAssertEqual(reading.textValue, "18446744073709551615")
        guard case .unclassified = reading.status else { return XCTFail("Exact numeric telemetry must not disappear.") }
    }

    func testNestedBatteryChannelsPreserveArrayPositionsMissingValuesAndExcludePayloads() {
        let dictionaries: [String: [String: Any]] = ["BatteryData": [
            "CellVoltage": [4276, "invalid", 4279] as [Any], "SystemPower": 38.395,
            "BatteryState": Data([0xde, 0xad]), "ManufacturerData": Data([0xba, 0xdd]), "Serial": "private"
        ]]
        let descriptors = HardwarePowerDecoder.nestedBatteryDescriptors(dictionaries)
        XCTAssertEqual(descriptors.count, 4)
        let readings = descriptors.map { HardwarePowerDecoder.nestedBatteryReading($0, dictionaries: dictionaries) }
        XCTAssertEqual(Set(readings.map(\.id)).count, 4)
        XCTAssertEqual(readings.first { $0.id.hasSuffix("CellVoltage:0") }?.value, 4.276)
        XCTAssertEqual(readings.first { $0.id.hasSuffix("CellVoltage:0") }?.unit, "V")
        XCTAssertNil(readings.first { $0.id.hasSuffix("CellVoltage:1") }?.value)
        XCTAssertFalse(readings.first { $0.id.hasSuffix("CellVoltage:1") }!.status.isAvailable)
        let missing = descriptors.map { HardwarePowerDecoder.nestedBatteryReading($0, dictionaries: [:]) }
        XCTAssertEqual(Set(missing.map(\.id)), Set(readings.map(\.id)))
        XCTAssertTrue(missing.allSatisfy { $0.value == nil && !$0.status.isAvailable })
        XCTAssertEqual(readings.first { $0.id.hasSuffix("SystemPower") }?.unit, "raw")
    }
}
