//
//  ArchiveRepository.swift
//  QzoneArchive
//
//  归档仓库: 账号, 动态, 互动, 任务, 游标, 频率保护的读写
//

import Foundation

/// 归档仓库协议
protocol ArchiveRepository {
    func loadActiveAccount() throws -> Account?
    func saveAccount(_ account: Account) throws
    func listAccounts() throws -> [Account]
    func deleteAccount(uin: String) throws

    func savePosts(_ posts: [ArchivePost], account: Account) throws -> Int
    func saveFeedPage(_ feeds: [[String: Any]], account: Account) throws -> Int
    func listPosts(
        account: Account,
        category: ArchiveCategory,
        limit: Int,
        offset: Int
    ) throws -> [ArchivePost]
    func countPosts(account: Account, category: ArchiveCategory) throws -> Int
    func fetchPost(account: Account, id: Int) throws -> ArchivePost
    func deletePosts(account: Account, ids: [Int]) throws -> Int
    func clearPosts(account: Account) throws -> Int
    func searchPosts(account: Account, keyword: String, limit: Int, offset: Int) throws -> [ArchivePost]
    func countSearchResults(account: Account, keyword: String) throws -> Int

    func overview(account: Account, mediaBytes: Int64) throws -> ArchiveOverview
    func interactionRanking(account: Account, limit: Int) throws -> [InteractionRank]
    func mediaTimeline(
        account: Account,
        limit: Int,
        offset: Int,
        year: Int?
    ) throws -> MediaTimelinePage

    func saveCheckpoint(account: Account, attachInfo: String, pages: Int, fetched: Int, saved: Int) throws
    func loadCheckpoint(account: Account) throws -> (attachInfo: String, pages: Int, fetched: Int, saved: Int, updatedAt: Date)?
    func clearCheckpoint(account: Account) throws
    func checkpointIsStale(account: Account) throws -> Bool

    func saveRateWindow(account: Account, startedAt: Date, pages: Int, retryAt: Date?) throws
    func loadRateWindow(account: Account) throws -> (startedAt: Date, pages: Int, retryAt: Date?)?
    func clearRateWindow(account: Account) throws

    func recordSkip(account: Account, pageNumber: Int, cursorOffset: Int, offsetAdvance: Int,
                    baseTime: Int, error: String, cursor: String) throws
    func listSkips(account: Account) throws -> [ArchiveSkipRow]
    func listPendingSkipIDs(account: Account) throws -> [Int]
    func resolveSkip(account: Account, id: Int, recoveredRecords: Int) throws
    func failSkip(account: Account, id: Int, error: String) throws
    func clearResolvedSkips(account: Account) throws

    func upsertTask(_ task: ArchiveTask, account: Account) throws
    func loadTask(account: Account, taskType: String) throws -> ArchiveTask?
    func clearTasks(account: Account) throws
    func saveFailure(taskID: UUID, account: Account, type: TaskFailure.ResourceType,
                     resourceID: String, code: String?, message: String) throws
    func listFailures(account: Account, resolved: Bool) throws -> [TaskFailure]
    func resolveFailure(id: UUID) throws
}

/// 异常跳过记录
struct ArchiveSkipRow {
    var id: Int
    var pageNumber: Int
    var cursorOffset: Int
    var offsetAdvance: Int
    var baseTime: Int
    var error: String
    var skippedAt: Date
    var retryCount: Int
    var lastRetryAt: Date?
    var resolvedAt: Date?
    var recoveredRecords: Int
    var cursor: String
}

/// SQLite 实现
final class SQLiteArchiveRepository: ArchiveRepository {
    private let database: ArchiveDatabase
    private let storage: FileStorageService
    private let logger = AppLogger()

    init(database: ArchiveDatabase, storage: FileStorageService = FileStorageService()) {
        self.database = database
        self.storage = storage
        try? database.open()
    }

    // MARK: - 账号

    func loadActiveAccount() throws -> Account? {
        let rows = try self.database.executeQuery(
            "SELECT * FROM accounts WHERE is_active=1 ORDER BY last_login_at DESC LIMIT 1",
            arguments: []
        )
        return rows.first.map { Self.account(from: $0) }
    }

    func saveAccount(_ account: Account) throws {
        _ = try self.database.executeUpdate(
            "UPDATE accounts SET is_active=0 WHERE qq_uin<>?",
            arguments: [account.qqUin]
        )
        _ = try self.database.executeUpdate(
            """
            INSERT INTO accounts (id, qq_uin, nickname, avatar_url, last_login_at, created_at, updated_at, is_active)
            VALUES (?,?,?,?,?,?,?,1)
            ON CONFLICT(qq_uin) DO UPDATE SET
              id=excluded.id, nickname=excluded.nickname, avatar_url=excluded.avatar_url,
              last_login_at=excluded.last_login_at, updated_at=excluded.updated_at, is_active=1
            """,
            arguments: [
                account.id, account.qqUin, account.nickname, account.avatarURL,
                account.lastLoginAt, account.createdAt, Date(),
            ]
        )
    }

    func listAccounts() throws -> [Account] {
        let rows = try self.database.executeQuery(
            "SELECT * FROM accounts ORDER BY last_login_at DESC",
            arguments: []
        )
        return rows.map { Self.account(from: $0) }
    }

    func deleteAccount(uin: String) throws {
        _ = try self.database.executeUpdate("DELETE FROM accounts WHERE qq_uin=?", arguments: [uin])
        _ = try self.database.executeUpdate("DELETE FROM archive_posts WHERE account_id=?", arguments: [uin])
        _ = try self.database.executeUpdate("DELETE FROM media_assets WHERE account_id=?", arguments: [uin])
        _ = try self.database.executeUpdate("DELETE FROM comments WHERE account_id=?", arguments: [uin])
        _ = try self.database.executeUpdate("DELETE FROM likes WHERE account_id=?", arguments: [uin])
        _ = try self.database.executeUpdate("DELETE FROM archive_tasks WHERE account_id=?", arguments: [uin])
        _ = try self.database.executeUpdate("DELETE FROM archive_skips WHERE account_id=?", arguments: [uin])
        _ = try self.database.executeUpdate("DELETE FROM archive_checkpoints WHERE account_id=?", arguments: [uin])
        _ = try self.database.executeUpdate("DELETE FROM archive_rate_limits WHERE account_id=?", arguments: [uin])
    }

    private static func account(from row: [String: Any]) -> Account {
        Account(
            id: UUID(uuidString: row["id"] as? String ?? "") ?? UUID(),
            qqUin: row["qq_uin"] as? String ?? "",
            nickname: row["nickname"] as? String,
            avatarURL: row["avatar_url"] as? String,
            lastLoginAt: (row["last_login_at"] as? Double).map { Date(timeIntervalSince1970: $0) },
            createdAt: (row["created_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date(),
            updatedAt: (row["updated_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        )
    }

    // MARK: - 动态

    func savePosts(_ posts: [ArchivePost], account: Account) throws -> Int {
        guard !posts.isEmpty else { return 0 }
        return try self.database.inTransaction {
            var saved = 0
            for post in posts {
                saved += try self.upsertPost(post, account: account)
                try self.saveLikes(account: account, post: post)
                try self.saveComments(account: account, post: post)
                try self.updateInteractionCounts(
                    account: account,
                    cellID: post.sourceID,
                    likeCount: post.likes.count,
                    commentCount: post.comments.count
                )
            }
            return saved
        }
    }

    /// 写入一页原始互动记录, 再由记录派生动态、评论、点赞与计数
    ///
    /// 与桌面端 savePage 对应: 原始记录按 feed_key 唯一落库, 动态与互动都是派生结果,
    /// 因此重复归档同一页既不会重复评论也不会重复点赞, 计数始终等于记录条数
    func saveFeedPage(_ feeds: [[String: Any]], account: Account) throws -> Int {
        guard !feeds.isEmpty else { return 0 }
        return try self.database.inTransaction {
            var touched: [String] = []
            var seen = Set<String>()
            for feed in feeds {
                let parsed = FeedParser.parseFeed(feed)
                let dynamic = FeedParser.parseOriginalDynamic(feed, ownerUin: account.qqUin)
                let cellID = dynamic?.cellID ?? (parsed.cellID.isEmpty ? nil : parsed.cellID)
                let raw = FeedParser.stableJSON(feed) ?? "{}"
                _ = try self.database.executeUpdate(
                    """
                    INSERT INTO archive_feed_records
                     (account_id, feed_key, cell_id, event_type, event_time, event_summary,
                      actor_uin, actor_name, original_author_uin, original_author_name,
                      picture_count, pictures_json, video_json, comments_json, raw_json, archived_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(account_id, feed_key) DO UPDATE SET
                      cell_id=excluded.cell_id, event_type=excluded.event_type,
                      event_time=excluded.event_time, event_summary=excluded.event_summary,
                      actor_uin=excluded.actor_uin, actor_name=excluded.actor_name,
                      original_author_uin=excluded.original_author_uin,
                      original_author_name=excluded.original_author_name,
                      picture_count=excluded.picture_count, pictures_json=excluded.pictures_json,
                      video_json=excluded.video_json, comments_json=excluded.comments_json,
                      raw_json=excluded.raw_json, archived_at=excluded.archived_at
                    """,
                    arguments: [
                        account.qqUin, parsed.feedKey, cellID, parsed.eventType, parsed.eventTime,
                        parsed.eventSummary, parsed.actorUin, parsed.actorName,
                        dynamic?.authorUin, dynamic?.authorName, dynamic?.pictureCount ?? 0,
                        dynamic?.picturesJSON, dynamic?.videoJSON, parsed.commentsJSON,
                        raw, Date(),
                    ]
                )
                if let cellID, seen.insert(cellID).inserted { touched.append(cellID) }
            }

            let posts = FeedParser.parsePosts(feeds, account: account)
            for post in posts {
                _ = try self.upsertPost(post, account: account)
            }
            for cellID in touched {
                try self.rebuildInteractions(account: account, cellID: cellID)
            }
            return feeds.count
        }
    }

    /// 单条动态 upsert, 冲突时图片与视频保留库中已有的非空值
    private func upsertPost(_ post: ArchivePost, account: Account) throws -> Int {
        try self.database.executeUpdate(
            """
            INSERT INTO archive_posts
             (account_id, source_id, author_uin, author_name, content_text, published_at,
              archived_at, post_type, source_url, raw_payload_path, is_deleted,
              picture_urls_json, video_urls_json, video_cover_url, like_count, comment_count,
              category, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(account_id, source_id) DO UPDATE SET
              author_uin=COALESCE(excluded.author_uin, archive_posts.author_uin),
              author_name=COALESCE(excluded.author_name, archive_posts.author_name),
              content_text=COALESCE(NULLIF(excluded.content_text,''), archive_posts.content_text),
              published_at=CASE WHEN excluded.published_at > 0
                                THEN excluded.published_at ELSE archive_posts.published_at END,
              archived_at=excluded.archived_at,
              post_type=COALESCE(excluded.post_type, archive_posts.post_type),
              source_url=COALESCE(excluded.source_url, archive_posts.source_url),
              raw_payload_path=COALESCE(excluded.raw_payload_path, archive_posts.raw_payload_path),
              picture_urls_json=COALESCE(NULLIF(excluded.picture_urls_json,'[]'),
                                         archive_posts.picture_urls_json),
              video_urls_json=COALESCE(NULLIF(excluded.video_urls_json,'[]'),
                                       archive_posts.video_urls_json),
              video_cover_url=COALESCE(excluded.video_cover_url, archive_posts.video_cover_url),
              category=excluded.category, updated_at=excluded.updated_at
            """,
            arguments: [
                account.qqUin, post.sourceID, post.authorUin, post.authorName,
                post.contentText, post.publishedAt, post.archivedAt, post.postType,
                post.sourceURL, post.rawPayloadPath, post.isDeleted ? 1 : 0,
                try Self.jsonText(post.pictureURLs), try Self.jsonText(post.videoURLs),
                post.videoCoverURL, post.likeCount, post.commentCount,
                post.category.raw, post.archivedAt, Date(),
            ]
        )
    }

    /// 按原始互动记录重建某条动态的评论、点赞与计数 (与原版查询语义一致)
    private func rebuildInteractions(account: Account, cellID: String) throws {
        let commentRows = try self.database.executeQuery(
            """
            SELECT comments_json, actor_uin, actor_name, event_summary, event_time
            FROM archive_feed_records
            WHERE account_id=? AND cell_id=? AND event_type IN (?,?)
            ORDER BY event_time ASC, id ASC
            """,
            arguments: [account.qqUin, cellID, FeedParser.eventTypeComment, FeedParser.eventTypeCommentAlt]
        )
        var parsedComments: [ParsedComment] = []
        for row in commentRows {
            parsedComments.append(
                FeedParser.commentFromValues(
                    commentsJSON: row["comments_json"] as? String,
                    actorUin: row["actor_uin"] as? String,
                    actorName: row["actor_name"] as? String,
                    eventSummary: row["event_summary"] as? String,
                    eventTime: Self.int(row["event_time"])
                )
            )
        }
        let merged = FeedParser.mergeComments(parsedComments)
        let likeRows = try self.database.executeQuery(
            """
            SELECT feed_key, actor_uin, actor_name FROM archive_feed_records
            WHERE account_id=? AND cell_id=? AND event_type=?
            ORDER BY event_time ASC, id ASC
            """,
            arguments: [account.qqUin, cellID, FeedParser.eventTypeLike]
        )

        _ = try self.database.executeUpdate(
            "DELETE FROM comments WHERE account_id=? AND post_id=?",
            arguments: [account.qqUin, cellID]
        )
        _ = try self.database.executeUpdate(
            "DELETE FROM likes WHERE account_id=? AND post_id=?",
            arguments: [account.qqUin, cellID]
        )
        for comment in merged {
            let archived = comment.toArchived(postID: cellID)
            try self.insertComment(account: account, postID: cellID, comment: archived)
        }
        for (index, row) in likeRows.enumerated() {
            let uin = row["actor_uin"] as? String
            let nickname = row["actor_name"] as? String
            // 与原版一致: 点赞按记录条数计, 同一人多次点赞保留多条记录
            let feedKey = row["feed_key"] as? String ?? "like-\(index)"
            let id = Self.rowID(parts: [account.qqUin, cellID, feedKey])
            _ = try self.database.executeUpdate(
                """
                INSERT INTO likes (id, account_id, post_id, author_uin, author_name, created_at)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET author_name=excluded.author_name
                """,
                arguments: [id, account.qqUin, cellID, uin, nickname, Date()]
            )
        }
        try self.updateInteractionCounts(
            account: account,
            cellID: cellID,
            likeCount: likeRows.count,
            commentCount: commentRows.count
        )
    }

    /// 计数与桌面端 SQL 的 COUNT(*) 一致: 评论数按互动记录条数, 不是合并后的评论条数
    private func updateInteractionCounts(
        account: Account,
        cellID: String,
        likeCount: Int,
        commentCount: Int
    ) throws {
        _ = try self.database.executeUpdate(
            "UPDATE archive_posts SET like_count=?, comment_count=?, updated_at=? WHERE account_id=? AND source_id=?",
            arguments: [likeCount, commentCount, Date(), account.qqUin, cellID]
        )
    }

    private func saveLikes(account: Account, post: ArchivePost) throws {
        for (index, like) in post.likes.enumerated() {
            let id = Self.rowID(parts: [account.qqUin, post.sourceID, like.uin ?? "like-\(index)"])
            _ = try self.database.executeUpdate(
                """
                INSERT INTO likes (id, account_id, post_id, author_uin, author_name, created_at)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET author_name=excluded.author_name
                """,
                arguments: [id, account.qqUin, post.sourceID, like.uin, like.nickname, Date()]
            )
        }
    }

    private func saveComments(account: Account, post: ArchivePost) throws {
        for comment in post.comments {
            try self.insertComment(account: account, postID: post.sourceID, comment: comment)
        }
    }

    /// 评论与回复的写入, 主键由 (账号, 动态, 评论标识) 稳定推导, 重复归档只更新不新增
    private func insertComment(account: Account, postID: String, comment: ArchivedComment) throws {
        let baseID = Self.rowID(parts: [account.qqUin, postID, comment.id])
        _ = try self.database.executeUpdate(
            """
            INSERT INTO comments
             (id, account_id, post_id, parent_id, author_uin, author_name, content_text, published_at, created_at)
            VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              author_uin=excluded.author_uin, author_name=excluded.author_name,
              content_text=excluded.content_text, published_at=excluded.published_at
            """,
            arguments: [
                baseID, account.qqUin, postID, comment.parentID,
                comment.authorUin, comment.authorName, comment.contentText,
                comment.publishedAt, comment.createdAt,
            ]
        )
        for reply in comment.replies {
            let replyID = Self.rowID(parts: [
                baseID, reply.uin ?? "", String(reply.createdAt), reply.content,
            ])
            _ = try self.database.executeUpdate(
                """
                INSERT INTO comments
                 (id, account_id, post_id, parent_id, author_uin, author_name, content_text, published_at, created_at)
                VALUES (?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  author_uin=excluded.author_uin, author_name=excluded.author_name,
                  content_text=excluded.content_text, published_at=excluded.published_at
                """,
                arguments: [
                    replyID, account.qqUin, postID, baseID,
                    reply.uin, reply.nickname, reply.content,
                    Date(timeIntervalSince1970: TimeInterval(reply.createdAt)), Date(),
                ]
            )
        }
    }

    /// 稳定行标识: 由若干字段拼接后取 FNV-1a 十六进制, 同一输入始终得到同一主键
    static func rowID(parts: [String]) -> String {
        FeedParser.formatFeedHash(FeedParser.stableFeedHash(parts))
    }

    func listPosts(account: Account, category: ArchiveCategory, limit: Int, offset: Int) throws -> [ArchivePost] {
        let rows = try self.database.executeQuery(
            """
            SELECT * FROM archive_posts
            WHERE account_id=? AND category=?
            ORDER BY published_at ASC, id ASC LIMIT ? OFFSET ?
            """,
            arguments: [account.qqUin, category.raw, max(1, limit), max(0, offset)]
        )
        return try rows.map { try post(from: $0, account: account) }
    }

    func countPosts(account: Account, category: ArchiveCategory) throws -> Int {
        let rows = try self.database.executeQuery(
            "SELECT COUNT(*) AS total FROM archive_posts WHERE account_id=? AND category=?",
            arguments: [account.qqUin, category.raw]
        )
        return Self.int(rows.first?["total"])
    }

    func fetchPost(account: Account, id: Int) throws -> ArchivePost {
        let rows = try self.database.executeQuery(
            "SELECT * FROM archive_posts WHERE account_id=? AND id=?",
            arguments: [account.qqUin, id]
        )
        guard let row = rows.first else { throw QzoneError.unknown("原始动态不存在或已删除") }
        return try post(from: row, account: account)
    }

    func deletePosts(account: Account, ids: [Int]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try self.database.inTransaction {
            var count = 0
            for id in ids {
                _ = try self.database.executeUpdate(
                    "DELETE FROM comments WHERE account_id=? AND post_id=(SELECT source_id FROM archive_posts WHERE account_id=? AND id=?)",
                    arguments: [account.qqUin, account.qqUin, id]
                )
                _ = try self.database.executeUpdate(
                    "DELETE FROM likes WHERE account_id=? AND post_id=(SELECT source_id FROM archive_posts WHERE account_id=? AND id=?)",
                    arguments: [account.qqUin, account.qqUin, id]
                )
                _ = try self.database.executeUpdate(
                    "DELETE FROM media_assets WHERE account_id=? AND post_id=(SELECT source_id FROM archive_posts WHERE account_id=? AND id=?)",
                    arguments: [account.qqUin, account.qqUin, id]
                )
                _ = try self.database.executeUpdate(
                    "DELETE FROM archive_feed_records WHERE account_id=? AND cell_id=(SELECT source_id FROM archive_posts WHERE account_id=? AND id=?)",
                    arguments: [account.qqUin, account.qqUin, id]
                )
                count += try self.database.executeUpdate(
                    "DELETE FROM archive_posts WHERE account_id=? AND id=?",
                    arguments: [account.qqUin, id]
                )
            }
            return count
        }
    }

    func clearPosts(account: Account) throws -> Int {
        try self.database.inTransaction {
            let count = try self.database.executeUpdate(
                "DELETE FROM archive_posts WHERE account_id=?",
                arguments: [account.qqUin]
            )
            _ = try self.database.executeUpdate("DELETE FROM comments WHERE account_id=?", arguments: [account.qqUin])
            _ = try self.database.executeUpdate("DELETE FROM likes WHERE account_id=?", arguments: [account.qqUin])
            _ = try self.database.executeUpdate("DELETE FROM archive_feed_records WHERE account_id=?", arguments: [account.qqUin])
            _ = try self.database.executeUpdate("DELETE FROM media_assets WHERE account_id=?", arguments: [account.qqUin])
            _ = try self.database.executeUpdate("DELETE FROM archive_checkpoints WHERE account_id=?", arguments: [account.qqUin])
            _ = try self.database.executeUpdate("DELETE FROM archive_rate_limits WHERE account_id=?", arguments: [account.qqUin])
            return count
        }
    }

    func searchPosts(account: Account, keyword: String, limit: Int, offset: Int) throws -> [ArchivePost] {
        let pattern = "%\(keyword)%"
        let rows = try self.database.executeQuery(
            """
            SELECT * FROM archive_posts
            WHERE account_id=? AND content_text LIKE ?
            ORDER BY published_at ASC, id ASC LIMIT ? OFFSET ?
            """,
            arguments: [account.qqUin, pattern, max(1, limit), max(0, offset)]
        )
        return try rows.map { try post(from: $0, account: account) }
    }

    func countSearchResults(account: Account, keyword: String) throws -> Int {
        let pattern = "%\(keyword)%"
        let rows = try self.database.executeQuery(
            "SELECT COUNT(*) AS total FROM archive_posts WHERE account_id=? AND content_text LIKE ?",
            arguments: [account.qqUin, pattern]
        )
        return Self.int(rows.first?["total"])
    }

    // MARK: - 统计

    func overview(account: Account, mediaBytes: Int64) throws -> ArchiveOverview {
        let dynamics = try Self.int(
            database.executeQuery(
                "SELECT COUNT(*) AS total FROM archive_posts WHERE account_id=?",
                arguments: [account.qqUin]
            ).first?["total"]
        )
        let interaction = try self.database.executeQuery(
            """
            SELECT COALESCE(SUM(CASE WHEN 1=1 THEN 1 ELSE 0 END),0) AS likes FROM likes WHERE account_id=?
            """,
            arguments: [account.qqUin]
        ).first
        let likes = Self.int(interaction?["likes"])
        let comments = try Self.int(
            database.executeQuery(
                "SELECT COUNT(*) AS total FROM comments WHERE account_id=?",
                arguments: [account.qqUin]
            ).first?["total"]
        )
        let mediaRows = try self.database.executeQuery(
            "SELECT picture_urls_json, video_urls_json FROM archive_posts WHERE account_id=?",
            arguments: [account.qqUin]
        )
        // 统计媒体总数 (原项目按媒体条目计数, 不是按动态条数)
        let decodeURLs: (Any?) -> [String] = { value in
            guard let json = value as? String, let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return decoded
        }
        var pictures = 0
        var videos = 0
        for row in mediaRows {
            pictures += decodeURLs(row["picture_urls_json"]).count
            videos += decodeURLs(row["video_urls_json"]).count
        }
        return ArchiveOverview(
            dynamics: dynamics,
            pictures: pictures,
            videos: videos,
            comments: comments,
            likes: likes,
            databaseBytes: databaseFileSize(),
            mediaBytes: mediaBytes
        )
    }

    func interactionRanking(account: Account, limit: Int) throws -> [InteractionRank] {
        let rows = try self.database.executeQuery(
            """
            SELECT uin,
                   COALESCE(NULLIF(MAX(nickname),''), uin) AS nickname,
                   SUM(liked) AS likes,
                   SUM(commented) AS comments,
                   SUM(liked + commented) AS interactions
            FROM (
              SELECT author_uin AS uin, author_name AS nickname, 0 AS liked, 1 AS commented
              FROM comments WHERE account_id=? AND author_uin IS NOT NULL AND author_uin<>'' AND author_uin<>?
              UNION ALL
              SELECT author_uin AS uin, author_name AS nickname, 1 AS liked, 0 AS commented
              FROM likes WHERE account_id=? AND author_uin IS NOT NULL AND author_uin<>'' AND author_uin<>?
            )
            GROUP BY uin ORDER BY interactions DESC LIMIT ?
            """,
            arguments: [account.qqUin, account.qqUin, account.qqUin, account.qqUin, max(1, limit)]
        )
        return rows.map { row in
            InteractionRank(
                uin: row["uin"] as? String ?? "",
                nickname: row["nickname"] as? String ?? "",
                interactions: Self.int(row["interactions"]),
                likes: Self.int(row["likes"]),
                comments: Self.int(row["comments"])
            )
        }
    }

    func mediaTimeline(account: Account, limit: Int, offset: Int, year: Int?) throws -> MediaTimelinePage {
        var arguments: [Any?] = [account.qqUin]
        var yearFilter = ""
        if let year {
            yearFilter = "AND CAST(strftime('%Y', published_at, 'unixepoch') AS INTEGER)=?"
            arguments.append(year)
        }
        let yearRows = try self.database.executeQuery(
            """
            SELECT DISTINCT CAST(strftime('%Y', published_at, 'unixepoch') AS INTEGER) AS year
            FROM archive_posts
            WHERE account_id=? AND category IN ('self','other')
              AND (picture_urls_json IS NOT NULL OR video_urls_json IS NOT NULL)
            ORDER BY 1 DESC
            """,
            arguments: [account.qqUin]
        )
        let years = yearRows.compactMap { Self.intOrNil($0["year"]) }

        arguments.append(max(1, limit))
        arguments.append(max(0, offset))
        let rows = try self.database.executeQuery(
            """
            SELECT id, published_at, content_text, author_uin, author_name,
                   picture_urls_json, video_urls_json, video_cover_url
            FROM archive_posts
            WHERE account_id=? AND category IN ('self','other')
              AND (picture_urls_json IS NOT NULL OR video_urls_json IS NOT NULL)
              \(yearFilter)
            ORDER BY published_at ASC, id ASC LIMIT ? OFFSET ?
            """,
            arguments: arguments
        )
        var items: [MediaTimelineItem] = []
        for row in rows {
            let id = Self.int(row["id"])
            let publishedAt = Self.doubleOrNil(row["published_at"]).map { Date(timeIntervalSince1970: $0) }
            let content = row["content_text"] as? String
            let authorUin = row["author_uin"] as? String
            let authorName = row["author_name"] as? String
            let pictures = Self.jsonStrings(row["picture_urls_json"])
            for (index, url) in pictures.enumerated() {
                items.append(MediaTimelineItem(
                    key: "\(id)-photo-\(index)",
                    dynamicID: id,
                    mediaType: .image,
                    pictureIndex: index,
                    url: url,
                    coverURL: nil,
                    publishedAt: publishedAt,
                    authorUin: authorUin,
                    authorName: authorName,
                    content: content
                ))
            }
            let videos = Self.jsonStrings(row["video_urls_json"])
            for (index, video) in videos.enumerated() {
                items.append(MediaTimelineItem(
                    key: "\(id)-video-\(index)",
                    dynamicID: id,
                    mediaType: .video,
                    pictureIndex: nil,
                    url: video,
                    coverURL: row["video_cover_url"] as? String,
                    publishedAt: publishedAt,
                    authorUin: authorUin,
                    authorName: authorName,
                    content: content
                ))
            }
        }
        let countRows = try self.database.executeQuery(
            """
            SELECT picture_urls_json, video_urls_json FROM archive_posts
            WHERE account_id=? AND category IN ('self','other')
              AND (picture_urls_json IS NOT NULL OR video_urls_json IS NOT NULL)
              \(yearFilter)
            """,
            arguments: Array(arguments.dropLast(2))
        )
        // 总数按媒体条目计, 不是按动态条数
        let total = countRows.reduce(0) { partial, row in
            partial
                + Self.jsonStrings(row["picture_urls_json"]).count
                + Self.jsonStrings(row["video_urls_json"]).count
        }
        return MediaTimelinePage(items: items, total: total, years: years)
    }

    // MARK: - 游标与频率

    func saveCheckpoint(account: Account, attachInfo: String, pages: Int, fetched: Int, saved: Int) throws {
        _ = try self.database.executeUpdate(
            """
            INSERT INTO archive_checkpoints (account_id, attach_info, pages, fetched, saved, updated_at)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(account_id) DO UPDATE SET
              attach_info=excluded.attach_info, pages=excluded.pages,
              fetched=excluded.fetched, saved=excluded.saved, updated_at=excluded.updated_at
            """,
            arguments: [account.qqUin, attachInfo, pages, fetched, saved, Date()]
        )
    }

    func loadCheckpoint(account: Account) throws -> (attachInfo: String, pages: Int, fetched: Int, saved: Int, updatedAt: Date)? {
        let rows = try self.database.executeQuery(
            "SELECT * FROM archive_checkpoints WHERE account_id=?",
            arguments: [account.qqUin]
        )
        guard let row = rows.first,
              let attach = row["attach_info"] as? String,
              let updated = Self.doubleOrNil(row["updated_at"])
        else { return nil }
        return (attach, Self.int(row["pages"]), Self.int(row["fetched"]), Self.int(row["saved"]), Date(timeIntervalSince1970: updated))
    }

    func clearCheckpoint(account: Account) throws {
        _ = try self.database.executeUpdate(
            "DELETE FROM archive_checkpoints WHERE account_id=?",
            arguments: [account.qqUin]
        )
    }

    func checkpointIsStale(account: Account) throws -> Bool {
        guard let checkpoint = try loadCheckpoint(account: account) else { return false }
        return Date().timeIntervalSince(checkpoint.updatedAt) > 10 * 60
    }

    func saveRateWindow(account: Account, startedAt: Date, pages: Int, retryAt: Date?) throws {
        _ = try self.database.executeUpdate(
            """
            INSERT INTO archive_rate_limits (account_id, window_started_at, pages, retry_at)
            VALUES (?,?,?,?)
            ON CONFLICT(account_id) DO UPDATE SET
              window_started_at=excluded.window_started_at, pages=excluded.pages, retry_at=excluded.retry_at
            """,
            arguments: [account.qqUin, startedAt, pages, retryAt]
        )
    }

    func loadRateWindow(account: Account) throws -> (startedAt: Date, pages: Int, retryAt: Date?)? {
        let rows = try self.database.executeQuery(
            "SELECT * FROM archive_rate_limits WHERE account_id=?",
            arguments: [account.qqUin]
        )
        guard let row = rows.first, let started = Self.doubleOrNil(row["window_started_at"]) else { return nil }
        let retry = Self.doubleOrNil(row["retry_at"]).map { Date(timeIntervalSince1970: $0) }
        return (Date(timeIntervalSince1970: started), Self.int(row["pages"]), retry)
    }

    func clearRateWindow(account: Account) throws {
        _ = try self.database.executeUpdate(
            "DELETE FROM archive_rate_limits WHERE account_id=?",
            arguments: [account.qqUin]
        )
    }

    // MARK: - 异常跳过

    func recordSkip(account: Account, pageNumber: Int, cursorOffset: Int, offsetAdvance: Int,
                    baseTime: Int, error: String, cursor: String) throws {
        _ = try self.database.executeUpdate(
            """
            INSERT INTO archive_skips
             (account_id, page_number, cursor_offset, offset_advance, base_time, error, skipped_at, cursor)
            VALUES (?,?,?,?,?,?,?,?)
            """,
            arguments: [account.qqUin, pageNumber, cursorOffset, offsetAdvance, baseTime, error, Date(), cursor]
        )
    }

    func listSkips(account: Account) throws -> [ArchiveSkipRow] {
        let rows = try self.database.executeQuery(
            "SELECT * FROM archive_skips WHERE account_id=? ORDER BY skipped_at ASC",
            arguments: [account.qqUin]
        )
        return rows.map { row in
            ArchiveSkipRow(
                id: Self.int(row["id"]),
                pageNumber: Self.int(row["page_number"]),
                cursorOffset: Self.int(row["cursor_offset"]),
                offsetAdvance: Self.int(row["offset_advance"]),
                baseTime: Self.int(row["base_time"]),
                error: row["error"] as? String ?? "",
                skippedAt: Date(timeIntervalSince1970: Self.double(row["skipped_at"])),
                retryCount: Self.int(row["retry_count"]),
                lastRetryAt: Self.doubleOrNil(row["last_retry_at"]).map { Date(timeIntervalSince1970: $0) },
                resolvedAt: Self.doubleOrNil(row["resolved_at"]).map { Date(timeIntervalSince1970: $0) },
                recoveredRecords: Self.int(row["recovered_records"]),
                cursor: row["cursor"] as? String ?? ""
            )
        }
    }

    func listPendingSkipIDs(account: Account) throws -> [Int] {
        let rows = try self.database.executeQuery(
            "SELECT id FROM archive_skips WHERE account_id=? AND resolved_at IS NULL ORDER BY skipped_at ASC",
            arguments: [account.qqUin]
        )
        return rows.map { Self.int($0["id"]) }
    }

    func resolveSkip(account: Account, id: Int, recoveredRecords: Int) throws {
        _ = try self.database.executeUpdate(
            """
            UPDATE archive_skips SET retry_count=retry_count+1, last_retry_at=?,
              resolved_at=?, recovered_records=? WHERE id=? AND account_id=?
            """,
            arguments: [Date(), Date(), recoveredRecords, id, account.qqUin]
        )
    }

    func failSkip(account: Account, id: Int, error: String) throws {
        _ = try self.database.executeUpdate(
            "UPDATE archive_skips SET retry_count=retry_count+1, last_retry_at=?, error=? WHERE id=? AND account_id=?",
            arguments: [Date(), error, id, account.qqUin]
        )
    }

    func clearResolvedSkips(account: Account) throws {
        _ = try self.database.executeUpdate(
            "DELETE FROM archive_skips WHERE account_id=? AND resolved_at IS NOT NULL",
            arguments: [account.qqUin]
        )
    }

    // MARK: - 任务

    func upsertTask(_ task: ArchiveTask, account: Account) throws {
        _ = try self.database.executeUpdate(
            """
            INSERT INTO archive_tasks
             (id, account_id, task_type, status, cursor, current_page, discovered_count,
              saved_count, skipped_count, failed_count, downloaded_count, started_at, finished_at,
              last_error, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              status=excluded.status, cursor=excluded.cursor, current_page=excluded.current_page,
              discovered_count=excluded.discovered_count, saved_count=excluded.saved_count,
              skipped_count=excluded.skipped_count, failed_count=excluded.failed_count,
              downloaded_count=excluded.downloaded_count, started_at=excluded.started_at,
              finished_at=excluded.finished_at, last_error=excluded.last_error,
              updated_at=excluded.updated_at
            """,
            arguments: [
                task.id, account.qqUin, task.taskType, task.status.rawValue, task.cursor,
                task.currentPage, task.discoveredCount, task.savedCount, task.skippedCount,
                task.failedCount, task.downloadedCount, task.startedAt, task.finishedAt,
                task.lastError, task.createdAt, Date(),
            ]
        )
    }

    func loadTask(account: Account, taskType: String) throws -> ArchiveTask? {
        let rows = try self.database.executeQuery(
            "SELECT * FROM archive_tasks WHERE account_id=? AND task_type=? ORDER BY updated_at DESC LIMIT 1",
            arguments: [account.qqUin, taskType]
        )
        guard let row = rows.first else { return nil }
        return ArchiveTask(
            id: UUID(uuidString: row["id"] as? String ?? "") ?? UUID(),
            accountID: account.id,
            taskType: row["task_type"] as? String ?? taskType,
            status: ArchiveTask.Status(rawValue: row["status"] as? String ?? "pending") ?? .pending,
            cursor: row["cursor"] as? String,
            currentPage: Self.int(row["current_page"]),
            discoveredCount: Self.int(row["discovered_count"]),
            savedCount: Self.int(row["saved_count"]),
            skippedCount: Self.int(row["skipped_count"]),
            failedCount: Self.int(row["failed_count"]),
            downloadedCount: Self.int(row["downloaded_count"]),
            startedAt: Self.doubleOrNil(row["started_at"]).map { Date(timeIntervalSince1970: $0) },
            finishedAt: Self.doubleOrNil(row["finished_at"]).map { Date(timeIntervalSince1970: $0) },
            lastError: row["last_error"] as? String
        )
    }

    func clearTasks(account: Account) throws {
        _ = try self.database.executeUpdate(
            "DELETE FROM archive_tasks WHERE account_id=?",
            arguments: [account.qqUin]
        )
    }

    func saveFailure(taskID: UUID, account: Account, type: TaskFailure.ResourceType,
                     resourceID: String, code: String?, message: String) throws {
        _ = try self.database.executeUpdate(
            """
            INSERT INTO task_failures
             (id, task_id, account_id, resource_type, resource_id, error_code, error_message, retry_count, resolved, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,0,0,?,?)
            """,
            arguments: [
                UUID().uuidString, taskID, account.qqUin, type.rawValue, resourceID,
                code, message, Date(), Date(),
            ]
        )
    }

    func listFailures(account: Account, resolved: Bool) throws -> [TaskFailure] {
        let rows = try self.database.executeQuery(
            "SELECT * FROM task_failures WHERE account_id=? AND resolved=? ORDER BY created_at DESC",
            arguments: [account.qqUin, resolved ? 1 : 0]
        )
        return rows.map { row in
            TaskFailure(
                id: UUID(uuidString: row["id"] as? String ?? "") ?? UUID(),
                taskID: UUID(uuidString: row["task_id"] as? String ?? "") ?? UUID(),
                resourceType: TaskFailure.ResourceType(rawValue: row["resource_type"] as? String ?? "post") ?? .post,
                resourceID: row["resource_id"] as? String ?? "",
                errorCode: row["error_code"] as? String,
                errorMessage: row["error_message"] as? String ?? "",
                retryCount: Self.int(row["retry_count"]),
                resolved: Self.int(row["resolved"]) == 1,
                createdAt: Date(timeIntervalSince1970: Self.double(row["created_at"])),
                updatedAt: Date(timeIntervalSince1970: Self.double(row["updated_at"]))
            )
        }
    }

    func resolveFailure(id: UUID) throws {
        _ = try self.database.executeUpdate(
            "UPDATE task_failures SET resolved=1, updated_at=? WHERE id=?",
            arguments: [Date(), id]
        )
    }

    // MARK: - 辅助

    private func post(from row: [String: Any], account: Account) throws -> ArchivePost {
        let id = Self.int(row["id"])
        let publishedAt = Self.doubleOrNil(row["published_at"]).map { Date(timeIntervalSince1970: $0) }
        let pictures = Self.jsonStrings(row["picture_urls_json"])
        let videos = Self.jsonStrings(row["video_urls_json"])
        let comments = try loadComments(account: account, sourceID: row["source_id"] as? String ?? "")
        let likes = try loadLikes(account: account, sourceID: row["source_id"] as? String ?? "")
        return ArchivePost(
            id: id,
            accountID: account.id,
            sourceID: row["source_id"] as? String ?? "",
            authorUin: row["author_uin"] as? String,
            authorName: row["author_name"] as? String,
            contentText: row["content_text"] as? String ?? "",
            publishedAt: publishedAt,
            archivedAt: Date(timeIntervalSince1970: Self.double(row["archived_at"])),
            postType: row["post_type"] as? String ?? "",
            sourceURL: row["source_url"] as? String,
            rawPayloadPath: row["raw_payload_path"] as? String,
            isDeleted: Self.int(row["is_deleted"]) == 1,
            pictureURLs: pictures,
            videoURLs: videos,
            videoCoverURL: row["video_cover_url"] as? String,
            likeCount: Self.int(row["like_count"]),
            commentCount: Self.int(row["comment_count"]),
            category: ArchiveCategory(rawValue: row["category"] as? String ?? "self") ?? .self_,
            likes: likes,
            comments: comments
        )
    }

    private func loadComments(account: Account, sourceID: String) throws -> [ArchivedComment] {
        guard !sourceID.isEmpty else { return [] }
        let rows = try self.database.executeQuery(
            "SELECT * FROM comments WHERE account_id=? AND post_id=? ORDER BY published_at ASC, created_at ASC",
            arguments: [account.qqUin, sourceID]
        )
        let replies = try self.database.executeQuery(
            "SELECT * FROM comments WHERE account_id=? AND post_id=? AND parent_id IS NOT NULL ORDER BY published_at ASC",
            arguments: [account.qqUin, sourceID]
        )
        let replyByParent = Dictionary(grouping: replies) { $0["parent_id"] as? String ?? "" }
        var result: [ArchivedComment] = []
        // SQLite 的 NULL 在行字典里是 NSNull, 不是 nil
        for row in rows where (row["parent_id"] as? NSNull) != nil || row["parent_id"] == nil {
            let comment = ArchivedComment(
                id: row["id"] as? String ?? "",
                postID: sourceID,
                parentID: nil,
                authorUin: row["author_uin"] as? String,
                authorName: row["author_name"] as? String,
                contentText: row["content_text"] as? String ?? "",
                publishedAt: Self.doubleOrNil(row["published_at"]).map { Date(timeIntervalSince1970: $0) },
                createdAt: Date(timeIntervalSince1970: Self.double(row["created_at"])),
                replies: (replyByParent[row["id"] as? String ?? ""] ?? []).map { reply in
                    ArchivedReply(
                        uin: reply["author_uin"] as? String,
                        nickname: reply["author_name"] as? String,
                        replyToUin: nil,
                        replyToNickname: nil,
                        content: reply["content_text"] as? String ?? "",
                        createdAt: Int(Self.double(reply["published_at"]))
                    )
                }
            )
            result.append(comment)
        }
        return result
    }

    private func loadLikes(account: Account, sourceID: String) throws -> [LikeUser] {
        guard !sourceID.isEmpty else { return [] }
        let rows = try self.database.executeQuery(
            "SELECT author_uin, author_name FROM likes WHERE account_id=? AND post_id=?",
            arguments: [account.qqUin, sourceID]
        )
        return rows.map {
            LikeUser(uin: $0["author_uin"] as? String, nickname: $0["author_name"] as? String)
        }
    }

    private func databaseFileSize() -> Int64 {
        let url = storage.databaseURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64
        else { return 0 }
        return size
    }

    private static func jsonText(_ array: [String]) throws -> String {
        guard !array.isEmpty else { return "" }
        let data = try JSONEncoder().encode(array)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func jsonStrings(_ value: Any?) -> [String] {
        guard let string = value as? String, !string.isEmpty,
              let data = string.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return decoded
    }

    private static func int(_ value: Any?) -> Int {
        if let number = value as? Int64 { return Int(number) }
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let string = value as? String, let number = Int(string) { return number }
        return 0
    }

    private static func intOrNil(_ value: Any?) -> Int? {
        if let number = value as? Int64 { return Int(number) }
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func double(_ value: Any?) -> Double {
        if let number = value as? Double { return number }
        if let number = value as? Int64 { return Double(number) }
        if let number = value as? Int { return Double(number) }
        return 0
    }

    private static func doubleOrNil(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int64 { return Double(number) }
        if let number = value as? Int { return Double(number) }
        return nil
    }
}
