import XCTest
@testable import QzoneArchive

/// 夹具结构与断言均取自原项目 scripts/selftest.ts 与 src/main/core/archiveParser.ts
final class FeedParserTests: XCTestCase {

    private let ownerUin = "123456789"
    private lazy var account = Account(id: UUID(), qqUin: ownerUin)

    // MARK: - 夹具

    /// 构造与线上一致的原始记录: 只使用原实现会读取的嵌套路径
    private func rawFeed(
        eventType: Int = 1,
        cellID: String? = "cell-1",
        time: Int = 1_700_000_000,
        appid: Int = 311,
        feedSkey: String? = nil,
        actorUin: String = "123456789",
        actorName: String = "我自己",
        content: String = "自己的动态",
        eventSummary: String = "发表了动态",
        title: String = "标题",
        pictures: [[String: Any]]? = nil,
        video: [String: Any]? = nil,
        comments: [String: Any]? = nil
    ) -> [String: Any] {
        var comm: [String: Any] = ["time": time, "subid": eventType]
        if let feedSkey { comm["feedskey"] = feedSkey }
        var cellComm: [String: Any] = ["time": time, "appid": appid]
        if let feedSkey { cellComm["feedskey"] = feedSkey }
        var original: [String: Any] = [
            "cell_comm": cellComm,
            "cell_summary": ["summary": content],
            "cell_userinfo": ["user": ["uin": actorUin, "nickname": actorName]],
        ]
        if let cellID { original["cell_id"] = ["cellid": cellID] }
        if let pictures { original["cell_pic"] = ["picdata": ["pic": pictures]] }
        if let video { original["cell_video"] = video }
        if let comments { original["cell_comment"] = comments }
        return [
            "comm": comm,
            "userinfo": ["user": ["uin": actorUin, "nickname": actorName]],
            "title": ["title": title],
            "summary": ["summary": eventSummary],
            "original": original,
        ]
    }

    /// 带 original 的动态记录 (original 为空对象时 parseFeed 取不到 cellid)
    private func feedWithoutCellID(time: Int = 1_700_000_000) -> [String: Any] {
        [
            "comm": ["time": time, "subid": 1],
            "userinfo": ["user": ["uin": ownerUin, "nickname": "我自己"]],
            "original": ["cell_summary": ["summary": "无 cellid"]],
        ]
    }

    // MARK: - parseFeed

    func testParseFeedReadsCoreFields() {
        let parsed = FeedParser.parseFeed(rawFeed())
        XCTAssertEqual(parsed.cellID, "cell-1")
        XCTAssertEqual(parsed.eventType, 1)
        XCTAssertEqual(parsed.eventTime, 1_700_000_000)
        XCTAssertEqual(parsed.actorUin, ownerUin)
        XCTAssertEqual(parsed.actorName, "我自己")
        XCTAssertEqual(parsed.title, "标题")
        XCTAssertEqual(parsed.content, "自己的动态")
        XCTAssertEqual(parsed.eventSummary, "发表了动态")
        XCTAssertEqual(parsed.originalAuthorUin, ownerUin)
    }

    func testParseFeedPrefersExplicitFeedSkey() {
        let parsed = FeedParser.parseFeed(rawFeed(feedSkey: "self-key"))
        XCTAssertEqual(parsed.feedKey, "self-key")
    }

    func testParseFeedGeneratedKeyFromCellID() {
        let parsed = FeedParser.parseFeed(rawFeed())
        XCTAssertEqual(parsed.feedKey, "1:cell-1:1700000000:123456789")
    }

    func testParseFeedFallbackKeyUsesStableHash() {
        let parsed = FeedParser.parseFeed(feedWithoutCellID())
        XCTAssertTrue(parsed.feedKey.hasPrefix("fallback:1:1700000000:123456789:"), parsed.feedKey)
        let hash = String(parsed.feedKey.split(separator: ":").last ?? "")
        XCTAssertEqual(hash.count, 16)
        XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) }, hash)
        // 同一份内容必须得到同一个键
        XCTAssertEqual(parsed.feedKey, FeedParser.parseFeed(feedWithoutCellID()).feedKey)
    }

    func testParseFeedCountsPictures() {
        let parsed = FeedParser.parseFeed(rawFeed(pictures: [
            ["photourl": ["0": ["url": "https://img.example/a-0.jpg"]]],
            ["photourl": ["0": ["url": "https://img.example/b-0.jpg"]]],
        ]))
        XCTAssertEqual(parsed.pictureCount, 2)
        XCTAssertNotNil(parsed.picturesJSON)
        XCTAssertTrue(parsed.picturesJSON?.contains("a-0.jpg") ?? false)
    }

    func testParseFeedSnapshotJSONFromCellComment() {
        let parsed = FeedParser.parseFeed(rawFeed(comments: ["comments": [["comment": "你好"]]]))
        XCTAssertNotNil(parsed.commentsJSON)
        XCTAssertTrue(parsed.commentsJSON?.contains("你好") ?? false)
    }

    // MARK: - parseOriginalDynamic

    func testOriginalDynamicCategorySelf() {
        let dynamic = FeedParser.parseOriginalDynamic(rawFeed(), ownerUin: ownerUin)
        XCTAssertEqual(dynamic?.cellID, "cell-1")
        XCTAssertEqual(dynamic?.category, ArchiveCategory.self_)
        XCTAssertEqual(dynamic?.authorUin, ownerUin)
        XCTAssertEqual(dynamic?.content, "自己的动态")
        XCTAssertEqual(dynamic?.publishedAt, 1_700_000_000)
        XCTAssertEqual(dynamic?.pictureCount, 0)
    }

    func testOriginalDynamicCategoryOther() {
        let dynamic = FeedParser.parseOriginalDynamic(
            rawFeed(actorUin: "987654321", actorName: "路人", content: "别人的动态"),
            ownerUin: ownerUin
        )
        XCTAssertEqual(dynamic?.category, ArchiveCategory.other)
        XCTAssertEqual(dynamic?.authorName, "路人")
    }

    func testOriginalDynamicGuestbookByAppID() {
        let dynamic = FeedParser.parseOriginalDynamic(
            rawFeed(eventType: 217, appid: 334, actorUin: "555", actorName: "板主"),
            ownerUin: ownerUin
        )
        XCTAssertEqual(dynamic?.category, ArchiveCategory.guestbook)
    }

    func testOriginalDynamicGuestbookByFeedSkey() {
        let dynamic = FeedParser.parseOriginalDynamic(
            rawFeed(eventType: 334, feedSkey: "334_abcdef"),
            ownerUin: ownerUin
        )
        XCTAssertEqual(dynamic?.category, ArchiveCategory.guestbook)
    }

    func testOriginalDynamicWithoutCellIDIsSkipped() {
        XCTAssertNil(FeedParser.parseOriginalDynamic(feedWithoutCellID(), ownerUin: ownerUin))
    }

    // MARK: - 媒体地址

    func testPictureURLsKeepCandidateOrderAndNormalize() {
        let json = """
        {"picdata":{"pic":[
          {"photourl":{"0":{"url":"//img.example/a-0.jpg"},"1":{"url":"https://img.example/a-1.jpg"}},
           "busi_param":{"-1":"https://img.example/a-busi.jpg"}},
          {"photourl":[{"url":"https://img.example/b-0.jpg"},{"url":"https://img.example/b-0.jpg"}]}
        ]}}
        """
        let candidates = FeedParser.pictureUrlCandidates(json)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.first, [
            "https://img.example/a-0.jpg",
            "https://img.example/a-1.jpg",
            "https://img.example/a-busi.jpg",
        ])
        XCTAssertEqual(FeedParser.pictureURLs(json), [
            "https://img.example/a-0.jpg",
            "https://img.example/b-0.jpg",
        ])
        XCTAssertEqual(FeedParser.pictureCount(json), 2)
    }

    func testVideoURLsAndCover() {
        let json = """
        {"videourl":"https://v.example/main.mp4",
         "videourls":{"1":{"url":"https://v.example/hd.mp4"},"2":{"url":"https://v.example/main.mp4"}},
         "coverurl":{"0":{"url":"https://v.example/cover.jpg"}}}
        """
        XCTAssertEqual(FeedParser.videoURLs(json), [
            "https://v.example/main.mp4",
            "https://v.example/hd.mp4",
        ])
        XCTAssertEqual(FeedParser.videoCoverURL(json), "https://v.example/cover.jpg")
        XCTAssertEqual(FeedParser.videoURLs(nil), [])
        XCTAssertNil(FeedParser.videoCoverURL("not json"))
    }

    func testJSONPointerSupportsEscapesAndArrayIndex() {
        let object: [String: Any] = ["a/b": 1, "a~b": 2, "list": ["x", "y"], "0": "zero"]
        XCTAssertEqual(FeedParser.jsonPointer(object, "/a~1b") as? Int, 1)
        XCTAssertEqual(FeedParser.jsonPointer(object, "/a~0b") as? Int, 2)
        XCTAssertEqual(FeedParser.jsonPointer(object, "/list/1") as? String, "y")
        XCTAssertEqual(FeedParser.jsonPointer(object, "/0") as? String, "zero")
        XCTAssertNil(FeedParser.jsonPointer(object, "/list/2"))
        XCTAssertNil(FeedParser.jsonPointer(object, "/list/-1"))
        XCTAssertNil(FeedParser.jsonPointer(object, "/missing"))
    }

    func testTextAtAndAsIntegerFollowDesktopSemantics() {
        let object: [String: Any] = ["n": 1700000000, "s": "123", "empty": "", "flag": true, "f": 1.5]
        XCTAssertEqual(FeedParser.textAt(object, "/n"), "1700000000")
        XCTAssertEqual(FeedParser.textAt(object, "/s"), "123")
        XCTAssertNil(FeedParser.textAt(object, "/empty"))
        XCTAssertNil(FeedParser.textAt(object, "/flag"))
        XCTAssertEqual(FeedParser.asInteger(object["n"]), 1_700_000_000)
        XCTAssertNil(FeedParser.asInteger(object["s"]))
        XCTAssertNil(FeedParser.asInteger(object["f"]))
        XCTAssertNil(FeedParser.asInteger(object["flag"]))
    }

    func testValidateCategoryAcceptsOnlyKnownValues() throws {
        try FeedParser.validateCategory("self")
        try FeedParser.validateCategory("other")
        try FeedParser.validateCategory("guestbook")
        XCTAssertThrowsError(try FeedParser.validateCategory("self_"))
        XCTAssertThrowsError(try FeedParser.validateCategory(""))
    }

    func testStableJSONSortsKeysAndHashIsStable() {
        XCTAssertEqual(FeedParser.stableJSON(["b": 1, "a": 2]), "{\"a\":2,\"b\":1}")
        var commA: [String: Any] = [:]
        commA["time"] = 1
        commA["subid"] = 217
        var commB: [String: Any] = [:]
        commB["subid"] = 217
        commB["time"] = 1
        XCTAssertEqual(FeedParser.stableFeedHash(["comm": commA]),
                       FeedParser.stableFeedHash(["comm": commB]))
        let text = FeedParser.formatFeedHash(FeedParser.stableFeedHash(["comm": commA]))
        XCTAssertEqual(text.count, 16)
        XCTAssertTrue(text.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testGuestbookReadsContentAndAuthorFromFeedLevel() {
        let feed = rawFeed(
            eventType: 217,
            appid: 334,
            actorUin: "999",
            actorName: "访客",
            content: "动态层内容",
            eventSummary: "留了言"
        )
        XCTAssertEqual(FeedParser.parseFeed(feed).content, "动态层内容")
        XCTAssertEqual(FeedParser.parseFeed(feed).eventSummary, "留了言")
        let dynamic = FeedParser.parseOriginalDynamic(feed, ownerUin: "123456789")
        XCTAssertEqual(dynamic?.category, ArchiveCategory.guestbook)
        XCTAssertEqual(dynamic?.content, "留了言")
        XCTAssertEqual(dynamic?.authorUin, "999")
    }

    func testParsePostsSeparatesLikesAndComments() {
        let like = rawFeed(eventType: 217, cellID: "cell-like", actorUin: "999", actorName: "点赞人")
        let comment = rawFeed(
            eventType: 2,
            cellID: "cell-comment",
            actorUin: "888",
            actorName: "评论人",
            comments: ["comments": [["comment": "你好", "uin": "888", "nickname": "评论人", "time": 1_700_000_100]]]
        )
        let dynamic = rawFeed(eventType: 1, cellID: "cell-main")
        let posts = FeedParser.parsePosts([like, comment, dynamic], account: account)
        guard let post = posts.first(where: { $0.contentText.contains("自己的动态") }) else {
            return XCTFail("未找到动态帖")
        }
        XCTAssertEqual(post.likeCount, 1)
        XCTAssertEqual(post.likes.first?.uin, "999")
        XCTAssertTrue(post.comments.contains { $0.contentText == "你好" })
    }
}
