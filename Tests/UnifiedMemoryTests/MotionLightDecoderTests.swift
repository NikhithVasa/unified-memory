import NativeHardware
import XCTest
@testable import UnifiedMemory

final class MotionLightDecoderTests: XCTestCase {
    private func lid(_ bytes: [UInt8]) -> Double? {
        bytes.withUnsafeBufferPointer { buffer in
            var angle = Double.nan
            guard UMMotionLightDecodeLidReport(buffer.baseAddress, buffer.count, &angle) else { return nil }
            return angle
        }
    }

    func testLidReportDecodesNineBitsAndDegreeBoundaries() throws {
        XCTAssertEqual(try XCTUnwrap(lid([1, 0, 0])), 0)
        XCTAssertEqual(try XCTUnwrap(lid([1, 132, 0])), 132)
        XCTAssertEqual(try XCTUnwrap(lid([1, 0, 1])), 256)
        XCTAssertEqual(try XCTUnwrap(lid([1, 104, 1])), 360)
        // Upper seven bits are report padding, not additional angle precision.
        XCTAssertEqual(try XCTUnwrap(lid([1, 104, 0xff])), 360)
    }

    func testLidRejectsWrongReportTruncatedExtendedAndOutOfRangePayloads() {
        let malformed: [[UInt8]] = [[], [1], [1, 10], [2, 10, 0], [1, 105, 1], [1, 255, 1], [1, 10, 0, 0]]
        for bytes in malformed {
            XCTAssertNil(lid(bytes), "\(bytes)")
        }
        var angle = 42.0
        XCTAssertFalse(UMMotionLightDecodeLidReport(nil, 3, &angle))
        XCTAssertEqual(angle, 42, "Failed decoding must not publish a substituted value.")
    }

    func testVectorPitchRollCoordinateAxesAndScaleIndependence() throws {
        let level = try XCTUnwrap(MotionLightDecoder.vectorAngles(x: 0, y: 0, z: 1))
        XCTAssertEqual(level.pitch, 0, accuracy: 1e-12)
        XCTAssertEqual(level.roll, 0, accuracy: 1e-12)
        let x = try XCTUnwrap(MotionLightDecoder.vectorAngles(x: 1, y: 0, z: 0))
        XCTAssertEqual(x.pitch, -90, accuracy: 1e-12)
        let y = try XCTUnwrap(MotionLightDecoder.vectorAngles(x: 0, y: 1, z: 0))
        XCTAssertEqual(y.roll, 90, accuracy: 1e-12)
        let vector = try XCTUnwrap(MotionLightDecoder.vectorAngles(x: -1, y: 1, z: 1))
        XCTAssertEqual(vector.pitch, 35.264389682754654, accuracy: 1e-10)
        XCTAssertEqual(vector.roll, 45, accuracy: 1e-12)
        let scaled = try XCTUnwrap(MotionLightDecoder.vectorAngles(x: -65_536, y: 65_536, z: 65_536))
        XCTAssertEqual(scaled.pitch, vector.pitch, accuracy: 1e-12)
        XCTAssertEqual(scaled.roll, vector.roll, accuracy: 1e-12)
    }

    func testVectorAnglesRejectMissingDirectionAndNonfiniteAxesWithoutOverflow() throws {
        XCTAssertNil(MotionLightDecoder.vectorAngles(x: 0, y: 0, z: 0))
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(MotionLightDecoder.vectorAngles(x: value, y: 1, z: 1))
            XCTAssertNil(MotionLightDecoder.vectorAngles(x: 1, y: value, z: 1))
            XCTAssertNil(MotionLightDecoder.vectorAngles(x: 1, y: 1, z: value))
        }
        let huge = try XCTUnwrap(MotionLightDecoder.vectorAngles(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude, z: .greatestFiniteMagnitude))
        let tiny = try XCTUnwrap(MotionLightDecoder.vectorAngles(x: .leastNonzeroMagnitude, y: .leastNonzeroMagnitude, z: .leastNonzeroMagnitude))
        XCTAssertEqual(huge.pitch, tiny.pitch, accuracy: 1e-12)
        XCTAssertEqual(huge.roll, tiny.roll, accuracy: 1e-12)
        XCTAssertTrue(huge.pitch.isFinite)
        XCTAssertTrue(huge.roll.isFinite)
    }
}
