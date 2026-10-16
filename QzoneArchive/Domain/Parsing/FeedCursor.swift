//
//  FeedCursor.swift
//  QzoneArchive
//
//  分页游标解析与推进
//
//  与桌面端 core/feedCursor.ts 的三层嵌套查询串解析一致
//

import Foundation

/// 游标详情
struct FeedCursorDetails {
    var offset: Int
    var baseTime: Int
    var loadCount: Int
}

/// 游标解析与推进
enum FeedCursor {
    /// 解析三层嵌套游标
    static func parse(_ cursor: String) throws -> FeedCursorDetails {
        guard let outer = parseQueryPairs(cursor) else { throw QzoneError.parseFailed("分页游标格式无效") }
        guard let attachRaw = outer["att"] else { throw QzoneError.parseFailed("分页游标缺少 att") }
        guard let attach = parseQueryPairs(attachRaw) else { throw QzoneError.parseFailed("分页游标 att 无效") }
        guard let backendRaw = attach["back_server_info"] else { throw QzoneError.parseFailed("分页游标缺少 back_server_info") }
        guard let backend = parseQueryPairs(backendRaw) else { throw QzoneError.parseFailed("分页游标 back_server_info 无效") }
        guard let offsetRaw = backend["offset"], let offset = Int(offsetRaw) else {
            throw QzoneError.parseFailed("分页游标缺少 offset")
        }
        guard let baseTimeRaw = backend["basetime"], let baseTime = Int(baseTimeRaw) else {
            throw QzoneError.parseFailed("分页游标缺少 basetime")
        }
        var loadCount = 0
        let loadCountRaw = outer["loadcount"] ?? attach["loadcount"]
        if let loadCountRaw, let parsed = Int(loadCountRaw) { loadCount = parsed }
        return FeedCursorDetails(offset: offset, baseTime: baseTime, loadCount: loadCount)
    }

    /// 按偏移推进游标
    static func advance(_ cursor: String, offsetAdvance: Int) throws -> String {
        guard offsetAdvance > 0 else { throw QzoneError.parseFailed("跳过偏移量必须大于 0") }
        let details = try parse(cursor)
        var outer = try parse(cursor)
        guard let attachRaw = outer["att"], var attach = parseQueryPairs(attachRaw),
              let backendRaw = attach["back_server_info"], var backend = parseQueryPairs(backendRaw)
        else { throw QzoneError.parseFailed("分页游标结构不完整") }
        let loadCountInOuter = outer["loadcount"] != nil

        backend["offset"] = String(details.offset + offsetAdvance)
        attach["back_server_info"] = serializeQueryPairs(backend)
        if !loadCountInOuter { attach["loadcount"] = String(details.loadCount + 1) }
        outer["att"] = serializeQueryPairs(attach)
        if loadCountInOuter { outer["loadcount"] = String(details.loadCount + 1) }
        return serializeQueryPairs(outer)
    }

    /// 异常页向前探测的偏移序列
    static func skipProbeOffsets(firstAdvance: Int, maxAdvance: Int = 4096) -> [Int] {
        let first = min(max(1, firstAdvance), maxAdvance)
        var offsets = [first]
        var candidate = 1
        while candidate <= first && candidate < maxAdvance { candidate *= 2 }
        while candidate < maxAdvance {
            offsets.append(candidate)
            candidate *= 2
        }
        if offsets.last != maxAdvance { offsets.append(maxAdvance) }
        return offsets
    }

    // MARK: - 查询串

    /// 解析查询串为键值表
    static func parseQueryPairs(_ value: String) -> [String: String]? {
        guard !value.isEmpty else { return nil }
        var result: [String: String] = [:]
        for pair in value.components(separatedBy: "&") where !pair.isEmpty {
            let parts = pair.split(separator: "=", maxSplits: 1)
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let raw = parts.count > 1 ? String(parts[1]) : ""
            result[key] = raw.removingPercentEncoding ?? raw
        }
        return result
    }

    /// 序列化键值表, 保留插入顺序
    static func serializeQueryPairs(_ pairs: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = pairs.map { URLQueryItem(name: $0.key, value: $1.value) }
        let query = components.percentEncodedQuery ?? ""
        // 去掉首部的问号
        return query.hasPrefix("?") ? String(query.dropFirst()) : query
    }
}
