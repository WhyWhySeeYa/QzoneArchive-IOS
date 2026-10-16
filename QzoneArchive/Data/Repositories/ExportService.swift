//
//  ExportService.swift
//  QzoneArchive
//
//  导出: 单文件 HTML, CSV, 媒体打包, 导出设置
//

import Foundation

/// 导出服务
final class ExportService {
    private let database: ArchiveDatabase
    private let storage: FileStorageService
    private let repository: ArchiveRepository
    private let logger = AppLogger()

    init(database: ArchiveDatabase, storage: FileStorageService = FileStorageService()) {
        self.database = database
        self.storage = storage
        self.repository = SQLiteArchiveRepository(database: database)
    }

    /// 导出 HTML 归档
    func exportHTML(account: Account, category: ArchiveCategory, ids: [Int]?) throws -> URL {
        let posts: [ArchivePost]
        if let ids, !ids.isEmpty {
            posts = try ids.compactMap { try? repository.fetchPost(account: account, id: $0) }
            if posts.isEmpty { throw QzoneError.unknown("请先选择需要导出的归档") }
        } else {
            posts = try repository.listPosts(account: account, category: category, limit: 100_000, offset: 0)
        }
        if posts.isEmpty { throw QzoneError.unknown("当前分类没有可以导出的归档") }
        let html = HTMLRenderer.renderPage(category: category, account: account, posts: posts)
        let fileName = "QzoneArchive-\(category.displayName)-\(Int(Date().timeIntervalSince1970)).html"
        let url = storage.exportsDirectory.appendingPathComponent(fileName)
        try storage.atomicWrite(Data(html.utf8), to: url)
        return url
    }

    /// 导出 CSV 索引
    func exportCSV(account: Account, category: ArchiveCategory) throws -> URL {
        let posts = try repository.listPosts(account: account, category: category, limit: 100_000, offset: 0)
        if posts.isEmpty { throw QzoneError.unknown("当前分类没有可以导出的归档") }
        var lines = ["ID,发布时间,作者,作者QQ,分类,内容,图片数,视频数,点赞数,评论数"]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for post in posts {
            let published = post.publishedAt.map { formatter.string(from: $0) } ?? ""
            let author = post.authorName ?? ""
            let authorUin = post.authorUin ?? ""
            let content = post.contentText
                .replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\n", with: " ")
            lines.append("\(post.id),\"\(published)\",\"\(author)\",\"\(authorUin)\",\"\(category.displayName)\",\"\(content)\",\(post.pictureURLs.count),\(post.videoURLs.count),\(post.likeCount),\(post.commentCount)")
        }
        let csv = lines.joined(separator: "\n")
        let url = storage.exportsDirectory.appendingPathComponent("QzoneArchive-\(category.displayName)-\(Int(Date().timeIntervalSince1970)).csv")
        try storage.atomicWrite(Data(csv.utf8), to: url)
        return url
    }

    /// 导出日志
    func exportLogs() -> URL {
        let url = storage.logsDirectory.appendingPathComponent("qzonearchive.log")
        let exportURL = storage.exportsDirectory.appendingPathComponent("QzoneArchive-logs-\(Int(Date().timeIntervalSince1970)).txt")
        let content = AppLogger.redact((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        try? storage.atomicWrite(Data(content.utf8), to: exportURL)
        return exportURL
    }

    /// 导出目录内容
    func listExports() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: storage.exportsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]
        )) ?? []
        return urls.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return lhsDate > rhsDate
        }
    }

    /// 删除导出文件
    func deleteExport(url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - HTML 渲染

/// 单文件导出页渲染, 与桌面端 archiveExport.ts 的结构一致
enum HTMLRenderer {
    private static let categoryNames: [String: String] = [
        "self": "本人动态",
        "other": "其他动态",
        "guestbook": "留言",
    ]

    private static let mentionPattern = try? NSRegularExpression(
        pattern: #"@\{uin:([^,}]+),nick:([^}]+)\}"#,
        options: []
    )

    static func renderPage(category: ArchiveCategory, account: Account, posts: [ArchivePost]) -> String {
        let categoryName = categoryNames[category.raw] ?? "留言"
        let cards = posts.map { renderCard($0) }.joined()
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>QQ空间归档 - \(categoryName)</title><style>*{box-sizing:border-box}body{margin:0;background:#f3f6fb;color:#243247;font:14px/1.7 system-ui,-apple-system,"Microsoft YaHei",sans-serif}main{width:min(820px,calc(100% - 24px));margin:30px auto}h1{margin:0}.intro{color:#758298;margin:0 0 20px}.card{background:#fff;border:1px solid #e5eaf2;border-radius:16px;padding:20px;margin:14px 0;box-shadow:0 8px 25px #2038580b}header{display:flex;gap:11px;align-items:center}.avatar{width:44px;height:44px;border-radius:50%}header strong,header small{display:block}small,.muted,.stats{color:#7e899a}.content{margin:14px 0;white-space:pre-wrap;overflow-wrap:anywhere}.mention,a{color:#2684ff}.pictures{display:grid;grid-template-columns:repeat(3,1fr);gap:6px}.pictures img{display:block;width:100%;height:210px;object-fit:cover;border-radius:8px}.video{display:inline-block;padding:7px 12px;background:#edf5ff;border-radius:9px;text-decoration:none}.stats{margin-top:12px}.comments{margin-top:12px;padding:12px;background:#f6f8fb;border-radius:10px}.comment{margin:8px 0}.comment-meta{margin-bottom:3px;color:#7e899a;font-size:11px}.comment-meta b{color:#2684ff}.replies{margin:6px 0 0 18px;padding:7px 10px;background:#fff;border-radius:0 7px 7px 0;border-left:2px solid #c9dcf6}@media(max-width:600px){main{margin:16px auto}.card{padding:15px}.pictures img{height:125px}}</style></head><body><main><h1>QQ空间归档 · \(categoryName)</h1><p class="intro">账号 \(account.qqUin) · 共 \(posts.count) 条 · 导出时间 <span id="export-time"></span></p>\(cards)</main><script>document.querySelector('#export-time').textContent=new Date().toLocaleString();document.querySelectorAll('time[data-time]').forEach(e=>e.textContent=new Date(Number(e.dataset.time)*1000).toLocaleString());</script></body></html>
        """
    }

    private static func renderCard(_ post: ArchivePost) -> String {
        let author = post.authorName ?? post.authorUin ?? "QQ 用户"
        let uin = post.authorUin ?? "0"
        let publishedAt = Int(post.publishedAt?.timeIntervalSince1970 ?? 0)
        var parts: [String] = []
        parts.append("<article class=\"card\"><header><img class=\"avatar\" src=\"https://qlogo2.store.qq.com/qzone/\(escape(uin))/\(escape(uin))/50\"><div><strong>\(escape(author))</strong><small>")
        if post.authorUin != nil {
            parts.append("QQ \(escape(uin)) · ")
        }
        parts.append("<time data-time=\"\(publishedAt)\"></time></small></div></header><div class=\"content\">\(qzoneTextHTML(post.contentText))</div>")
        if !post.pictureURLs.isEmpty {
            parts.append("<div class=\"pictures\">")
            for url in post.pictureURLs {
                parts.append("<a href=\"\(escape(url))\" target=\"_blank\"><img loading=\"lazy\" referrerpolicy=\"no-referrer\" src=\"\(escape(url))\"></a>")
            }
            parts.append("</div>")
        }
        if let videoURL = post.videoURLs.first {
            parts.append("<p><a class=\"video\" href=\"\(escape(videoURL))\" target=\"_blank\">▶ 查看视频</a></p>")
        }
        parts.append("<div class=\"stats\">")
        if !post.likes.isEmpty {
            parts.append("♥ ")
            let names = post.likes.prefix(10).map { escape($0.nickname ?? $0.uin ?? "QQ用户") }
            parts.append(names.joined(separator: "、"))
            if post.likes.count > 10 {
                parts.append(" 等 \(post.likeCount) 人赞了")
            } else {
                parts.append(" 赞了")
            }
        }
        parts.append("　💬 \(post.commentCount) 条评论</div>")
        if !post.comments.isEmpty {
            parts.append("<section class=\"comments\">")
            for comment in post.comments {
                let commentName = comment.authorName ?? comment.authorUin ?? "QQ 用户"
                let commentTime = Int(comment.publishedAt?.timeIntervalSince1970 ?? 0)
                parts.append("<div class=\"comment\"><div class=\"comment-meta\"><b>\(escape(commentName))</b> 评论于 <time data-time=\"\(commentTime)\"></time></div>\(qzoneTextHTML(comment.contentText))")
                if !comment.replies.isEmpty {
                    parts.append("<div class=\"replies\">")
                    for reply in comment.replies {
                        let replyName = reply.nickname ?? reply.uin ?? commentName
                        parts.append("<div><div class=\"comment-meta\"><b>\(escape(replyName))</b> 回复 \(escape(commentName)) · <time data-time=\"\(reply.createdAt)\"></time></div>\(qzoneTextHTML(reply.content))</div>")
                    }
                    parts.append("</div>")
                }
                parts.append("</div>")
            }
            parts.append("</section>")
        }
        parts.append("</article>")
        return parts.joined()
    }

    /// HTML 转义, 与基准的替换顺序一致
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// 空间正文转 HTML: 提及语法转带 QQ 号的 span
    static func qzoneTextHTML(_ value: String) -> String {
        let source = value
        var text = source
        while text.hasPrefix("：") || text.hasPrefix(":") {
            text.removeFirst()
        }
        while text.first?.isWhitespace == true {
            text.removeFirst()
        }
        var html = ""
        var cursor = text.startIndex
        let regex = mentionPattern
        if let regex {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                guard let range = Range(match.range(at: 0), in: text) else { continue }
                let before = String(text[cursor..<range.lowerBound])
                html += escape(before)
                let uin = match.numberOfRanges > 1 && Range(match.range(at: 1), in: text) != nil
                    ? String(text[Range(match.range(at: 1), in: text)!]) : ""
                let nick = match.numberOfRanges > 2 && Range(match.range(at: 2), in: text) != nil
                    ? String(text[Range(match.range(at: 2), in: text)!]) : ""
                html += "<span class=\"mention\" title=\"QQ \(escape(uin))\">@\(escape(nick))</span>"
                cursor = range.upperBound
            }
        }
        html += escape(String(text[cursor...]))
        if html.isEmpty { return "<span class=\"muted\">该动态没有文字内容</span>" }
        return html
    }
}
