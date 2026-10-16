//
//  QzoneLoginPrimitivesTests.swift
//  QzoneArchiveTests
//
//  登录原语测试: ptqrtoken, bkn, UA 选择, Cookie 解析, 回调文本解析
//

import XCTest
@testable import QzoneArchive

final class QzoneLoginPrimitivesTests: XCTestCase {
    func testPtqrTokenIsStable() {
        let qrsig = "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(QzoneLoginPrimitives.ptqrToken(qrsig), QzoneLoginPrimitives.ptqrToken(qrsig))
        XCTAssertLessThanOrEqual(QzoneLoginPrimitives.ptqrToken(qrsig), 0x7fff_ffff)
    }

    func testBknIsStableAndBounded() {
        XCTAssertEqual(QzoneLoginPrimitives.bkn("abcdefg"), QzoneLoginPrimitives.bkn("abcdefg"))
        XCTAssertLessThanOrEqual(QzoneLoginPrimitives.bkn("abcdefg"), 0x7fff_ffff)
        XCTAssertNotEqual(QzoneLoginPrimitives.bkn("a"), QzoneLoginPrimitives.bkn("b"))
    }

    func testPollLoginURLOnlyWhenCodeIsZero() {
        let ok = "ptuiCB('0','0','https://ptlogin2.qzone.qq.com/check_sig?pttype=1&uin=123456789','0','登录成功','')"
        XCTAssertEqual(
            QzoneLoginPrimitives.pollLoginURL(ok),
            "https://ptlogin2.qzone.qq.com/check_sig?pttype=1&uin=123456789"
        )
        let expired = "ptuiCB('65','0','','0','二维码已过期','')"
        XCTAssertNil(QzoneLoginPrimitives.pollLoginURL(expired))
        let scanned = "ptuiCB('66','0','','0','已扫描','')"
        XCTAssertNil(QzoneLoginPrimitives.pollLoginURL(scanned))
        XCTAssertNil(QzoneLoginPrimitives.pollLoginURL("no quotes here"))
    }

    func testCallbackQueryValue() {
        let text = "ptuiCB('0','0','https://x.y/check_sig?pttype=1&uin=123&sig=abc&f_url=','0','ok','')"
        XCTAssertEqual(QzoneLoginPrimitives.callbackQueryValue(text, name: "uin"), "123")
        XCTAssertEqual(QzoneLoginPrimitives.callbackQueryValue(text, name: "sig"), "abc")
        XCTAssertNil(QzoneLoginPrimitives.callbackQueryValue(text, name: "missing"))
    }

    func testNormalizedUinStripsPrefixes() {
        XCTAssertEqual(QzoneLoginPrimitives.normalizedUin("o0123456789"), "123456789")
        XCTAssertEqual(QzoneLoginPrimitives.normalizedUin("00012345"), "12345")
        XCTAssertEqual(QzoneLoginPrimitives.normalizedUin("12345"), "12345")
        XCTAssertEqual(QzoneLoginPrimitives.normalizedUin("o0"), "")
    }

    func testAccountUserAgentIsDeterministicPerUin() {
        let uin = "123456789"
        XCTAssertEqual(QzoneLoginPrimitives.accountUserAgent(uin: uin), QzoneLoginPrimitives.accountUserAgent(uin: uin))
        XCTAssertTrue(QzoneLoginPrimitives.mobileUserAgents.contains(QzoneLoginPrimitives.accountUserAgent(uin: uin)))
    }

    func testSelectMobileUserAgentAvoidsPrevious() {
        let previous = QzoneLoginPrimitives.mobileUserAgents[0]
        for _ in 0..<20 {
            XCTAssertNotEqual(QzoneLoginPrimitives.selectMobileUserAgent(previous: previous), previous)
        }
    }

    func testCookieHeaderSorted() {
        let header = QzoneLoginPrimitives.cookieHeader(["uin": "o123", "p_skey": "abc", "skey": "@xyz"])
        XCTAssertEqual(header, "p_skey=abc; skey=@xyz; uin=o123")
    }

    func testLoginCredentialsFiltersWhitelist() {
        let credentials = QzoneLoginPrimitives.loginCredentials(
            from: ["uin": "o123", "p_skey": "abc", "pt2gguin": "u1", "pgv_pvid": "noise", "skey": "", "pt4_token": "tok"],
            uin: "o123"
        )
        XCTAssertEqual(Set(credentials.keys), ["uin", "p_skey", "pt2gguin", "pt4_token"])
        XCTAssertFalse(credentials.values.contains(""))
    }

    func testRandomHelpersLengthAndCharset() {
        XCTAssertEqual(QzoneLoginPrimitives.randomHex(length: 16).count, 16)
        let hex = QzoneLoginPrimitives.randomHex(length: 32)
        XCTAssertTrue(hex.allSatisfy { "0123456789abcdef".contains($0) })
        let alphanumeric = QzoneLoginPrimitives.randomAlphanumeric(length: 24)
        XCTAssertEqual(alphanumeric.count, 24)
        XCTAssertTrue(alphanumeric.allSatisfy { $0.isLetter || $0.isNumber })
        XCTAssertTrue(QzoneLoginPrimitives.randomUUIDLike().contains("-"))
    }

    func testUnixMillisIsReasonable() {
        let millis = QzoneLoginPrimitives.unixMillis()
        XCTAssertGreaterThan(millis, 1_600_000_000_000)
        XCTAssertLessThan(millis, 3_000_000_000_000)
    }

    func testQzoneErrorRedactionRemovesCredentials() {
        let text = "Cookie: skey=@abc123; p_skey=SECRETVALUE"
        let redacted = QzoneError.redact(text)
        XCTAssertFalse(redacted.contains("abc123"))
        XCTAssertFalse(redacted.contains("SECRETVALUE"))
    }
}
