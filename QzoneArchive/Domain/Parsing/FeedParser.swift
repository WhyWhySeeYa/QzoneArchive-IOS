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
            // 其余事件类型按动态正文处理; 缺少 original.cell_id.cellid 的记录原实现直接跳过
            guard let dynamic = parseOriginalDynamic(feed, ownerUin: account.qqUin) else { continue }
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

    /// 解析一条互动记录, 字段与路径与桌面端 parseFeed 逐条对应
    static func parseFeed(_ feed: [String: Any]) -> ParsedFeed {
        let cellID = textAt(feed, "/original/cell_id/cellid")
        let eventTime = asInteger(jsonPointer(feed, "/comm/time")) ?? 0
        let eventType = asInteger(jsonPointer(feed, "/comm/subid")) ?? 0
        let actorUin = textAt(feed, "/userinfo/user/uin")
        let actorLabel = actorUin ?? "unknown"
        let feedSkey = textAt(feed, "/comm/feedskey")
            ?? textAt(feed, "/original/cell_comm/feedskey")
        var feedKey = feedSkey
        if feedKey == nil {
            if let cellID = cellID {
                feedKey = "\(eventType):\(cellID):\(eventTime):\(actorLabel)"
            } else {
                feedKey = "fallback:\(eventType):\(eventTime):\(actorLabel):\(formatFeedHash(stableFeedHash(feed)))"
            }
        }
        let pictures = jsonPointer(feed, "/original/cell_pic")
        let pictureItems = pictures.flatMap { jsonPointer($0, "/picdata/pic") }
        return ParsedFeed(
            feedKey: feedKey ?? "",
            cellID: cellID ?? "",
            eventType: eventType,
            eventTime: eventTime,
            title: textAt(feed, "/title/title"),
            content: textAt(feed, "/original/cell_summary/summary"),
            eventSummary: textAt(feed, "/summary/summary"),
            actorUin: actorUin,
            actorName: textAt(feed, "/userinfo/user/nickname"),
            originalAuthorUin: textAt(feed, "/original/cell_userinfo/user/uin"),
            originalAuthorName: textAt(feed, "/original/cell_userinfo/user/nickname"),
            pictureCount: (pictureItems as? [Any])?.count ?? 0,
            picturesJSON: stableJSON(pictures),
            videoJSON: stableJSON(nonNullValue(jsonPointer(feed, "/original/cell_video"))),
            commentsJSON: stableJSON(nonNullValue(jsonPointer(feed, "/original/cell_comment"))),
            rawJSON: stableJSON(feed) ?? "{}"
        )
    }

    /// FNV-1a 64 位散列, 与 Rust 版 stable_feed_hash 逐位一致
    static func stableFeedHash(_ value: Any) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (stableJSON(value) ?? "").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1_0000_0000_01b3
        }
        return hash
    }

    /// 16 位小写十六进制, 对应 Rust 版 {:016x}
    static func formatFeedHash(_ hash: UInt64) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var text = ""
        for shift in stride(from: 60, through: 0, by: -4) {
            text.append(Character(UnicodeScalar(digits[Int((hash >> UInt64(shift)) & 0xF)])))
        }
        return text
    }

    // MARK: - 动态

    /// 解析原始动态, 与桌面端 saveOriginalDynamic 逐条对应。
    /// 缺少 original 或其中没有 cell_id 时返回 nil (原实现直接跳过该条)
    static func parseOriginalDynamic(_ feed: [String: Any], ownerUin: String) -> ParsedDynamic? {
        guard let original = jsonPointer(feed, "/original") as? [String: Any],
              let cellID = textAt(original, "/cell_id/cellid") else { return nil }
        let appid = asInteger(jsonPointer(original, "/cell_comm/appid")) ?? 0
        let feedSkey = textAt(original, "/cell_comm/feedskey") ?? ""
        let isGuestbook = appid == 334 || feedSkey.hasPrefix("334_")
        let publishedAt = asInteger(jsonPointer(original, "/cell_comm/time"))
            ?? asInteger(jsonPointer(feed, "/comm/time"))
            ?? 0
        let content = isGuestbook
            ? textAt(feed, "/summary/summary")
            : textAt(original, "/cell_summary/summary")
        let authorUin = isGuestbook
            ? textAt(feed, "/userinfo/user/uin")
            : textAt(original, "/cell_userinfo/user/uin")
        let authorName = isGuestbook
            ? textAt(feed, "/userinfo/user/nickname")
            : textAt(original, "/cell_userinfo/user/nickname")
        let pictures = jsonPointer(original, "/cell_pic")
        let pictureItems = pictures.flatMap { jsonPointer($0, "/picdata/pic") }
        return ParsedDynamic(
            cellID: cellID,
            publishedAt: publishedAt,
            content: content ?? "",
            authorUin: authorUin,
            authorName: authorName,
            category: isGuestbook ? .guestbook : (authorUin == ownerUin ? .self_ : .other),
            picturesJSON: stableJSON(pictures),
            videoJSON: stableJSON(nonNullValue(jsonPointer(original, "/cell_video"))),
            pictureCount: (pictureItems as? [Any])?.count ?? 0
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

    /// 逐张图片的首选地址, 对应桌面端 pictureUrls
    static func pictureURLs(_ json: String?) -> [String] {
        guard let pictures = tryParseJsonText(json) as? [Any] else { return [] }
        return pictures.compactMap { pictureCandidates($0).first }
    }

    /// 单张图片的候选地址, 对应桌面端 pictureUrlCandidates (保序去重, 过滤空串)
    static func pictureUrlCandidates(_ json: String?) -> [[String]] {
        guard let json = json, let pictures = tryParseJsonText(json) as? [Any] else { return [] }
        return pictures.map { pictureCandidates($0) }
    }

    /// 单张图片的候选地址 (顺序保留, 去重, 空串过滤)
    static func pictureCandidates(_ picture: Any) -> [String] {
        var candidates: [String] = []
        let photoURL = jsonPointer(picture, "/photourl")
        var entries: [Any] = []
        if let list = photoURL as? [Any] {
            entries = list
        } else if let table = photoURL as? [String: Any] {
            // JS 的 Object.values 对整数键升序优先; Swift 字典无序, 用键排序保证确定性
            entries = table.keys.sorted().compactMap { table[$0] }
        }
        for entry in entries {
            if let url = textAt(entry, "/url") {
                candidates.append(url.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if let busi = textAt(picture, "/busi_param/-1") {
            candidates.append(busi.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates where !candidate.isEmpty {
            guard !seen.contains(candidate) else { continue }
            seen.insert(candidate)
            result.append(candidate.hasPrefix("//") ? "https:" + candidate : candidate)
        }
        return result
    }

    /// 视频地址, 对应桌面端 videoUrls (先单数 videourl, 再复数 videourls 的 url)
    static func videoURLs(_ json: String?) -> [String] {
        guard let root = tryParseJsonText(json) else { return [] }
        var candidates: [String] = []
        if let single = textAt(root, "/videourl") { candidates.append(single) }
        if let table = jsonPointer(root, "/videourls") as? [String: Any] {
            for key in table.keys.sorted() {
                if let url = textAt(table[key] as Any, "/url") { candidates.append(url) }
            }
        }
        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 视频封面, 对应桌面端 videoCoverUrl
    static func videoCoverURL(_ json: String?) -> String? {
        guard let root = tryParseJsonText(json) else { return nil }
        if let first = textAt(root, "/coverurl/0/url") { return first }
        guard let table = jsonPointer(root, "/coverurl") as? [String: Any] else { return nil }
        for key in table.keys.sorted() {
            if let url = textAt(table[key] as Any, "/url") { return url }
        }
        return nil
    }

    /// JSON Pointer (RFC 6901), 与桌面端 jsonPointer 行为一致
    static func jsonPointer(_ object: Any, _ path: String) -> Any? {
        if path.isEmpty { return object }
        guard path.hasPrefix("/") else { return nil }
        var current: Any = object
        for rawToken in path.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = rawToken
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            if let array = current as? [Any] {
                guard isDecimalToken(token), let index = Int(token), index < array.count else { return nil }
                current = array[index]
            } else if let dictionary = current as? [String: Any], let next = dictionary[token] {
                current = next
            } else {
                return nil
            }
        }
        return current
    }

    /// 数组下标只接受纯十进制数字 (对应 JS 的 ^\d+$ 判定)
    private static func isDecimalToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }

    /// 取指针指向的文本: 非空字符串原样返回, 数字转十进制文本, 其余 nil
    static func textAt(_ object: Any, _ path: String) -> String? {
        guard let target = jsonPointer(object, path) else { return nil }
        if target is Bool { return nil }
        if let text = target as? String { return text.isEmpty ? nil : text }
        if let number = target as? NSNumber { return number.stringValue }
        return nil
    }

    /// 只接受整数数字 (JS Number.isInteger), 字符串不参与转换
    static func asInteger(_ value: Any?) -> Int? {
        guard let value = value, !(value is Bool), let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw.rounded() == raw, abs(raw) <= 9_007_199_254_740_992 else { return nil }
        return Int(raw)
    }

    /// 过滤 null 值 (JS 的 null/undefined)
    static func nonNullValue(_ value: Any?) -> Any? {
        guard let value = value, !(value is NSNull) else { return nil }
        return value
    }

    /// 解析 JSON 文本, 失败返回 nil
    static func tryParseJsonText(_ text: String?) -> Any? {
        guard let text = text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// 从任意值取非空文本
    static func string(_ value: Any?) -> String? {
        guard let value = value else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// 从任意值取整数
    static func integer(_ value: Any?) -> Int? {
        asInteger(value)
    }

    /// 校验归档分类, 与 Rust 版 validate_category 对应
    static func validateCategory(_ category: String) throws {
        guard category == "self" || category == "other" || category == "guestbook" else {
            throw QzoneError.parseFailed("非法归档分类: \(category)")
        }
    }

    static func pictureCount(_ json: String?) -> Int {
        guard let root = tryParseJsonText(json),
              let pictures = jsonPointer(root, "/picdata/pic") as? [Any] else { return 0 }
        return pictures.count
    }

    /// 稳定 JSON 文本: 递归按键升序并紧凑输出 (对应桌面端 stableJsonText)
    static func stableJSON(_ value: Any?) -> String? {
        guard let value = value,
              let normalized = normalizeJSONValue(value),
              JSONSerialization.isValidJSONObject(normalized),
              let data = try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// 递归按键排序, 丢弃无法序列化的值
    private static func normalizeJSONValue(_ value: Any) -> Any? {
        switch value {
        case let dictionary as [String: Any]:
            var result: [String: Any] = [:]
            for (key, element) in dictionary {
                if let normalized = normalizeJSONValue(element) { result[key] = normalized }
            }
            return result
        case let array as [Any]:
            return array.compactMap { normalizeJSONValue($0) }
        case let text as String:
            return text
        case let number as NSNumber:
            return number
        case is NSNull:
            return NSNull()
        default:
            return nil
        }
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
