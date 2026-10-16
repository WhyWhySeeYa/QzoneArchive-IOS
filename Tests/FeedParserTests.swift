//
//  FeedParserTests.swift
//  QzoneArchiveTests
//
//  互动数据解析测试, 用例对齐桌面端 core/archiveParser.ts
//

import XCTest
@testable import QzoneArchive

final class FeedParserTests: XCTestCase {
    private let account = Account(id: UUID(), qqUin: "123456789")

    /// 构造一条动态原始记录
    private func feed(
        cellID: String,
        eventType: Int,
        eventTime: Int,
        content: String,
        authorUin: String?,
        authorName: String?
    ) -> [String: Any] {
        var result: [String: Any] = [
            "cell_id": cellID,
            "event_type": eventType,
            "event_time": eventTime,
            "content": content,
        ]
        if let authorUin {
            result["actor_uin"] = authorUin
            result["cell_userinfo"] = ["user": ["uin": authorUin, "nickname": authorName ?? ""]]
        }
        return result
    }

    func testParseFeedReadsCoreFields() {
        let parsed = FeedParser.parseFeed(feed(
            cellID: "cell-1",
            eventType: 1,
            eventTime: 1_700_000_000,
            content: "今天天气不错",
            authorUin: "123456789",
            authorName: "我自己"
        ))
        XCTAssertEqual(parsed.cellID, "cell-1")
        XCTAssertEqual(parsed.eventType, 1)
        XCTAssertEqual(parsed.eventTime, 1_700_000_000)
        XCTAssertEqual(parsed.content, "今天天气不错")
        XCTAssertEqual(parsed.actorUin, "123456789")
        XCTAssertEqual(parsed.actorName, "我自己")
        XCTAssertEqual(parsed.feedKey, "cell-1-1-1700000000-123456789")
    }

    func testParseFeedUsesExplicitKeyWhenPresent() {
        var raw = feed(cellID: "cell-2", eventType: 1, eventTime: 1, content: "x",
                       authorUin: "123456789", authorName: "me")
        raw["key"] = "explicit-key"
        XCTAssertEqual(FeedParser.parseFeed(raw).feedKey, "explicit-key")
    }

    func testParsePostsSeparatesLikesAndComments() {
        let feeds: [[String: Any]] = [
            feed(cellID: "c1", eventType: 1, eventTime: 1, content: "正文", authorUin: "123456789", authorName: "me"),
            feed(cellID: "c1", eventType: 217, eventTime: 2, content: "赞", authorUin: "999", authorName: "好友A"),
            feed(cellID: "c1", eventType: 2, eventTime: 3, content: "评论内容", authorUin: "888", authorName: "好友B"),
        ]
        let posts = FeedParser.parsePosts(feeds, account: account)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].contentText, "正文")
        XCTAssertEqual(posts[0].likes.count, 1)
        XCTAssertEqual(posts[0].likes[0].uin, "999")
        XCTAssertEqual(posts[0].comments.count, 1)
        XCTAssertEqual(posts[0].comments[0].contentText, "评论内容")
        XCTAssertEqual(posts[0].likeCount, 1)
        XCTAssertEqual(posts[0].commentCount, 1)
    }

    func testParsePostsKeepsOriginalOrder() {
        let feeds: [[String: Any]] = [
            feed(cellID: "c1", eventType: 1, eventTime: 1, content: "第一条", authorUin: "123456789", authorName: "me"),
            feed(cellID: "c2", eventType: 1, eventTime: 2, content: "第二条", authorUin: "123456789", authorName: "me"),
            feed(cellID: "c1", eventType: 217, eventTime: 3, content: "赞", authorUin: "999", authorName: "A"),
        ]
        let posts = FeedParser.parsePosts(feeds, account: account)
        XCTAssertEqual(posts.map(\.contentText), ["第一条", "第二条"])
    }

    func testCategoryDependsOnAuthor() {
        let own = FeedParser.parseOriginalDynamic(
            feed(cellID: "c1", eventType: 1, eventTime: 1, content: "自己的", authorUin: "123456789", authorName: "me"),
            ownerUin: "123456789"
        )
        XCTAssertEqual(own.category, .self_)

        let other = FeedParser.parseOriginalDynamic(
            feed(cellID: "c2", eventType: 1, eventTime: 1, content: "好友的", authorUin: "999", authorName: "A"),
            ownerUin: "123456789"
        )
        XCTAssertEqual(other.category, .other)
    }

    func testGuestbookDetectedByCellID() {
        let dynamic = FeedParser.parseOriginalDynamic(
            feed(cellID: "guestbook-1", eventType: 1, eventTime: 1, content: "留言", authorUin: "123456789", authorName: "me"),
            ownerUin: "123456789"
        )
        XCTAssertEqual(dynamic.category, .guestbook)
    }

    func testPictureURLsExtractedFromJSON() {
        let json = #"[{"url":"https://example.com/a.jpg"},{"url":"https://example.com/b.jpg"}]"#
        let urls = FeedParser.pictureURLs(json)
        XCTAssertEqual(urls, ["https://example.com/a.jpg", "https://example.com/b.jpg"])
    }

    func testPictureURLsEmptyOnInvalidJSON() {
        XCTAssertTrue(FeedParser.pictureURLs("not json").isEmpty)
        XCTAssertTrue(FeedParser.pictureURLs(nil).isEmpty)
    }

    func testVideoURLsExtracted() {
        let json = #"[{"url":"https://example.com/v.mp4","cover":"https://example.com/c.jpg"}]"#
        XCTAssertEqual(FeedParser.videoURLs(json), ["https://example.com/v.mp4"])
        XCTAssertEqual(FeedParser.videoCoverURL(json), "https://example.com/c.jpg")
    }

    func testMergeCommentsDeduplicates() {
        let first = ParsedComment(id: "a", uin: "1", nickname: "A", content: "同样的话", createdAt: 1, replies: [])
        let second = ParsedComment(id: "b", uin: "1", nickname: "A", content: "同样的话", createdAt: 1, replies: [])
        XCTAssertEqual(FeedParser.mergeComments([first, second]).count, 1)
    }

    func testMergeCommentsKeepsDistinct() {
        let first = ParsedComment(id: "a", uin: "1", nickname: "A", content: "话1", createdAt: 1, replies: [])
        let second = ParsedComment(id: "b", uin: "1", nickname: "A", content: "话2", createdAt: 2, replies: [])
        XCTAssertEqual(FeedParser.mergeComments([first, second]).count, 2)
    }

    func testCommentFieldsFallbacks() {
        let comment: [String: Any] = [
            "user": ["uin": "42", "nickname": "昵称"],
            "time": 1_700_000_000,
            "comment": "内容",
        ]
        XCTAssertEqual(FeedParser.commentContent(comment), "内容")
        XCTAssertEqual(FeedParser.commentUin(comment), "42")
        XCTAssertEqual(FeedParser.commentNickname(comment), "昵称")
        XCTAssertEqual(FeedParser.commentTime(comment), 1_700_000_000)
    }

    func testPlainTextRendererHandlesMention() {
        let rendered = QzoneTextFormatter.plain("：回复 @{uin:123,nick:小明} 的内容")
        XCTAssertEqual(rendered, "回复 @小明 的内容")
    }
}
