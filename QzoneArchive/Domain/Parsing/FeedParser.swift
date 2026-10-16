//
//  FeedParser.swift
//  QzoneArchive
//
//  互动数据解析: 动态, 评论, 点赞, 媒体地址
//
//  与桌面端 core/archiveParser.ts 的字段路径与兜底顺序一致
//

import Foundation

/// 解析后的互动记录
struct ParsedFeed {
    var feedKey: String
    var cellID: String
    var eventType: Int
    var eventTime: Int
    var title: String?
    var content: String?
    var eventSummary: String?
    var actorUin: String?
    var actorName: String?
    var originalAuthorUin: String?
    var originalAuthorName: String?
    var pictureCount: Int
    var picturesJSON: String?
    var videoJSON: String?
    var commentsJSON: String?
    var rawJSON: String
}

/// 互动数据解析
enum FeedParser {
    /// 互动类型: 评论
    static let eventTypeComment = 2
    /// 互动类型: 点赞
    static let eventTypeLike = 217
    /// 互动类型: 评论(另一来源)
    static let eventTypeCommentAlt = 311

    // MARK: - 页面组装

    ///
    /// 把一页原始互动数据整理成动态模型
    ///
    /// 与桌面端 parseFeedPage 之后写入 archive_feeds 的行为对应:
    /// 动态正文来自原始动态记录, 评论与点赞按 cell_id 聚合到同一动态上
    ///
    static func parsePosts(_ feeds: [[String: Any]], account: Account) -> [ArchivePost] {
        // 按 cell_id 聚合, 动态正文放在动态条目上
        var dynamics: [String: ArchivePost] = [:]
        var order: [String] = []
        // cell_id -> 评论与点赞
        var commentsByCell: [String: [ParsedComment]] = [:]
        var likesByCell: [String: [LikeUser]] = [:]

        for feed in feeds {
            let parsed = parseFeed(feed)
            let cellID = parsed.cellID
            if parsed.eventType == eventTypeLike {
                let user = LikeUser(uin: parsed.actorUin, nickname: parsed.actorName)
                likesByCell[cellID, default: []].append(user)
                continue
            }
            if parsed.eventType == eventTypeComment || parsed.eventType == eventTypeCommentAlt {
                let comments = commentFromValues(
                    commentsJSON: parsed.commentsJSON,
                    actorUin: parsed.actorUin,
                    actorName: parsed.actorName,
                    eventSummary: parsed.eventSummary,
                    eventTime: parsed.eventTime
                )
                for comment in comments {
                    commentsByCell[cellID, default: []].append(comment)
                }
                continue
            }
            // 其余事件类型按动态正文处理
            let dynamic = parseOriginalDynamic(feed, ownerUin: account.qqUin)
            let post = ArchivePost(
                id: 0,
                accountID: account.id,
                sourceID: dynamic.cellID.isEmpty ? parsed.feedKey : dynamic.cellID,
                authorUin: dynamic.authorUin,
                authorName: dynamic.authorName,
                contentText: dynamic.content,
                publishedAt: dynamic.publishedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(dynamic.publishedAt)) : nil,
                archivedAt: Date(),
                postType: "text",
                sourceURL: nil,
                rawPayloadPath: nil,
                isDeleted: false,
                pictureURLs: pictureURLs(dynamic.picturesJSON),
                videoURLs: videoURLs(dynamic.videoJSON),
                videoCoverURL: videoCoverURL(dynamic.videoJSON),
                likeCount: 0,
                commentCount: 0,
                category: dynamic.category,
                likes: [],
                comments: []
            )
            if dynamics[cellID] == nil { order.append(cellID) }
            dynamics[cellID] = post
        }

        // 聚合评论与点赞
        return order.compactMap { cellID in
            guard var post = dynamics[cellID] else { return nil }
            post.comments = mergeComments(commentsByCell[cellID] ?? []).map { $0.toArchived(postID: post.sourceID) }
            post.likes = likesByCell[cellID] ?? []
            post.commentCount = post.comments.count
            post.likeCount = post.likes.count
            return post
        }
    }

    // MARK: - 单条互动记录

    /// 解析一条互动记录
    static func parseFeed(_ feed: [String: Any]) -> ParsedFeed {
        let cellID = string(feed["cell_id"])
            ?? string(feed["cellId"])
            ?? string(feed["cellid"])
            ?? string(jsonPointer(feed, "/cell_id"))
            ?? string(jsonPointer(feed, "/cell_common/cell_id"))
            ?? ""
        let key = keyFrom(feed: feed, cellID: cellID)
        let eventType = integer(feed["event_type"])
            ?? integer(feed["eventType"])
            ?? integer(jsonPointer(feed, "/cell_common/event_type"))
            ?? 0
        let eventTime = integer(feed["event_time"])
            ?? integer(feed["eventTime"])
            ?? integer(jsonPointer(feed, "/cell_common/event_time"))
            ?? integer(jsonPointer(feed, "/cell_common/time"))
            ?? 0
        let title = string(feed["title"])
            ?? string(jsonPointer(feed, "/cell_common/title"))
        let content = string(feed["content"])
            ?? string(jsonPointer(feed, "/cell_common/content"))
            ?? string(jsonPointer(feed, "/cell_common/richtext"))
            ?? string(jsonPointer(feed, "/cell_common/summary"))
        let eventSummary = string(feed["event_summary"])
            ?? string(jsonPointer(feed, "/cell_common/event_summary"))
            ?? string(jsonPointer(feed, "/cell_common/summary"))
        let actorUin = string(feed["actor_uin"])
            ?? string(feed["actorUin"])
            ?? string(jsonPointer(feed, "/cell_userinfo/user/uin"))
            ?? string(jsonPointer(feed, "/cell_userinfo/uin"))
        let actorName = string(feed["actor_name"])
            ?? string(feed["actorName"])
            ?? string(jsonPointer(feed, "/cell_userinfo/user/nickname"))
            ?? string(jsonPointer(feed, "/cell_userinfo/nickname"))
        let originalAuthorUin = string(feed["original_author_uin"])
            ?? string(feed["originalAuthorUin"])
            ?? string(jsonPointer(feed, "/cell_original_author/uin"))
        let originalAuthorName = string(feed["original_author_name"])
            ?? string(feed["originalAuthorName"])
            ?? string(jsonPointer(feed, "/cell_original_author/nickname"))
        let picturesJSON = stableJSON(jsonPointer(feed, "/cell_pic"))
        let videoJSON = stableJSON(jsonPointer(feed, "/cell_video"))
        let commentsJSON = stableJSON(jsonPointer(feed, "/cell_comments"))
        let rawJSON = stableJSON(feed) ?? "{}"
        return ParsedFeed(
            feedKey: key,
            cellID: cellID,
            eventType: eventType,
            eventTime: eventTime,
            title: title,
            content: content,
            eventSummary: eventSummary,
            actorUin: actorUin,
            actorName: actorName,
            originalAuthorUin: originalAuthorUin,
            originalAuthorName: originalAuthorName,
            pictureCount: pictureCount(picturesJSON),
            picturesJSON: picturesJSON,
            videoJSON: videoJSON,
            commentsJSON: commentsJSON,
            rawJSON: rawJSON
        )
    }

    /// 生成互动记录唯一键
    static func keyFrom(feed: [String: Any], cellID: String) -> String {
        let keys = ["key", "id", "feed_key", "feedKey", "cell_key"]
        for key in keys {
            if let value = string(feed[key]), !value.isEmpty { return value }
        }
        let eventType = integer(feed["event_type"]) ?? integer(jsonPointer(feed, "/cell_common/event_type")) ?? 0
        let eventTime = integer(feed["event_time"]) ?? integer(jsonPointer(feed, "/cell_common/event_time")) ?? 0
        let actor = string(feed["actor_uin"])
            ?? string(jsonPointer(feed, "/cell_userinfo/user/uin"))
            ?? string(jsonPointer(feed, "/cell_userinfo/uin"))
            ?? ""
        return "\(cellID)-\(eventType)-\(eventTime)-\(actor)"
    }

    // MARK: - 动态

    /// 解析原始动态
    static func parseOriginalDynamic(_ feed: [String: Any], ownerUin: String) -> ParsedDynamic {
        let authorUin = string(jsonPointer(feed, "/cell_userinfo/user/uin"))
            ?? string(jsonPointer(feed, "/cell_userinfo/uin"))
        let authorName = string(jsonPointer(feed, "/cell_userinfo/user/nickname"))
            ?? string(jsonPointer(feed, "/cell_userinfo/nickname"))
        let cellID = string(feed["cell_id"])
            ?? string(feed["cellId"])
            ?? string(jsonPointer(feed, "/cell_common/cell_id"))
            ?? ""
        let publishedAt = integer(feed["published_at"])
            ?? integer(jsonPointer(feed, "/cell_common/time"))
            ?? integer(jsonPointer(feed, "/cell_common/published_at"))
            ?? 0
        let content = string(feed["content"])
            ?? string(jsonPointer(feed, "/cell_common/content"))
            ?? string(jsonPointer(feed, "/cell_common/richtext"))
            ?? string(jsonPointer(feed, "/cell_common/summary"))
            ?? ""
        let isGuestbook = string(feed["cell_id"])?.contains("guestbook") == true
            || string(feed["type"])?.contains("guestbook") == true
        let category: ArchiveCategory = isGuestbook ? .guestbook : (authorUin == ownerUin ? .self_ : .other)
        let picturesJSON = stableJSON(jsonPointer(feed, "/cell_pic"))
        let videoJSON = stableJSON(jsonPointer(feed, "/cell_video"))
        return ParsedDynamic(
            cellID: cellID,
            publishedAt: publishedAt,
            content: content,
            authorUin: authorUin,
            authorName: authorName,
            category: category,
            picturesJSON: picturesJSON,
            videoJSON: videoJSON,
            pictureCount: pictureCount(picturesJSON)
        )
    }

    // MARK: - 评论

    /// 取评论内容
    static func commentContent(_ comment: [String: Any]) -> String {
        let keys = ["comment", "content", "richtext", "text"]
        for key in keys {
            if let value = string(comment[key]), !value.isEmpty { return value }
        }
        return ""
    }

    /// 取评论作者昵称
    static func commentNickname(_ comment: [String: Any]) -> String? {
        let keys = ["nickname", "name", "nick"]
        for key in keys {
            if let value = string(comment[key]), !value.isEmpty { return value }
        }
        if let user = comment["user"] as? [String: Any] {
            return string(user["nickname"]) ?? string(user["name"])
        }
        return nil
    }

    /// 取评论作者 QQ
    static func commentUin(_ comment: [String: Any]) -> String? {
        let keys = ["uin", "qq", "user_uin", "userId"]
        for key in keys {
            if let value = string(comment[key]), !value.isEmpty { return value }
        }
        if let user = comment["user"] as? [String: Any] {
            return string(user["uin"]) ?? string(user["id"])
        }
        return nil
    }

    /// 取评论发布时间
    static func commentTime(_ comment: [String: Any]) -> Int {
        integer(comment["time"])
            ?? integer(comment["created_at"])
            ?? integer(comment["createdAt"])
            ?? integer(comment["pubtime"])
            ?? integer(comment["timestamp"])
            ?? 0
    }

    /// 合并同一来源的评论, 去掉重复项
    static func mergeComments(_ comments: [ParsedComment]) -> [ParsedComment] {
        var seen = Set<String>()
        var result: [ParsedComment] = []
        for comment in comments {
            let key = "\(comment.uin ?? "")-\(comment.createdAt)-\(comment.content)"
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(comment)
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    /// 由互动记录字段构建评论
    static func commentFromValues(
        commentsJSON: String?,
        actorUin: String?,
        actorName: String?,
        eventSummary: String?,
        eventTime: Int
    ) -> [ParsedComment] {
        var result: [ParsedComment] = []
        if let commentsJSON,
           let data = commentsJSON.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for comment in array {
                result.append(
                    ParsedComment(
                        id: UUID().uuidString,
                        uin: commentUin(comment) ?? actorUin,
                        nickname: commentNickname(comment) ?? actorName,
                        content: commentContent(comment),
                        createdAt: commentTime(comment) != 0 ? commentTime(comment) : eventTime,
                        replies: []
                    )
                )
            }
            if !result.isEmpty { return result }
        }
        if let eventSummary, !eventSummary.isEmpty {
            result.append(
                ParsedComment(
                    id: UUID().uuidString,
                    uin: actorUin,
                    nickname: actorName,
                    content: eventSummary,
                    createdAt: eventTime,
                    replies: []
                )
            )
        }
        return result
    }

    // MARK: - 媒体地址

    /// 从图片字段提取候选地址
    static func pictureURLs(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        var candidates: [String] = []
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for item in array {
                if let urls = item["urls"] as? [[String: Any]] {
                    for entry in urls {
                        if let url = string(entry["url"]) { candidates.append(url) }
                    }
                } else if let url = item["url"] as? String {
                    candidates.append(url)
                }
                if let url = string(item["raw"]) { candidates.append(url) }
                if let url = string(item["origin"]) { candidates.append(url) }
            }
        } else if let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
            candidates.append(contentsOf: array)
        }
        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates where !candidate.isEmpty && !seen.contains(candidate) {
            seen.insert(candidate)
            result.append(candidate)
        }
        return result
    }

    /// 从视频字段提取候选地址
    static func videoURLs(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        var candidates: [String] = []
        let keys = ["url", "video_url", "videoUrl", "raw_url", "rawUrl", "download_url", "downloadUrl", "play_url", "playUrl", "hd_url", "hdUrl", "sd_url", "sdUrl"]
        for key in keys {
            if let url = string(object[key]) { candidates.append(url) }
        }
        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 视频封面地址
    static func videoCoverURL(_ json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let keys = ["cover_url", "coverUrl", "cover", "pic_url", "picUrl", "thumbnail", "preview_url", "previewUrl"]
        for key in keys {
            if let url = string(object[key]) { return url }
        }
        return nil
    }

    // MARK: - 工具

    /// 取字符串字段
    static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// 取整数字段
    static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// 按 JSON Pointer 路径取值, 支持数字索引
    static func jsonPointer(_ object: Any, _ path: String) -> Any? {
        let parts = path.split(separator: "/").dropFirst()
        var current: Any? = object
        for part in parts {
            if let array = current as? [Any], let index = Int(part) {
                current = array.indices.contains(index) ? array[index] : nil
            } else if let dictionary = current as? [String: Any] {
                current = dictionary[String(part)]
            } else {
                return nil
            }
            if current == nil { return nil }
        }
        return current
    }

    /// 图片数量
    static func pictureCount(_ json: String?) -> Int {
        guard let json, let data = json.data(using: .utf8) else { return 0 }
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return array.count }
        if let array = try? JSONSerialization.jsonObject(with: data) as? [String] { return array.count }
        return 0
    }

    /// 稳定序列化: 键排序, 保证同一条数据的 JSON 一致
    static func stableJSON(_ value: Any?) -> String? {
        guard let value else { return nil }
        guard JSONSerialization.isValidJSONObject(value) else {
            return (value as? String).map { "\"\($0)\"" }
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 解析后的原始动态
struct ParsedDynamic {
    var cellID: String
    var publishedAt: Int
    var content: String
    var authorUin: String?
    var authorName: String?
    var category: ArchiveCategory
    var picturesJSON: String?
    var videoJSON: String?
    var pictureCount: Int
}

/// 解析后的评论
struct ParsedComment {
    var id: String
    var uin: String?
    var nickname: String?
    var content: String
    var createdAt: Int
    var replies: [ArchivedReply]
}

extension ParsedComment {
    /// 转为归档评论模型
    func toArchived(postID: String) -> ArchivedComment {
        ArchivedComment(
            id: id,
            postID: postID,
            authorUin: uin,
            authorName: nickname,
            contentText: content,
            publishedAt: createdAt > 0 ? Date(timeIntervalSince1970: TimeInterval(createdAt)) : nil,
            replies: replies
        )
    }
}
