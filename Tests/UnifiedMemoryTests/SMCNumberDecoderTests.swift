import NativeTemperature
import XCTest

final class SMCNumberDecoderTests: XCTestCase {
    private func decode(_ type: String, _ bytes: [UInt8]) -> Double? {
        let code = type.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var value = 0.0
        let decoded = bytes.withUnsafeBufferPointer { UMSMCDecodeNumber(code, $0.baseAddress!, $0.count, &value) }
        return decoded ? value : nil
    }

    func testSignedValuesAndFractionalFanSpeed() {
        XCTAssertEqual(decode("si16", [0xff, 0x9c]), -100)
        XCTAssertEqual(decode("si32", [0xff, 0xff, 0xff, 0xf6]), -10)
        XCTAssertEqual(decode("fpe2", [0x2e, 0xe0]), 3000)
        XCTAssertEqual(decode("sp78", [0xfe, 0x80]), -1.5)
        XCTAssertEqual(decode("ui32", [0, 1, 0, 0]), 65536)
        XCTAssertNil(decode("fpzz", [0, 1]))
        XCTAssertNil(decode("ui16", [1]))
        XCTAssertNil(decode("ioft", [0, 0, 0, 0, 0, 0, 0, 0]))
    }
}
