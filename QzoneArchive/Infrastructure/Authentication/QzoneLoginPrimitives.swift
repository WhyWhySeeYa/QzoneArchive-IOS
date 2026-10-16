//
//  QzoneLoginPrimitives.swift
//  QzoneArchive
//
//  QQ 登录基础件: 哈希, UA 选择, Cookie 解析, 回调文本解析
//
//  与桌面端 loginPrimitives.ts 的行为逐项对齐
//

import Foundation

/// 登录原语纯函数集合
enum QzoneLoginPrimitives {
    /// 一加应用标识, 与原 Rust 版一致
    static let appID = "549000929"
    static let daID = "5"

    /// 移动端 UA 池
    static let mobileUserAgents: [String] = [
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (Linux; Android 15; Pixel 8 Build/AP3A.241105.007) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36",
        "Mozilla/5.0 (Linux; Android 14; SM-S9280 Build/UP1A.231005.007) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36",
        "Mozilla/5.0 (Linux; Android 14; 23127PN0CC Build/UKQ1.231003.002) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36",
        "Mozilla/5.0 (Linux; Android 14; V2309A Build/UP1A.231005.007) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36",
    ]

    /// 凭证导出的 Cookie 白名单
    static let credentialCookieNames = ["uin", "skey", "p_uin", "pt4_token", "p_skey", "pt2gguin"]

    /// ptqrtoken 计算: 对 qrsig 做 5 位左移累加, 取低 31 位
    static func ptqrToken(_ qrsig: String) -> UInt32 {
        var value: UInt32 = 0
        for character in qrsig.unicodeScalars {
            value = value &+ (value << 5) &+ UInt32(character.value)
        }
        return value & 0x7fff_ffff
    }

    /// bkn 计算: 以 5381 为初值的 5 位左移累加, 取低 31 位
    static func bkn(_ pSkey: String) -> UInt32 {
        var value: UInt32 = 5381
        for character in pSkey.unicodeScalars {
            value = value &+ (value << 5) &+ UInt32(character.value)
        }
        return value & 0x7fff_ffff
    }

    /// 从回调文本中取查询参数
    static func callbackQueryValue(_ text: String, name: String) -> String? {
        let pattern = "(?:[?&]|')\(NSRegularExpression.escapedPattern(for: name))=([^&']+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[valueRange])
    }

    /// 取第 3 个单引号参数, 仅当首参为 0 时视为登录跳转地址
    static func pollLoginURL(_ text: String) -> String? {
        let parts = text.components(separatedBy: "'")
        guard parts.count >= 4, parts[1] == "0" else { return nil }
        return parts[3]
    }

    /// 去掉 uin 前缀的 o 与前导 0
    static func normalizedUin(_ value: String) -> String {
        var result = value
        while result.hasPrefix("o") { result.removeFirst() }
        while result.hasPrefix("0") { result.removeFirst() }
        return result
    }

    /// 随机十六进制串
    static func randomHex(length: Int) -> String {
        var result = ""
        result.reserveCapacity(length)
        while result.count < length {
            let chunk = String(format: "%08x", UInt32.random(in: 0..<UInt32.max))
            result += chunk
        }
        return String(result.prefix(length))
    }

    /// 随机大小写字母加数字混合串
    static func randomAlphanumeric(length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var result = ""
        result.reserveCapacity(length)
        while result.count < length {
            result.append(chars[Int.random(in: 0..<chars.count)])
        }
        return result
    }

    /// 形如 UUID 的随机串
    static func randomUUIDLike() -> String {
        "\(randomHex(length: 8))-\(randomHex(length: 4))-\(randomHex(length: 4))-\(randomHex(length: 4))-\(randomHex(length: 12))"
    }

    /// 毫秒时间戳
    static func unixMillis() -> Int {
        Int((Date().timeIntervalSince1970 * 1000).rounded())
    }

    /// 按 uin 固定选择 UA
    static func accountUserAgent(uin: String) -> String {
        var hash: UInt32 = 0
        for byte in Array(uin.utf8) {
            hash = hash &* 31 &+ UInt32(byte)
        }
        return mobileUserAgents[Int(hash % UInt32(mobileUserAgents.count))]
    }

    /// 拼接 Cookie 头, 顺序与桌面端一致
    static func cookieHeader(_ cookies: [String: String]) -> String {
        cookies.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// 只导出白名单内的非空 Cookie
    static func loginCredentials(from cookies: [String: String], uin: String) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in cookies {
            if credentialCookieNames.contains(name) && !value.isEmpty {
                result[name] = value
            }
        }
        return result
    }

    /// 随机选择 UA, 避免与上一次重复
    static func selectMobileUserAgent(previous: String?) -> String {
        let selected = mobileUserAgents.randomElement() ?? mobileUserAgents[0]
        if selected == previous, let alternative = mobileUserAgents.first(where: { $0 != previous }) {
            return alternative
        }
        return selected
    }
}
