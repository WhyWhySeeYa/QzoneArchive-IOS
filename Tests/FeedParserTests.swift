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
        // 点赞/评论记录与原动态共用同一个 cell_id (线上即如此), 评论正文取自 main_comment
        let like = rawFeed(eventType: 217, cellID: "cell-main", actorUin: "999", actorName: "点赞人")
        let comment = rawFeed(
            eventType: 2,
            cellID: "cell-main",
            actorUin: "888",
            actorName: "评论人",
            comments: [
                "main_comment": [
                    "commentid": "c1",
                    "user": ["uin": "888", "nickname": "评论人"],
                    "content": "你好",
                    "date": 1_700_000_100,
                    "replys": [[
                        "content": "谢谢",
                        "user": ["uin": ownerUin, "nickname": "我自己"],
                        "date": 1_700_000_200,
                    ]],
                ],
            ]
        )
        let dynamic = rawFeed(eventType: 1, cellID: "cell-main")
        let posts = FeedParser.parsePosts([like, comment, dynamic], account: account)
        guard let post = posts.first(where: { $0.contentText.contains("自己的动态") }) else {
            return XCTFail("未找到动态帖")
        }
        XCTAssertEqual(post.likeCount, 1)
        XCTAssertEqual(post.likes.first?.uin, "999")
        XCTAssertEqual(post.commentCount, 1)
        XCTAssertEqual(post.comments.first?.contentText, "你好")
        XCTAssertEqual(post.comments.first?.authorUin, "888")
        XCTAssertEqual(post.comments.first?.replies.count, 1)
        XCTAssertEqual(post.comments.first?.replies.first?.content, "谢谢")
    }

    // MARK: - 评论解析 (对应 archiveParser.ts commentFromValues / mergeComments)

    func testCommentFallsBackToEventSummary() {
        // main_comment 缺失时正文取互动摘要, 与原版 "评论了这条动态" 兜底链一致
        // 缺少 cell_id 的互动记录不应产生动态 (原版 save_original_dynamic 直接返回)
        let feed = rawFeed(eventType: 2, cellID: nil, eventSummary: "评论了这条动态")
        let comment = FeedParser.commentFromValues(
            commentsJSON: nil,
            actorUin: "888",
            actorName: "评论人",
            eventSummary: "评论了这条动态",
            eventTime: 1_700_000_100
        )
        XCTAssertEqual(comment.content, "评论了这条动态")
        XCTAssertEqual(comment.uin, "888")
        XCTAssertEqual(comment.createdAt, 1_700_000_100)
        XCTAssertTrue(FeedParser.parsePosts([feed], account: account).isEmpty, "无 cellid 时不应产生动态")
    }

    func testCommentReplyNotificationAppended() {
        // 回复通知: main_comment 是被回复的那条, 真正的回复正文在互动记录摘要里
        let json = """
        {"main_comment":{"commentid":"c1","user":{"uin":"20002","nickname":"好友"},
        "content":"写得不错","date":1700000100,"replynum":1,
        "replys":[{"content":"谢谢","user":{"uin":"10001","nickname":"我"},"date":1700000200}]}}
        """
        let comment = FeedParser.commentFromValues(
            commentsJSON: json,
            actorUin: "30003",
            actorName: "路人",
            eventSummary: "回复了你：同感",
            eventTime: 1_700_000_300
        )
        XCTAssertEqual(comment.content, "写得不错")
        XCTAssertEqual(comment.replies.count, 2, "回复通知应补一条回复")
        XCTAssertEqual(comment.replies.last?.content, "回复了你：同感")
        XCTAssertEqual(comment.replies.last?.uin, "30003")
        XCTAssertEqual(comment.replies.last?.replyToUin, "10001", "回复对象取时间最近的回复作者")
    }

    func testMergeCommentsDedupesByCommentID() {
        let first = ParsedComment(
            id: "a", uin: "20002", nickname: "好友", content: "写得不错", createdAt: 1_700_000_100,
            replies: [ArchivedReply(uin: "10001", nickname: "我", replyToUin: nil,
                                    replyToNickname: nil, content: "谢谢", createdAt: 1_700_000_200)],
            commentID: "c1"
        )
        let second = ParsedComment(
            id: "b", uin: "20002", nickname: "好友", content: "写得不错", createdAt: 1_700_000_100,
            replies: [ArchivedReply(uin: "30003", nickname: "路人", replyToUin: nil,
                                    replyToNickname: nil, content: "同感", createdAt: 1_700_000_300)],
            commentID: "c1"
        )
        let merged = FeedParser.mergeComments([first, second])
        XCTAssertEqual(merged.count, 1, "同一 commentid 只保留一条评论")
        XCTAssertEqual(merged.first?.replies.count, 2)
        XCTAssertEqual(merged.first?.replies.map(\.content), ["谢谢", "同感"], "回复按时间稳定排序")
    }

    func testPictureCandidatesSkipMissingPhotoURL() {
        let pictures: [[String: Any]] = [
            ["photourl": [["url": "https://img.example/a.jpg"]]],
            ["busi_param": ["-1": "https://img.example/b.jpg"]],
            ["photourl": [["url": "//img.example/c.jpg"], ["url": "https://img.example/c.jpg"]]],
        ]
        let json = String(
            data: try! JSONSerialization.data(withJSONObject: ["picdata": ["pic": pictures]]),
            encoding: .utf8
        )
        let candidates = FeedParser.pictureUrlCandidates(json)
        XCTAssertEqual(candidates.count, 2, "缺少 photourl 的图片不进入候选")
        XCTAssertEqual(candidates[0], ["https://img.example/a.jpg"])
        XCTAssertEqual(candidates[1], ["https://img.example/c.jpg"], "补全协议后去重")
        XCTAssertEqual(FeedParser.pictureURLs(json), ["https://img.example/a.jpg", "https://img.example/c.jpg"])
    }

    func testCommentFeedAloneCreatesDynamic() {
        // 原版对每条互动记录都执行 save_original_dynamic, 只有评论通知时也会归档出动态
        let comment = rawFeed(eventType: 2, cellID: "cell-only", content: "只有评论通知的动态")
        let posts = FeedParser.parsePosts([comment], account: account)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.sourceID, "cell-only")
        XCTAssertEqual(posts.first?.contentText, "只有评论通知的动态")
        XCTAssertEqual(posts.first?.commentCount, 1)
    }
}
