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

    /// 从 ptuiCB 回调里取跳转地址
    /// 对应参考实现 pollLoginUrl: 取出所有单引号包裹的片段,
    /// 第 1 个是状态码, 第 3 个是跳转地址 (如 ptuiCB('0','0','<url>','0','登录成功',''))
    static func pollLoginURL(_ text: String) -> String? {
        let values = quotedValues(text)
        guard values.count >= 3, values[0] == "0" else { return nil }
        return values[2]
    }

    /// 取出所有单引号包裹的片段, 对应参考实现的正则 /'([^']*)'/g
    static func quotedValues(_ text: String) -> [String] {
        var values: [String] = []
        var current: String?
        for character in text {
            if character == "'" {
                if let value = current {
                    values.append(value)
                    current = nil
                } else {
                    current = ""
                }
            } else if current != nil {
                current?.append(character)
            }
        }
        return values
    }

    /// 去掉 uin 前缀的 o 与前导 0
    static func normalizedUin(_ value: String) -> String {
        var result = value
        while result.hasPrefix("o") { result.removeFirst() }
        while result.hasPrefix("0") { result.removeFirst() }
        return result
    }

    // MARK: - 随机值 (与桌面端 loginPrimitives.ts 的 128 位 LCG 逐位对齐)

    private static let hexChars = Array("0123456789abcdef")
    private static let alphanumChars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    private static let randomMultiplier: UInt64 = 6364136223846793005
    private static let randomIncrement: UInt64 = 1442695040888963407
    private static let randomSeedMultiplier: UInt64 = 0x9e37_79b9
    private static let userAgentSeedMultiplier: UInt64 = 0x9e37_79b1

    /// 与桌面端 USER_AGENT_SEQUENCE 对应: UA 选择会自增该序号, 随机值只读取当前值作种子
    private static let sequenceLock = NSLock()
    private static var userAgentSequence: UInt64 = 0

    /// 128 位 LCG 状态, 拆成高低两个 64 位部分 (Swift 无 UInt128)
    private struct RandomState {
        var high: UInt64
        var low: UInt64
    }

    private static func currentSequence() -> UInt64 {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        return userAgentSequence
    }

    private static func advanceSequence() -> UInt64 {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        let sequence = userAgentSequence
        userAgentSequence &+= 1
        return sequence
    }

    /// state = (state * 乘数 + 增量) mod 2^128
    private static func nextRandomState(_ state: RandomState) -> RandomState {
        let product = state.low.multipliedFullWidth(by: randomMultiplier)
        let high = product.high &+ (state.high &* randomMultiplier)
        let (low, overflow) = product.low.addingReportingOverflow(randomIncrement)
        return RandomState(high: overflow ? high &+ 1 : high, low: low)
    }

    /// state = ((毫秒时间戳 ^ 序号) * 乘数) mod 2^128
    private static func initialRandomState(multiplier: UInt64) -> RandomState {
        let seed = UInt64(unixMillis()) ^ currentSequence()
        let product = seed.multipliedFullWidth(by: multiplier)
        return RandomState(high: product.high, low: product.low)
    }

    /// 随机十六进制串: 每次取 (state >> 32) 的低 4 位
    static func randomHex(length: Int) -> String {
        var state = initialRandomState(multiplier: randomSeedMultiplier)
        var result = ""
        result.reserveCapacity(length)
        for _ in 0..<length {
            state = nextRandomState(state)
            result.append(hexChars[Int((state.low >> 32) & 0xf)])
        }
        return result
    }

    /// 随机大小写字母加数字混合串: 每次取 (state >> 32) mod 62
    static func randomAlphanumeric(length: Int) -> String {
        var state = initialRandomState(multiplier: randomSeedMultiplier)
        var result = ""
        result.reserveCapacity(length)
        for _ in 0..<length {
            state = nextRandomState(state)
            // (state >> 32) mod len: 高位部分按 2^32 mod len 折回来
            let modulus = UInt64(alphanumChars.count)
            let lowPart = (state.low >> 32) % modulus
            let highPart = ((state.high % modulus) * ((1 << 32) % modulus)) % modulus
            result.append(alphanumChars[Int((lowPart + highPart) % modulus)])
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

    /// 选择移动端 UA: 序号自增, 种子由毫秒时间戳与序号混合, 且不与上一次重复
    static func selectMobileUserAgent(previous: String?) -> String {
        let sequence = advanceSequence()
        // 桌面端对 64 位取模, Swift 的 &* 本身就会回绕
        let seed = UInt64(unixMillis()) ^ (sequence &* userAgentSeedMultiplier)
        var index = Int(seed % UInt64(mobileUserAgents.count))
        if let previous, previous == mobileUserAgents[index] {
            index = (index + 1) % mobileUserAgents.count
        }
        return mobileUserAgents[index]
    }
}
