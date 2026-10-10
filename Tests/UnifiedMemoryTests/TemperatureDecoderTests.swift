import NativeTemperature
import XCTest
@testable import UnifiedMemory

final class TemperatureDecoderTests: XCTestCase {
    private let floatType: UInt32 = 0x666c7420 // "flt "
    private let fixedType: UInt32 = 0x73703738 // "sp78"

    private func decode(type: UInt32, bytes: [UInt8]) -> Double? {
        bytes.withUnsafeBufferPointer { buffer in
            var value = 0.0
            guard UMTemperatureDecodeSMC(type, buffer.baseAddress!, buffer.count, &value) else { return nil }
            return value
        }
    }

    func testSMCFloatIsNativeLittleEndianAndSafeWhenUnaligned() throws {
        let bytes: [UInt8] = [0xff, 0x00, 0x00, 0x32, 0x42] // Unaligned 44.5f.
        var value = 0.0
        let decoded = bytes.withUnsafeBufferPointer { buffer in
            UMTemperatureDecodeSMC(floatType, buffer.baseAddress!.advanced(by: 1), 4, &value)
        }
        XCTAssertTrue(decoded)
        XCTAssertEqual(value, 44.5, accuracy: 0)
        XCTAssertEqual(try XCTUnwrap(decode(type: floatType, bytes: [0, 0, 0x32, 0x42])), 44.5, accuracy: 0)
    }

    func testSMCFixedPointIsSignedBigEndian() throws {
        XCTAssertEqual(try XCTUnwrap(decode(type: fixedType, bytes: [0x31, 0x80])), 49.5, accuracy: 0)
        XCTAssertEqual(try XCTUnwrap(decode(type: fixedType, bytes: [0xea, 0x80])), -21.5, accuracy: 0)
        let sentinel = try XCTUnwrap(decode(type: fixedType, bytes: [0x80, 0x00]))
        XCTAssertEqual(sentinel, -128)
        XCTAssertFalse(TemperatureDecoder.isUsableCelsius(sentinel))
    }

    func testSMCRejectsUnsupportedTypesMalformedLengthsAndNonfiniteFloats() {
        XCTAssertNil(decode(type: 0x75693332, bytes: [0, 0, 0, 45])) // "ui32" is not Celsius.
        XCTAssertNil(decode(type: floatType, bytes: [0, 0, 0x32]))
        XCTAssertNil(decode(type: fixedType, bytes: [0x31, 0x80, 0]))
        XCTAssertNil(decode(type: floatType, bytes: [0, 0, 0x80, 0x7f])) // +Infinity.
        XCTAssertNil(decode(type: floatType, bytes: [0, 0, 0xc0, 0x7f])) // NaN.
    }

    func testCalibrationAndDummyChannelsAreNotPhysicalReadings() {
        for name in ["PMU tcal", "PMU2 TCAL", " tcal ", "Calibration channel", "Dummy temperature", "Sentinel", "  "] {
            XCTAssertFalse(TemperatureDecoder.isPhysicalSensor(name: name), name)
        }
        for name in ["PMU tdie8", "PMU2 tdev5", "gas gauge battery", "NAND CH0 temp", "SMC Tp00"] {
            XCTAssertTrue(TemperatureDecoder.isPhysicalSensor(name: name), name)
        }
    }

    func testInvalidChannelsCannotMasqueradeAsLaptopTemperature() {
        for value in [Double.nan, .infinity, -.infinity, -128, -21.9752197265625, 0, 150.01, 255, 65_535] {
            XCTAssertFalse(TemperatureDecoder.isUsableCelsius(value), "\(value)")
        }
        for value in [0.5, 32, 49.962493896484375, 100, 150] {
            XCTAssertTrue(TemperatureDecoder.isUsableCelsius(value), "\(value)")
        }
    }

    func testUnavailableAndUnclassifiedChannelsRetainIdentityWithoutFakeCelsius() {
        let disconnected = TemperatureDecoder.sensorState(id: "hid:1", name: "PMU tdev1", value: -21.98, exclusionReason: nil)
        let blocked = TemperatureDecoder.sensorState(id: "hid:2", name: "PMU tdie8", value: nil, exclusionReason: nil)
        let unclassified = TemperatureDecoder.sensorState(
            id: "smc:TVMD", name: "SMC TVMD", value: 1,
            exclusionReason: TemperatureDecoder.exclusionReason(name: "SMC TVMD", physical: false)
        )
        let calibration = TemperatureDecoder.sensorState(
            id: "hid:3", name: "PMU tcal", value: 51.82,
            exclusionReason: TemperatureDecoder.exclusionReason(name: "PMU tcal", physical: true)
        )
        for state in [disconnected, blocked, unclassified, calibration] {
            XCTAssertNil(state.celsius)
            XCTAssertFalse(state.id.isEmpty)
        }
        guard case .unavailable = disconnected.status,
              case .unavailable = blocked.status,
              case .excluded = unclassified.status,
              case .excluded = calibration.status else {
            return XCTFail("Invalid, blocked and excluded channels must keep their distinct honest statuses.")
        }
        let snapshot = TemperatureSnapshot(
            timestamp: Date(timeIntervalSince1970: 0), readings: [],
            sensors: [disconnected, blocked, unclassified, calibration]
        )
        XCTAssertEqual(TemperatureReadError.noCurrentReadings(snapshot).snapshot?.sensors.count, 4)
        XCTAssertNil(snapshot.hottest)
    }

    func testHottestUsesActualMaximumAndDuplicateProductNamesKeepDistinctIDs() {
        let readings = [
            TemperatureReading(id: "hid:1", name: "gas gauge battery", celsius: 32),
            TemperatureReading(id: "hid:2", name: "gas gauge battery", celsius: 37.5),
            TemperatureReading(id: "smc:Tp00", name: "SMC Tp00", celsius: 48.25)
        ]
        let snapshot = TemperatureSnapshot(timestamp: Date(timeIntervalSince1970: 0), readings: readings, sensors: [])
        XCTAssertEqual(snapshot.hottest?.id, "smc:Tp00")
        XCTAssertEqual(snapshot.hottest?.celsius, 48.25)
        XCTAssertEqual(Set(snapshot.readings.map(\.id)).count, 3)
        XCTAssertNil(TemperatureSnapshot(timestamp: snapshot.timestamp, readings: [], sensors: []).hottest)
    }
}
