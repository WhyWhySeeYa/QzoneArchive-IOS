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

    func upsertTask(_ task: ArchiveTask) throws
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
        let rows = try database.executeQuery(
            "SELECT * FROM accounts WHERE is_active=1 ORDER BY last_login_at DESC LIMIT 1",
            arguments: []
        )
        return rows.first.map { Self.account(from: $0) }
    }

    func saveAccount(_ account: Account) throws {
        _ = try database.executeUpdate(
            "UPDATE accounts SET is_active=0 WHERE qq_uin<>?",
            arguments: [account.qqUin]
        )
        _ = try database.executeUpdate(
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
        let rows = try database.executeQuery(
            "SELECT * FROM accounts ORDER BY last_login_at DESC",
            arguments: []
        )
        return rows.map { Self.account(from: $0) }
    }

    func deleteAccount(uin: String) throws {
        _ = try database.executeUpdate("DELETE FROM accounts WHERE qq_uin=?", arguments: [uin])
        _ = try database.executeUpdate("DELETE FROM archive_posts WHERE account_id=?", arguments: [uin])
        _ = try database.executeUpdate("DELETE FROM media_assets WHERE account_id=?", arguments: [uin])
        _ = try database.executeUpdate("DELETE FROM comments WHERE account_id=?", arguments: [uin])
        _ = try database.executeUpdate("DELETE FROM likes WHERE account_id=?", arguments: [uin])
        _ = try database.executeUpdate("DELETE FROM archive_tasks WHERE account_id=?", arguments: [uin])
        _ = try database.executeUpdate("DELETE FROM archive_skips WHERE account_id=?", arguments: [uin])
        _ = try database.executeUpdate("DELETE FROM archive_checkpoints WHERE account_id=?", arguments: [uin])
        _ = try database.executeUpdate("DELETE FROM archive_rate_limits WHERE account_id=?", arguments: [uin])
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
        return try database.inTransaction {
            var saved = 0
            for post in posts {
                let changes = try database.executeUpdate(
                    """
                    INSERT INTO archive_posts
                     (account_id, source_id, author_uin, author_name, content_text, published_at,
                      archived_at, post_type, source_url, raw_payload_path, is_deleted,
                      picture_urls_json, video_urls_json, video_cover_url, like_count, comment_count,
                      category, created_at, updated_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(account_id, source_id) DO UPDATE SET
                      author_uin=excluded.author_uin, author_name=excluded.author_name,
                      content_text=excluded.content_text, published_at=excluded.published_at,
                      archived_at=excluded.archived_at, post_type=excluded.post_type,
                      source_url=excluded.source_url, raw_payload_path=excluded.raw_payload_path,
                      picture_urls_json=excluded.picture_urls_json,
                      video_urls_json=excluded.video_urls_json,
                      video_cover_url=excluded.video_cover_url,
                      like_count=excluded.like_count, comment_count=excluded.comment_count,
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
                saved += changes
                if post.likeCount > 0 || !post.likes.isEmpty {
                    try saveLikes(account: account, post: post)
                }
                if post.commentCount > 0 || !post.comments.isEmpty {
                    try saveComments(account: account, post: post)
                }
            }
            return saved
        }
    }

    private func saveLikes(account: Account, post: ArchivePost) throws {
        for like in post.likes {
            _ = try database.executeUpdate(
                """
                INSERT OR IGNORE INTO likes (id, account_id, post_id, author_uin, author_name, created_at)
                VALUES (?,?,?,?,?,?)
                """,
                arguments: [
                    UUID().uuidString, account.qqUin, post.sourceID,
                    like.uin, like.nickname, Date(),
                ]
            )
        }
    }

    private func saveComments(account: Account, post: ArchivePost) throws {
        for comment in post.comments {
            _ = try database.executeUpdate(
                """
                INSERT OR REPLACE INTO comments
                 (id, account_id, post_id, parent_id, author_uin, author_name, content_text, published_at, created_at)
                VALUES (?,?,?,?,?,?,?,?,?)
                """,
                arguments: [
                    comment.id, account.qqUin, post.sourceID, comment.parentID,
                    comment.authorUin, comment.authorName, comment.contentText,
                    comment.publishedAt, comment.createdAt,
                ]
            )
            for reply in comment.replies {
                _ = try database.executeUpdate(
                    """
                    INSERT OR REPLACE INTO comments
                     (id, account_id, post_id, parent_id, author_uin, author_name, content_text, published_at, created_at)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    """,
                    arguments: [
                        "\(comment.id)-reply-\(reply.createdAt)-\(reply.uin ?? "")",
                        account.qqUin, post.sourceID, comment.id,
                        reply.uin, reply.nickname, reply.content,
                        Date(timeIntervalSince1970: TimeInterval(reply.createdAt)), Date(),
                    ]
                )
            }
        }
    }

    func listPosts(account: Account, category: ArchiveCategory, limit: Int, offset: Int) throws -> [ArchivePost] {
        let rows = try database.executeQuery(
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
        let rows = try database.executeQuery(
            "SELECT COUNT(*) AS total FROM archive_posts WHERE account_id=? AND category=?",
            arguments: [account.qqUin, category.raw]
        )
        return Self.int(rows.first?["total"])
    }

    func fetchPost(account: Account, id: Int) throws -> ArchivePost {
        let rows = try database.executeQuery(
            "SELECT * FROM archive_posts WHERE account_id=? AND id=?",
            arguments: [account.qqUin, id]
        )
        guard let row = rows.first else { throw QzoneError.unknown("原始动态不存在或已删除") }
        return try post(from: row, account: account)
    }

    func deletePosts(account: Account, ids: [Int]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try database.inTransaction {
            var count = 0
            for id in ids {
                _ = try database.executeUpdate(
                    "DELETE FROM comments WHERE account_id=? AND post_id=(SELECT source_id FROM archive_posts WHERE account_id=? AND id=?)",
                    arguments: [account.qqUin, account.qqUin, id]
                )
                _ = try database.executeUpdate(
                    "DELETE FROM likes WHERE account_id=? AND post_id=(SELECT source_id FROM archive_posts WHERE account_id=? AND id=?)",
                    arguments: [account.qqUin, account.qqUin, id]
                )
                _ = try database.executeUpdate(
                    "DELETE FROM media_assets WHERE account_id=? AND post_id=(SELECT source_id FROM archive_posts WHERE account_id=? AND id=?)",
                    arguments: [account.qqUin, account.qqUin, id]
                )
                count += try database.executeUpdate(
                    "DELETE FROM archive_posts WHERE account_id=? AND id=?",
                    arguments: [account.qqUin, id]
                )
            }
            return count
        }
    }

    func clearPosts(account: Account) throws -> Int {
        try database.inTransaction {
            let count = try database.executeUpdate(
                "DELETE FROM archive_posts WHERE account_id=?",
                arguments: [account.qqUin]
            )
            _ = try database.executeUpdate("DELETE FROM comments WHERE account_id=?", arguments: [account.qqUin])
            _ = try database.executeUpdate("DELETE FROM likes WHERE account_id=?", arguments: [account.qqUin])
            _ = try database.executeUpdate("DELETE FROM media_assets WHERE account_id=?", arguments: [account.qqUin])
            _ = try database.executeUpdate("DELETE FROM archive_checkpoints WHERE account_id=?", arguments: [account.qqUin])
            _ = try database.executeUpdate("DELETE FROM archive_rate_limits WHERE account_id=?", arguments: [account.qqUin])
            return count
        }
    }

    func searchPosts(account: Account, keyword: String, limit: Int, offset: Int) throws -> [ArchivePost] {
        let pattern = "%\(keyword)%"
        let rows = try database.executeQuery(
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
        let rows = try database.executeQuery(
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
        let interaction = try database.executeQuery(
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
        let pictureRows = try database.executeQuery(
            "SELECT picture_urls_json FROM archive_posts WHERE account_id=? AND picture_urls_json IS NOT NULL",
            arguments: [account.qqUin]
        )
        var pictures = 0
        var videos = 0
        for row in pictureRows {
            let json = row["picture_urls_json"] as? String ?? ""
            if let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                pictures += decoded.count
            }
            let videoJSON = row["video_urls_json"] as? String ?? ""
            if let data = videoJSON.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data),
               !decoded.isEmpty {
                videos += 1
            }
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
        let rows = try database.executeQuery(
            """
            SELECT author_uin AS uin,
                   COALESCE(NULLIF(MAX(author_name),''), author_uin) AS nickname,
                   COUNT(*) AS interactions
            FROM (
              SELECT author_uin, author_name FROM comments WHERE account_id=? AND author_uin IS NOT NULL AND author_uin<>'' AND author_uin<>?
              UNION ALL
              SELECT author_uin, author_name FROM likes WHERE account_id=? AND author_uin IS NOT NULL AND author_uin<>'' AND author_uin<>?
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
                likes: 0,
                comments: 0
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
        let yearRows = try database.executeQuery(
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
        let rows = try database.executeQuery(
            """
            SELECT id, published_at, content, author_uin, author_name,
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
            let content = row["content"] as? String
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
            if let video = videos.first {
                items.append(MediaTimelineItem(
                    key: "\(id)-video",
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
        let countRows = try database.executeQuery(
            """
            SELECT COUNT(*) AS total FROM archive_posts
            WHERE account_id=? AND category IN ('self','other')
              AND (picture_urls_json IS NOT NULL OR video_urls_json IS NOT NULL)
              \(yearFilter)
            """,
            arguments: Array(arguments.dropLast(2))
        )
        return MediaTimelinePage(items: items, total: Self.int(countRows.first?["total"]), years: years)
    }

    // MARK: - 游标与频率

    func saveCheckpoint(account: Account, attachInfo: String, pages: Int, fetched: Int, saved: Int) throws {
        _ = try database.executeUpdate(
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
        let rows = try database.executeQuery(
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
        _ = try database.executeUpdate(
            "DELETE FROM archive_checkpoints WHERE account_id=?",
            arguments: [account.qqUin]
        )
    }

    func checkpointIsStale(account: Account) throws -> Bool {
        guard let checkpoint = try loadCheckpoint(account: account) else { return false }
        return Date().timeIntervalSince(checkpoint.updatedAt) > 10 * 60
    }

    func saveRateWindow(account: Account, startedAt: Date, pages: Int, retryAt: Date?) throws {
        _ = try database.executeUpdate(
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
        let rows = try database.executeQuery(
            "SELECT * FROM archive_rate_limits WHERE account_id=?",
            arguments: [account.qqUin]
        )
        guard let row = rows.first, let started = Self.doubleOrNil(row["window_started_at"]) else { return nil }
        let retry = Self.doubleOrNil(row["retry_at"]).map { Date(timeIntervalSince1970: $0) }
        return (Date(timeIntervalSince1970: started), Self.int(row["pages"]), retry)
    }

    func clearRateWindow(account: Account) throws {
        _ = try database.executeUpdate(
            "DELETE FROM archive_rate_limits WHERE account_id=?",
            arguments: [account.qqUin]
        )
    }

    // MARK: - 异常跳过

    func recordSkip(account: Account, pageNumber: Int, cursorOffset: Int, offsetAdvance: Int,
                    baseTime: Int, error: String, cursor: String) throws {
        _ = try database.executeUpdate(
            """
            INSERT INTO archive_skips
             (account_id, page_number, cursor_offset, offset_advance, base_time, error, skipped_at, cursor)
            VALUES (?,?,?,?,?,?,?,?)
            """,
            arguments: [account.qqUin, pageNumber, cursorOffset, offsetAdvance, baseTime, error, Date(), cursor]
        )
    }

    func listSkips(account: Account) throws -> [ArchiveSkipRow] {
        let rows = try database.executeQuery(
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
        let rows = try database.executeQuery(
            "SELECT id FROM archive_skips WHERE account_id=? AND resolved_at IS NULL ORDER BY skipped_at ASC",
            arguments: [account.qqUin]
        )
        return rows.map { Self.int($0["id"]) }
    }

    func resolveSkip(account: Account, id: Int, recoveredRecords: Int) throws {
        _ = try database.executeUpdate(
            """
            UPDATE archive_skips SET retry_count=retry_count+1, last_retry_at=?,
              resolved_at=?, recovered_records=? WHERE id=? AND account_id=?
            """,
            arguments: [Date(), Date(), recoveredRecords, id, account.qqUin]
        )
    }

    func failSkip(account: Account, id: Int, error: String) throws {
        _ = try database.executeUpdate(
            "UPDATE archive_skips SET retry_count=retry_count+1, last_retry_at=?, error=? WHERE id=? AND account_id=?",
            arguments: [Date(), error, id, account.qqUin]
        )
    }

    func clearResolvedSkips(account: Account) throws {
        _ = try database.executeUpdate(
            "DELETE FROM archive_skips WHERE account_id=? AND resolved_at IS NOT NULL",
            arguments: [account.qqUin]
        )
    }

    // MARK: - 任务

    func upsertTask(_ task: ArchiveTask) throws {
        _ = try database.executeUpdate(
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
                task.id, task.accountID, task.taskType, task.status.rawValue, task.cursor,
                task.currentPage, task.discoveredCount, task.savedCount, task.skippedCount,
                task.failedCount, task.downloadedCount, task.startedAt, task.finishedAt,
                task.lastError, task.createdAt, Date(),
            ]
        )
    }

    func loadTask(account: Account, taskType: String) throws -> ArchiveTask? {
        let rows = try database.executeQuery(
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
        _ = try database.executeUpdate(
            "DELETE FROM archive_tasks WHERE account_id=?",
            arguments: [account.qqUin]
        )
    }

    func saveFailure(taskID: UUID, account: Account, type: TaskFailure.ResourceType,
                     resourceID: String, code: String?, message: String) throws {
        _ = try database.executeUpdate(
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
        let rows = try database.executeQuery(
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
        _ = try database.executeUpdate(
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
        let rows = try database.executeQuery(
            "SELECT * FROM comments WHERE account_id=? AND post_id=? ORDER BY published_at ASC, created_at ASC",
            arguments: [account.qqUin, sourceID]
        )
        let replies = try database.executeQuery(
            "SELECT * FROM comments WHERE account_id=? AND post_id=? AND parent_id IS NOT NULL ORDER BY published_at ASC",
            arguments: [account.qqUin, sourceID]
        )
        let replyByParent = Dictionary(grouping: replies) { $0["parent_id"] as? String ?? "" }
        var result: [ArchivedComment] = []
        for row in rows where row["parent_id"] == nil {
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
        let rows = try database.executeQuery(
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
