import XCTest
@testable import UnifiedMemory

final class CPUCounterTests: XCTestCase {
    func testBusyTicksExcludeIdleAndHandleCounterWrap() {
        XCTAssertEqual(CPUCounterUsage.percent(previous: (100, 20, 500, 5), current: (110, 30, 570, 15))!, 30, accuracy: 0.0001)
        XCTAssertEqual(CPUCounterUsage.percent(previous: (UInt32.max - 2, 0, 10, 0), current: (2, 0, 15, 0))!, 50, accuracy: 0.0001)
        XCTAssertNil(CPUCounterUsage.percent(previous: (1, 2, 3, 4), current: (1, 2, 3, 4)))
    }
}
