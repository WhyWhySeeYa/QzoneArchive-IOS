//
//  FeedCursor.swift
//  QzoneArchive
//
//  分页游标解析与推进
//
//  与桌面端 core/feedCursor.ts 的三层嵌套查询串解析一致
//

import Foundation

/// 保序键值对
struct QueryPair: Equatable {
    var key: String
    var value: String
}

/// 键值表查找
extension Array where Element == QueryPair {
    /// 按键取值, 取第一个匹配
    subscript(key key: String) -> String? {
        first(where: { $0.key == key })?.value
    }

    /// 改写已存在的键, 对应原实现 setPairValue: 键不存在即视为游标损坏
    mutating func setExisting(key: String, value: String) throws {
        guard let index = firstIndex(where: { $0.key == key }) else {
            throw QzoneError.parseFailed("分页游标缺少 \(key)")
        }
        self[index].value = value
    }

    /// 存在则改写, 不存在则追加, 对应原实现 setOrAppendPairValue
    mutating func setOrAppend(key: String, value: String) {
        if let index = firstIndex(where: { $0.key == key }) {
            self[index].value = value
        } else {
            append(QueryPair(key: key, value: value))
        }
    }
}

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
        guard let attachRaw = outer[key: "att"] else { throw QzoneError.parseFailed("分页游标缺少 att") }
        guard let attach = parseQueryPairs(attachRaw) else { throw QzoneError.parseFailed("分页游标 att 无效") }
        guard let backendRaw = attach[key: "back_server_info"] else { throw QzoneError.parseFailed("分页游标缺少 back_server_info") }
        guard let backend = parseQueryPairs(backendRaw) else { throw QzoneError.parseFailed("分页游标 back_server_info 无效") }
        guard let offsetRaw = backend[key: "offset"], let offset = Int(offsetRaw) else {
            throw QzoneError.parseFailed("分页游标缺少 offset")
        }
        guard let baseTimeRaw = backend[key: "basetime"], let baseTime = Int(baseTimeRaw) else {
            throw QzoneError.parseFailed("分页游标缺少 basetime")
        }
        var loadCount = 0
        let loadCountRaw = outer[key: "loadcount"] ?? attach[key: "loadcount"]
        if let loadCountRaw, let parsed = Int(loadCountRaw) { loadCount = parsed }
        return FeedCursorDetails(offset: offset, baseTime: baseTime, loadCount: loadCount)
    }

    /// 按偏移推进游标
    static func advance(_ cursor: String, offsetAdvance: Int) throws -> String {
        guard offsetAdvance > 0 else { throw QzoneError.parseFailed("跳过偏移量必须大于 0") }
        let details = try parse(cursor)
        guard var outer = parseQueryPairs(cursor) else { throw QzoneError.parseFailed("分页游标格式无效") }
        guard let attachRaw = outer[key: "att"], var attach = parseQueryPairs(attachRaw),
              let backendRaw = attach[key: "back_server_info"], var backend = parseQueryPairs(backendRaw)
        else { throw QzoneError.parseFailed("分页游标结构不完整") }
        let loadCountInOuter = outer[key: "loadcount"] != nil

        try backend.setExisting(key: "offset", value: String(details.offset + offsetAdvance))
        try attach.setExisting(key: "back_server_info", value: serializeQueryPairs(backend))
        if !loadCountInOuter { attach.setOrAppend(key: "loadcount", value: String(details.loadCount + 1)) }
        try outer.setExisting(key: "att", value: serializeQueryPairs(attach))
        if loadCountInOuter { outer.setOrAppend(key: "loadcount", value: String(details.loadCount + 1)) }
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

    /// 解析查询串为键值表, 保留插入顺序
    static func parseQueryPairs(_ value: String) -> [QueryPair]? {
        guard !value.isEmpty else { return nil }
        var result: [QueryPair] = []
        for pair in value.components(separatedBy: "&") where !pair.isEmpty {
            let parts = pair.split(separator: "=", maxSplits: 1)
            let key = formDecode(String(parts[0]))
            let raw = parts.count > 1 ? String(parts[1]) : ""
            result.append(QueryPair(key: key, value: formDecode(raw)))
        }
        return result
    }

    /// 序列化键值表, 保留插入顺序
    /// 用 application/x-www-form-urlencoded 编码, 与 URLSearchParams.toString() 一致
    static func serializeQueryPairs(_ pairs: [QueryPair]) -> String {
        pairs
            .map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&")
    }

    /// 百分号解码: '+' 视作空格, 非法转义原样保留 (URLSearchParams 的行为)
    private static func formDecode(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x2B {
                decoded.append(0x20)
                index += 1
            } else if byte == 0x25, index + 2 < bytes.count,
                      let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                decoded.append(high << 4 | low)
                index += 3
            } else {
                decoded.append(byte)
                index += 1
            }
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    /// 百分号编码: 保留 A-Za-z0-9 与 * - . _, 空格转 '+', 其余按 UTF-8 字节转义
    private static func formEncode(_ value: String) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2A, 0x2D, 0x2E, 0x5F:
                result.append(Character(UnicodeScalar(byte)))
            case 0x20:
                result.append("+")
            default:
                result.append(Character(UnicodeScalar(0x25)))
                result.append(Character(UnicodeScalar(digits[Int(byte >> 4)])))
                result.append(Character(UnicodeScalar(digits[Int(byte & 0x0F)])))
            }
        }
        return result
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}
