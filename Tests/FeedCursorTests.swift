//
//  FeedCursorTests.swift
//  QzoneArchiveTests
//
//  分页游标解析, 推进与异常跳过测试
//

import XCTest
@testable import QzoneArchive

final class FeedCursorTests: XCTestCase {
    /// 真实游标是逐层编码的: back_server_info 的值编码一次, 整个 att 值再编码一次
    /// (线上样例见 testParseRealCursorFromDesktopFixture)
    private func makeCursor(offset: Int, baseTime: Int, loadCount: Int) -> String {
        let backend = FeedCursor.serializeQueryPairs([
            QueryPair(key: "offset", value: "\(offset)"),
            QueryPair(key: "basetime", value: "\(baseTime)"),
        ])
        let attach = FeedCursor.serializeQueryPairs([
            QueryPair(key: "back_server_info", value: backend),
            QueryPair(key: "loadcount", value: "\(loadCount)"),
        ])
        return FeedCursor.serializeQueryPairs([QueryPair(key: "att", value: attach)])
    }

    /// 线上真实游标, 取自原项目 scripts/selftest.ts 的样例
    private let realCursor = "att=back%5Fserver%5Finfo%3Doffset%253D1168%2526total%253D4%2526basetime%253D1495974154%2526feedsource%253D1&lastrefreshtime=1785906139&lastseparatortime=0&loadcount=77&refresh_id=1785906139&tl=1495974154"

    func testParseRealCursorFromDesktopFixture() throws {
        let details = try FeedCursor.parse(realCursor)
        XCTAssertEqual(details.offset, 1168)
        XCTAssertEqual(details.baseTime, 1_495_974_154)
        XCTAssertEqual(details.loadCount, 77)
    }

    func testAdvanceRealCursorKeepsShape() throws {
        let advanced = try FeedCursor.advance(realCursor, offsetAdvance: 20)
        XCTAssertEqual(try FeedCursor.parse(advanced).offset, 1188)
        // 外层有 loadcount 时只递增外层, att 形状保持原样
        let outer = FeedCursor.parseQueryPairs(advanced) ?? []
        XCTAssertEqual(outer.first(where: { $0.key == "loadcount" })?.value, "78")
        XCTAssertEqual(
            outer.first(where: { $0.key == "att" })?.value,
            "back_server_info=offset%3D1188%26total%3D4%26basetime%3D1495974154%26feedsource%3D1"
        )
        XCTAssertTrue(advanced.hasPrefix("att="))
    }

    /// 对应原项目 selftest 的 buildNestedCursor: 逐层编码拼出嵌套游标
    private func buildNestedCursor(loadCountInAtt: Bool, loadCountInOuter: Bool) -> String {
        let backend = FeedCursor.serializeQueryPairs([
            QueryPair(key: "offset", value: "1168"),
            QueryPair(key: "basetime", value: "1495974154"),
        ])
        var attachPairs = [QueryPair(key: "back_server_info", value: backend)]
        if loadCountInAtt { attachPairs.append(QueryPair(key: "loadcount", value: "0")) }
        var outerPairs = [QueryPair(key: "att", value: FeedCursor.serializeQueryPairs(attachPairs))]
        outerPairs.append(QueryPair(key: "tl", value: "1495974154"))
        if loadCountInOuter { outerPairs.append(QueryPair(key: "loadcount", value: "0")) }
        return FeedCursor.serializeQueryPairs(outerPairs)
    }

    func testAdvanceKeepsLoadCountInsideAtt() throws {
        let cursor = buildNestedCursor(loadCountInAtt: true, loadCountInOuter: false)
        let advanced = try FeedCursor.advance(cursor, offsetAdvance: 1)
        let details = try FeedCursor.parse(advanced)
        XCTAssertEqual(details.offset, 1169)
        XCTAssertEqual(details.loadCount, 1)
        XCTAssertNil(FeedCursor.parseQueryPairs(advanced)?[key: "loadcount"])
    }

    func testMissingLoadCountDefaultsToZeroAndGoesIntoAtt() throws {
        let cursor = buildNestedCursor(loadCountInAtt: false, loadCountInOuter: false)
        XCTAssertEqual(try FeedCursor.parse(cursor).loadCount, 0)
        let advanced = try FeedCursor.advance(cursor, offsetAdvance: 1)
        XCTAssertEqual(try FeedCursor.parse(advanced).loadCount, 1)
        XCTAssertNil(FeedCursor.parseQueryPairs(advanced)?[key: "loadcount"])
    }

    func testAdvanceRealCursorByTwo() throws {
        let details = try FeedCursor.parse(try FeedCursor.advance(realCursor, offsetAdvance: 2))
        XCTAssertEqual(details.offset, 1170)
        XCTAssertEqual(details.baseTime, 1_495_974_154)
        XCTAssertEqual(details.loadCount, 78)
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
