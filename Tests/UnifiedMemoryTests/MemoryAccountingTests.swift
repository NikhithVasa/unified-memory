import Darwin
import XCTest
@testable import UnifiedMemory

final class MemoryAccountingTests: XCTestCase {
    func testSpeculativePagesAreNotCountedTwiceAndCompressionUsesPhysicalSize() {
        var statistics = vm_statistics64_data_t()
        statistics.free_count = 100 // Includes the 40 speculative pages.
        statistics.speculative_count = 40
        statistics.external_page_count = 300 // Also includes those speculative pages.
        statistics.internal_page_count = 400
        statistics.purgeable_count = 20
        statistics.wire_count = 80
        statistics.compressor_page_count = 120
        statistics.total_uncompressed_pages_in_compressor = 900
        let page: UInt64 = 16_384
        let sample = MemorySnapshot(
            timestamp: Date(timeIntervalSince1970: 0),
            total: 1_000 * page,
            statistics: statistics,
            pageBytes: page,
            swapUsed: 0,
            swapTotal: 0,
            pressureLevel: 1
        )

        XCTAssertEqual(sample.free, 100 * page)
        XCTAssertEqual(sample.cached, 280 * page)
        XCTAssertEqual(sample.app, 380 * page)
        XCTAssertEqual(sample.compressed, 120 * page)
        XCTAssertEqual(sample.used, 580 * page)
        XCTAssertEqual(sample.available, 380 * page)
        XCTAssertEqual(sample.other, 40 * page)
        XCTAssertEqual(sample.used + sample.available + sample.other, sample.total)
    }
}
