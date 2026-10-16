//
//  FeedCursorTests.swift
//  QzoneArchiveTests
//
//  分页游标解析, 推进与异常跳过测试
//

import XCTest
@testable import QzoneArchive

final class FeedCursorTests: XCTestCase {
    private func makeCursor(offset: Int, baseTime: Int, loadCount: Int) -> String {
        let backend = "offset=\(offset)&basetime=\(baseTime)"
        let attach = "back_server_info=\(backend)&loadcount=\(loadCount)"
        return "att=\(attach)"
    }

    func testParseReadsThreeLayers() throws {
        let details = try FeedCursor.parse(makeCursor(offset: 120, baseTime: 1_700_000_000, loadCount: 3))
        XCTAssertEqual(details.offset, 120)
        XCTAssertEqual(details.baseTime, 1_700_000_000)
        XCTAssertEqual(details.loadCount, 3)
    }

    func testParseThrowsOnInvalidCursor() {
        XCTAssertThrowsError(try FeedCursor.parse("garbage"))
        XCTAssertThrowsError(try FeedCursor.parse("att=no_back_server_info"))
        XCTAssertThrowsError(try FeedCursor.parse("att=back_server_info=no_offset"))
    }

    func testAdvanceAddsOffset() throws {
        let cursor = makeCursor(offset: 100, baseTime: 1_700_000_000, loadCount: 3)
        let advanced = try FeedCursor.advance(cursor, offsetAdvance: 20)
        let details = try FeedCursor.parse(advanced)
        XCTAssertEqual(details.offset, 120)
        XCTAssertEqual(details.loadCount, 4)
        XCTAssertEqual(details.baseTime, 1_700_000_000)
    }

    func testAdvanceRejectsNonPositive() {
        XCTAssertThrowsError(try FeedCursor.advance(makeCursor(offset: 10, baseTime: 1, loadCount: 1), offsetAdvance: 0))
        XCTAssertThrowsError(try FeedCursor.advance(makeCursor(offset: 10, baseTime: 1, loadCount: 1), offsetAdvance: -5))
    }

    func testSkipProbeOffsetsGrowAndCapAtMax() {
        let offsets = FeedCursor.skipProbeOffsets(firstAdvance: 10)
        XCTAssertEqual(offsets.first, 10)
        XCTAssertEqual(offsets.last, 4096)
        // 严格递增
        for index in 1..<offsets.count {
            XCTAssertGreaterThan(offsets[index], offsets[index - 1])
        }
        // 每项不超过上限
        for offset in offsets { XCTAssertLessThanOrEqual(offset, 4096) }
    }

    func testSkipProbeOffsetsClampSmallFirst() {
        XCTAssertEqual(FeedCursor.skipProbeOffsets(firstAdvance: 0), [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096])
    }

    func testQueryPairsRoundTrip() {
        let cursor = makeCursor(offset: 5, baseTime: 9, loadCount: 1)
        let parsed = FeedCursor.parseQueryPairs(cursor)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.first(where: { $0.key == "att" })?.value,
                       "back_server_info=offset%3D5%26basetime%3D9&loadcount=1")
        XCTAssertEqual(FeedCursor.serializeQueryPairs(parsed ?? []), cursor)
    }

    func testRetryableResponseReason() {
        XCTAssertEqual(QzoneAPIClient.retryableResponseReason(status: 500, body: ""), "HTTP 500")
        XCTAssertEqual(QzoneAPIClient.retryableResponseReason(status: 429, body: ""), "HTTP 429")
        XCTAssertEqual(QzoneAPIClient.retryableResponseReason(status: 200, body: "not json"), "响应不是有效 JSON")
        XCTAssertNotNil(QzoneAPIClient.retryableResponseReason(status: 200, body: "{\"code\":-3000,\"message\":\"太频繁\"}"))
        XCTAssertNil(QzoneAPIClient.retryableResponseReason(status: 200, body: "{\"code\":-3000,\"message\":\"登录失效\"}"))
        XCTAssertNil(QzoneAPIClient.retryableResponseReason(status: 200, body: "{\"code\":0,\"data\":{}}"))
        XCTAssertNil(QzoneAPIClient.retryableResponseReason(status: 404, body: ""))
    }

    func testRetryDelayGrowsExponentially() {
        XCTAssertEqual(QzoneAPIClient.feedRetryDelayMs(attempt: 1), 1500)
        XCTAssertEqual(QzoneAPIClient.feedRetryDelayMs(attempt: 2), 3000)
        XCTAssertEqual(QzoneAPIClient.feedRetryDelayMs(attempt: 3), 6000)
    }
}
