//
//  ArchiveRepositoryTests.swift
//  QzoneArchiveTests
//
//  归档仓库测试: 去重, 分页, 统计, 互动排行, 检查点
//

import XCTest
@testable import QzoneArchive

final class ArchiveRepositoryTests: XCTestCase {
    private var storage: FileStorageService!
    private var database: ArchiveDatabase!
    private var repository: SQLiteArchiveRepository!
    private var account: Account!

    override func setUp() {
        super.setUp()
        storage = FileStorageService()
        try? FileManager.default.createDirectory(
            at: storage.appDataRoot, withIntermediateDirectories: true
        )
        database = ArchiveDatabase()
        try? database.open()
        try? database.resetDatabase()
        repository = SQLiteArchiveRepository(database: database)
        account = Account(id: UUID(), qqUin: "123456789", nickname: "测试账号")
    }

    override func tearDown() {
        database.close()
        try? FileManager.default.removeItem(at: storage.appDataRoot)
        super.tearDown()
    }

    private func makePost(
        sourceID: String,
        content: String,
        uin: String? = "123456789",
        pictures: [String] = [],
        videos: [String] = []
    ) -> ArchivePost {
        ArchivePost(
            id: 0,
            accountID: account.id,
            sourceID: sourceID,
            authorUin: uin,
            authorName: "测试账号",
            contentText: content,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            archivedAt: Date(),
            postType: "text",
            sourceURL: nil,
            rawPayloadPath: nil,
            isDeleted: false,
            pictureURLs: pictures,
            videoURLs: videos,
            videoCoverURL: nil,
            likeCount: 0,
            commentCount: 0,
            category: uin == account.qqUin ? .self_ : .other,
            likes: [],
            comments: []
        )
    }

    func testSavePostsAndCount() throws {
        let inserted = try repository.savePosts([
            makePost(sourceID: "s1", content: "第一条"),
            makePost(sourceID: "s2", content: "第二条"),
        ], account: account)
        XCTAssertEqual(inserted, 2)
        XCTAssertEqual(try repository.countPosts(account: account, category: .self_), 2)
    }

    func testSavePostsIsIdempotent() throws {
        _ = try repository.savePosts([makePost(sourceID: "s1", content: "原文")], account: account)
        let again = try repository.savePosts([makePost(sourceID: "s1", content: "原文")], account: account)
        XCTAssertEqual(again, 1)
        XCTAssertEqual(try repository.countPosts(account: account, category: .self_), 1)
    }

    func testListPostsPagination() throws {
        var posts: [ArchivePost] = []
        for index in 0..<25 {
            posts.append(makePost(sourceID: "s\(index)", content: "内容\(index)"))
        }
        _ = try repository.savePosts(posts, account: account)
        let firstPage = try repository.listPosts(account: account, category: .self_, limit: 10, offset: 0)
        XCTAssertEqual(firstPage.count, 10)
        let lastPage = try repository.listPosts(account: account, category: .self_, limit: 10, offset: 20)
        XCTAssertEqual(lastPage.count, 5)
    }

    func testSearchFindsByKeyword() throws {
        _ = try repository.savePosts([
            makePost(sourceID: "s1", content: "今天去了西湖"),
            makePost(sourceID: "s2", content: "明天加班"),
        ], account: account)
        XCTAssertEqual(try repository.countSearchResults(account: account, keyword: "西湖"), 1)
        let found = try repository.searchPosts(account: account, keyword: "西湖", limit: 10, offset: 0)
        XCTAssertEqual(found.first?.sourceID, "s1")
    }

    func testOverviewAggregates() throws {
        _ = try repository.savePosts([
            makePost(sourceID: "s1", content: "a", pictures: ["https://e.com/a.jpg"]),
            makePost(sourceID: "s2", content: "b", pictures: ["https://e.com/b.jpg", "https://e.com/c.jpg"]),
            makePost(sourceID: "s3", content: "c", videos: ["https://e.com/v.mp4"]),
        ], account: account)
        let overview = try repository.overview(account: account, mediaBytes: 2048)
        XCTAssertEqual(overview.dynamics, 3)
        XCTAssertEqual(overview.pictures, 3)
        XCTAssertEqual(overview.videos, 1)
        XCTAssertEqual(overview.mediaBytes, 2048)
    }

    func testDeletePostsRemovesOnlyGivenIDs() throws {
        _ = try repository.savePosts([
            makePost(sourceID: "s1", content: "a"),
            makePost(sourceID: "s2", content: "b"),
        ], account: account)
        let posts = try repository.listPosts(account: account, category: .self_, limit: 10, offset: 0)
        let target = posts.first { $0.sourceID == "s1" }!
        let removed = try repository.deletePosts(account: account, ids: [target.id])
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try repository.countPosts(account: account, category: .self_), 1)
    }

    func testClearPostsWipesAll() throws {
        _ = try repository.savePosts([
            makePost(sourceID: "s1", content: "a"),
            makePost(sourceID: "s2", content: "b"),
        ], account: account)
        let removed = try repository.clearPosts(account: account)
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(try repository.countPosts(account: account, category: .self_), 0)
    }

    func testCheckpointRoundTrip() throws {
        try repository.saveCheckpoint(account: account, attachInfo: "att=abc", pages: 7, fetched: 140, saved: 132)
        let loaded = try repository.loadCheckpoint(account: account)
        XCTAssertEqual(loaded?.attachInfo, "att=abc")
        XCTAssertEqual(loaded?.pages, 7)
        XCTAssertEqual(loaded?.fetched, 140)
        XCTAssertEqual(loaded?.saved, 132)
        try repository.clearCheckpoint(account: account)
        XCTAssertNil(try repository.loadCheckpoint(account: account))
    }

    func testTaskUpsertAndLoad() throws {
        var task = ArchiveTask(accountID: account.id, taskType: "feed")
        task.status = .running
        task.currentPage = 12
        task.savedCount = 300
        try repository.upsertTask(task, account: account)
        let loaded = try repository.loadTask(account: account, taskType: "feed")
        XCTAssertEqual(loaded?.status, .running)
        XCTAssertEqual(loaded?.currentPage, 12)
        XCTAssertEqual(loaded?.savedCount, 300)
    }

    func testMediaTimelineReturnsItems() throws {
        _ = try repository.savePosts([
            makePost(sourceID: "s1", content: "a", pictures: ["https://e.com/a.jpg", "https://e.com/b.jpg"]),
        ], account: account)
        let page = try repository.mediaTimeline(account: account, limit: 50, offset: 0, year: nil)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.total, 2)
        XCTAssertFalse(page.years.isEmpty)
    }

    func testMediaTimelineFiltersByYear() throws {
        _ = try repository.savePosts([
            makePost(sourceID: "s1", content: "a", pictures: ["https://e.com/a.jpg"]),
        ], account: account)
        let wrongYear = try repository.mediaTimeline(
            account: account, limit: 50, offset: 0, year: 1999
        )
        XCTAssertTrue(wrongYear.items.isEmpty)
    }

    func testSkipRecordingAndResolution() throws {
        try repository.recordSkip(
            account: account, pageNumber: 3, cursorOffset: 100, offsetAdvance: 10,
            baseTime: 1_700_000_000, error: "临时失败", cursor: "att=x"
        )
        var skips = try repository.listSkips(account: account)
        XCTAssertEqual(skips.count, 1)
        let pending = try repository.listPendingSkipIDs(account: account)
        XCTAssertEqual(pending.count, 1)
        try repository.resolveSkip(account: account, id: pending[0], recoveredRecords: 5)
        skips = try repository.listSkips(account: account)
        XCTAssertEqual(skips.first?.recoveredRecords, 5)
    }

    func testInteractionRankingGroupsByAuthor() throws {
        var post = makePost(sourceID: "s1", content: "正文")
        post.likes = [LikeUser(uin: "999", nickname: "好友A"), LikeUser(uin: "888", nickname: "好友B")]
        post.comments = [
            ParsedComment(id: "c1", uin: "999", nickname: "好友A", content: "评论", createdAt: 1, replies: [])
                .toArchived(postID: post.sourceID)
        ]
        _ = try repository.savePosts([post], account: account)
        let ranking = try repository.interactionRanking(account: account, limit: 10)
        XCTAssertEqual(ranking.first?.uin, "999")
        XCTAssertEqual(ranking.first?.likes, 1)
        XCTAssertEqual(ranking.first?.comments, 1)
    }

    func testSaveFeedPageIsIdempotent() throws {
        // 同一页重复归档: 原始记录按 feed_key 去重, 评论/点赞与计数不重复累积
        let feeds: [[String: Any]] = [
            [
                "comm": ["time": 1_700_000_000, "subid": 1],
                "userinfo": ["user": ["uin": "123456789", "nickname": "测试账号"]],
                "original": [
                    "cell_id": ["cellid": "cell-1"],
                    "cell_comm": ["time": 1_700_000_000, "appid": 311, "feedskey": "feed-1"],
                    "cell_summary": ["summary": "自己的动态"],
                    "cell_userinfo": ["user": ["uin": "123456789", "nickname": "测试账号"]],
                ],
            ],
            [
                "comm": ["time": 1_700_000_100, "subid": 2],
                "userinfo": ["user": ["uin": "888", "nickname": "评论人"]],
                "summary": ["summary": "评论了你的动态"],
                "original": [
                    "cell_id": ["cellid": "cell-1"],
                    "cell_comm": ["time": 1_700_000_000, "appid": 311],
                    "cell_comment": [
                        "main_comment": [
                            "commentid": "c1",
                            "user": ["uin": "888", "nickname": "评论人"],
                            "content": "你好",
                            "date": 1_700_000_100,
                        ],
                    ],
                ],
            ],
            [
                "comm": ["time": 1_700_000_200, "subid": 217],
                "userinfo": ["user": ["uin": "999", "nickname": "点赞人"]],
                "original": [
                    "cell_id": ["cellid": "cell-1"],
                    "cell_comm": ["time": 1_700_000_000, "appid": 311],
                ],
            ],
        ]

        XCTAssertEqual(try repository.saveFeedPage(feeds, account: account), 3)
        let first = try repository.fetchPost(account: account, id: 1)
        let dbg = try database.executeQuery(
            "SELECT feed_key, cell_id, event_type FROM archive_feed_records",
            arguments: []
        )
        print("DBG records:", dbg.count)
        for row in dbg { print("DBG row:", row) }
        let dbg2 = try database.executeQuery("SELECT id, account_id, post_id, content_text FROM comments", arguments: [])
        print("DBG comments rows:", dbg2.count, dbg2)
        XCTAssertEqual(first.commentCount, 1)
        XCTAssertEqual(first.likeCount, 1)
        XCTAssertEqual(first.comments.count, 1)
        XCTAssertEqual(first.comments.first?.contentText, "你好")

        XCTAssertEqual(try repository.saveFeedPage(feeds, account: account), 3)
        let second = try repository.fetchPost(account: account, id: 1)
        XCTAssertEqual(second.commentCount, 1, "重复归档不应重复计数")
        XCTAssertEqual(second.likeCount, 1)
        XCTAssertEqual(second.comments.count, 1, "重复归档不应重复插入评论")
        XCTAssertEqual(second.likes.count, 1, "重复归档不应重复插入点赞")

        // 分页到达时只带来新评论, 计数应累加而不是被覆盖
        let moreComment: [String: Any] = [
            "comm": ["time": 1_700_000_300, "subid": 2],
            "userinfo": ["user": ["uin": "777", "nickname": "另一位"]],
            "summary": ["summary": "评论了你的动态"],
            "original": [
                "cell_id": ["cellid": "cell-1"],
                "cell_comm": ["time": 1_700_000_000, "appid": 311],
                "cell_comment": [
                    "main_comment": [
                        "commentid": "c2",
                        "user": ["uin": "777", "nickname": "另一位"],
                        "content": "第二条评论",
                        "date": 1_700_000_300,
                    ],
                ],
            ],
        ]
        _ = try repository.saveFeedPage([moreComment], account: account)
        let third = try repository.fetchPost(account: account, id: 1)
        XCTAssertEqual(third.commentCount, 2, "后续页面的评论应累加到同一条动态")
        XCTAssertEqual(third.comments.count, 2)
    }
}
