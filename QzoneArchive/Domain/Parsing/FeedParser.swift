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
    /// 与桌面端 saveFeedRows 的行为对应: 每条记录都先按 original 更新动态
    /// (图片与视频在冲突时保留已有非空值), 评论与点赞再按 cell_id 聚合到同一动态上
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

            // 原版对每条互动记录都执行 save_original_dynamic, 评论与点赞通知同样带 original
            if let dynamic = parseOriginalDynamic(feed, ownerUin: account.qqUin), !dynamic.cellID.isEmpty {
                let pictures = pictureURLs(dynamic.picturesJSON)
                let videos = videoURLs(dynamic.videoJSON)
                let cover = videoCoverURL(dynamic.videoJSON)
                if var existing = dynamics[dynamic.cellID] {
                    // 冲突更新时图片与视频保留库中已有的非空值
                    if !pictures.isEmpty { existing.pictureURLs = pictures }
                    if !videos.isEmpty { existing.videoURLs = videos }
                    if let cover { existing.videoCoverURL = cover }
                    existing.authorUin = dynamic.authorUin ?? existing.authorUin
                    existing.authorName = dynamic.authorName ?? existing.authorName
                    if !dynamic.content.isEmpty { existing.contentText = dynamic.content }
                    if dynamic.publishedAt > 0 {
                        existing.publishedAt = Date(timeIntervalSince1970: TimeInterval(dynamic.publishedAt))
                    }
                    existing.category = dynamic.category
                    dynamics[dynamic.cellID] = existing
                } else {
                    order.append(dynamic.cellID)
                    dynamics[dynamic.cellID] = ArchivePost(
                        id: 0,
                        accountID: account.id,
                        sourceID: dynamic.cellID,
                        authorUin: dynamic.authorUin,
                        authorName: dynamic.authorName,
                        contentText: dynamic.content,
                        publishedAt: dynamic.publishedAt > 0
                            ? Date(timeIntervalSince1970: TimeInterval(dynamic.publishedAt))
                            : nil,
                        archivedAt: Date(),
                        postType: "text",
                        sourceURL: nil,
                        rawPayloadPath: nil,
                        isDeleted: false,
                        pictureURLs: pictures,
                        videoURLs: videos,
                        videoCoverURL: cover,
                        likeCount: 0,
                        commentCount: 0,
                        category: dynamic.category,
                        likes: [],
                        comments: []
                    )
                }
            }

            if parsed.eventType == eventTypeLike {
                let user = LikeUser(uin: parsed.actorUin, nickname: parsed.actorName)
                likesByCell[cellID, default: []].append(user)
                continue
            }
            if parsed.eventType == eventTypeComment || parsed.eventType == eventTypeCommentAlt {
                let comment = commentFromValues(
                    commentsJSON: parsed.commentsJSON,
                    actorUin: parsed.actorUin,
                    actorName: parsed.actorName,
                    eventSummary: parsed.eventSummary,
                    eventTime: parsed.eventTime
                )
                commentsByCell[cellID, default: []].append(comment)
            }
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

    /// 回复去重比较, 对应 Rust 版 same_reply 的 uin/content/created_at 三元组
    static func sameReply(_ left: ArchivedReply, _ right: ArchivedReply) -> Bool {
        left.uin == right.uin && left.content == right.content && left.createdAt == right.createdAt
    }

    /// 取数组字段, 非数组按空列表处理 (对应 array_field 的 and_then(as_array))
    static func arrayField(_ value: Any?, _ pointers: String...) -> [Any] {
        var current: Any? = value
        for pointer in pointers {
            guard let base = current else { return [] }
            current = jsonPointer(base, pointer)
        }
        return current as? [Any] ?? []
    }

    /// 解析单条回复, 对应 Rust 版 reply_from_value, 缺少正文时返回 nil
    static func replyFromValue(_ value: Any) -> ArchivedReply? {
        guard let content = textAt(value, "/content") else { return nil }
        return ArchivedReply(
            uin: textAt(value, "/user/uin") ?? textAt(value, "/replyuser/uin"),
            nickname: textAt(value, "/user/nickname") ?? textAt(value, "/replyuser/nickname"),
            replyToUin: textAt(value, "/replyuser/uin")
                ?? textAt(value, "/targetuser/uin")
                ?? textAt(value, "/target/uin"),
            replyToNickname: textAt(value, "/replyuser/nickname")
                ?? textAt(value, "/targetuser/nickname")
                ?? textAt(value, "/target/nickname"),
            content: content,
            createdAt: asInteger(jsonPointer(value, "/date")) ?? 0
        )
    }

    ///
    /// 由互动记录的评论字段构造评论, 与 Rust 版 comment_from_values 逐条对应
    ///
    /// 主评论取 main_comment; 主评论下的 replys 与同 commentid 的 comments 项回复合并去重;
    /// 回复通知这类记录把回复正文与作者放在互动记录本身, 需要补一条指向最近一条对端回复的回复
    ///
    static func commentFromValues(
        commentsJSON: String?,
        actorUin: String?,
        actorName: String?,
        eventSummary: String?,
        eventTime: Int
    ) -> ParsedComment {
        let value = tryParseJsonText(commentsJSON)
        let main = jsonPointer(value, "/main_comment")
        let commentID = textAt(main, "/commentid")
        let mainUin = textAt(main, "/user/uin")
        let mainName = textAt(main, "/user/nickname")
        let mainContent = textAt(main, "/content")
        let mainTime = asInteger(jsonPointer(main, "/date")) ?? eventTime

        var replies: [ArchivedReply] = []
        for item in arrayField(main, "/replys") {
            if let reply = replyFromValue(item) { replies.append(reply) }
        }
        if let commentID {
            for comment in arrayField(value, "/comments")
            where textAt(comment, "/commentid") == commentID {
                for item in arrayField(comment, "/replys") {
                    guard let reply = replyFromValue(item) else { continue }
                    if !replies.contains(where: { sameReply($0, reply) }) { replies.append(reply) }
                }
            }
        }

        // 回复通知把被回复的主评论放在 main_comment, 真正的回复正文与作者放在互动记录上;
        // 当主评论作者再次回复时, 回复对象取此前最后一条来自对端的回复
        let isReplyNotification =
            (asInteger(jsonPointer(main, "/replynum")) ?? 0) > 0
            && mainUin != nil
            && actorUin != nil
            && mainContent != eventSummary
            && eventTime > mainTime
        if isReplyNotification, let content = eventSummary {
            let duplicate = replies.contains { $0.uin == actorUin && $0.content == content }
            if !duplicate {
                var target: ArchivedReply?
                for reply in replies {
                    if reply.uin == actorUin || reply.createdAt > eventTime { continue }
                    if target == nil || reply.createdAt >= target!.createdAt { target = reply }
                }
                replies.append(
                    ArchivedReply(
                        uin: actorUin,
                        nickname: actorName,
                        replyToUin: target?.uin ?? mainUin,
                        replyToNickname: target?.nickname ?? mainName,
                        content: content,
                        createdAt: eventTime
                    )
                )
            }
        }

        let comment = ParsedComment(
            id: "",
            uin: mainUin ?? actorUin,
            nickname: mainName ?? actorName,
            content: mainContent ?? eventSummary ?? "评论了这条动态",
            createdAt: mainTime,
            replies: sortReplies(replies),
            commentID: commentID
        )
        return comment.withStableID()
    }

    /// 合并同一原动态下的多条评论, 与 Rust 版 merge_comments 对应
    static func mergeComments(_ comments: [ParsedComment]) -> [ParsedComment] {
        var merged: [ParsedComment] = []
        for comment in comments {
            if let index = merged.firstIndex(where: { candidate in
                (comment.commentID != nil && candidate.commentID == comment.commentID)
                    || (candidate.uin == comment.uin
                        && candidate.content == comment.content
                        && candidate.createdAt == comment.createdAt)
            }) {
                for reply in comment.replies
                where !merged[index].replies.contains(where: { sameReply($0, reply) }) {
                    merged[index].replies.append(reply)
                }
                merged[index].replies = sortReplies(merged[index].replies)
                continue
            }
            var copy = comment
            copy.replies = sortReplies(copy.replies)
            merged.append(copy)
        }
        return merged
    }

    /// 稳定排序, 与 Rust 的 sort_by_key 一致
    static func sortReplies(_ replies: [ArchivedReply]) -> [ArchivedReply] {
        replies.enumerated()
            .sorted { left, right in
                if left.element.createdAt == right.element.createdAt { return left.offset < right.offset }
                return left.element.createdAt < right.element.createdAt
            }
            .map(\.element)
    }

    /// 评论的稳定标识: 有 commentid 用 commentid, 否则用 uin/时间/正文的 FNV 哈希
    static func commentStableID(commentID: String?, uin: String?, createdAt: Int, content: String) -> String {
        if let commentID, !commentID.isEmpty { return "c-\(commentID)" }
        let digest = formatFeedHash(stableFeedHash([uin ?? "", String(createdAt), content]))
        return "c-\(digest)"
    }

    // MARK: - 媒体地址

    /// 逐张图片的首选地址, 对应桌面端 pictureUrls
    static func pictureURLs(_ json: String?) -> [String] {
        pictureUrlCandidates(json).compactMap { $0.first }
    }

    /// 每张图片的候选地址, 对应桌面端 pictureUrlCandidates
    ///
    /// 缺少 photourl 字段的图片不进入结果, 候选为空的图片同样跳过 (与原版 push 条件一致)
    static func pictureUrlCandidates(_ json: String?) -> [[String]] {
        guard let root = tryParseJsonText(json),
              let pictures = jsonPointer(root, "/picdata/pic") as? [Any] else { return [] }
        var result: [[String]] = []
        for picture in pictures {
            guard let object = picture as? [String: Any], object["photourl"] != nil else { continue }
            let candidates = pictureCandidates(picture)
            if !candidates.isEmpty { result.append(candidates) }
        }
        return result
    }

    /// 单张图片的候选地址: photourl 各项的 url, 再补 busi_param 的 -1 项
    ///
    /// 以双斜杠开头的地址补全协议, 组内按补全后的地址去重 (与原版 seen 的键一致)
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
            let url = candidate.hasPrefix("//") ? "https:" + candidate : candidate
            guard seen.insert(url).inserted else { continue }
            result.append(url)
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

    /// 判断是否为 JSON 布尔值
    ///
    /// 注意不能用 `value is Bool`: NSNumber(0/1) 在 Darwin 上也能桥接成 Bool,
    /// 会把真实的数字 1 误判为布尔 (replynum/hasmore 都是 0/1)
    static func isJSONBool(_ value: Any) -> Bool {
        return CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// 取指针指向的文本: 非空字符串原样返回, 数字转十进制文本, 其余 nil
    static func textAt(_ object: Any, _ path: String) -> String? {
        guard let target = jsonPointer(object, path) else { return nil }
        if isJSONBool(target) { return nil }
        if let text = target as? String { return text.isEmpty ? nil : text }
        if let number = target as? NSNumber { return number.stringValue }
        return nil
    }

    /// 只接受整数数字 (JS Number.isInteger), 字符串不参与转换
    static func asInteger(_ value: Any?) -> Int? {
        guard let value = value, !isJSONBool(value), let number = value as? NSNumber else { return nil }
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
    /// 原版 commentId, 仅用于聚合去重, 不进入输出
    var commentID: String? = nil
}

extension ParsedComment {
    /// 按原版规则生成稳定标识 (commentid 优先, 否则三元组哈希)
    func withStableID() -> ParsedComment {
        var copy = self
        copy.id = FeedParser.commentStableID(
            commentID: commentID,
            uin: uin,
            createdAt: createdAt,
            content: content
        )
        return copy
    }

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
