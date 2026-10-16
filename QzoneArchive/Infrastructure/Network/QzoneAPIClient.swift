//
//  QzoneAPIClient.swift
//  QzoneArchive
//
//  QQ 空间接口客户端: 互动列表拉取, 重试与退避
//

import Foundation

/// 互动列表刷新类型
enum FeedRefreshType: Int {
    case firstPage = 1
    case normal = 2
}

/// 一页互动数据
struct QzoneFeedPage {
    var feeds: [[String: Any]]
    var attachInfo: String?
    var hasMore: Bool
}

/// 接口凭证
struct QzoneFeedCredentials {
    var gTk: Int
    var cookies: [String: String]
    var userAgent: String
    var cookieHeader: String { QzoneLoginPrimitives.cookieHeader(cookies) }
}

/// 空间接口客户端, 对应桌面端 core/qzoneClient.ts
actor QzoneAPIClient {
    /// 互动列表接口地址
    let feedsURL = "https://mobile.qzone.qq.com/get_feeds"

    private let session: LoginSession
    private let logger: AppLogger
    private let urlSession: URLSession

    init(session: LoginSession, logger: AppLogger) {
        self.session = session
        self.logger = logger
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpMaximumConnectionsPerHost = 1
        urlSession = URLSession(configuration: config)
    }

    /// 当前凭证
    func credentials() async throws -> QzoneAuth {
        guard let auth = await session.currentCredentials() else { throw QzoneError.notLoggedIn }
        return auth
    }

    /// 拉取一页互动数据
    func fetchFeeds(
        refreshType: FeedRefreshType,
        attachInfo: String?,
        attempts: Int = 6
    ) async throws -> QzoneFeedPage {
        let auth = try await credentials()
        let feedCredentials = QzoneFeedCredentials(
            gTk: auth.gTk,
            cookies: auth.cookies,
            userAgent: auth.userAgent
        )
        var lastReason = ""
        for attempt in 1...max(1, attempts) {
            do {
                let (data, response) = try await performFeedRequest(
                    refreshType: refreshType,
                    attachInfo: attachInfo,
                    feedCredentials: feedCredentials
                )
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = Self.decodeText(data)
                if let reason = Self.retryableResponseReason(status: status, body: body) {
                    lastReason = reason
                    if attempt < attempts {
                        logger.info("接口可重试: \(reason)")
                        try await Task.sleep(nanoseconds: UInt64(Self.feedRetryDelayMs(attempt: attempt)) * 1_000_000)
                        continue
                    }
                    throw QzoneError.apiError(code: 0, message: "第 \(attempt) 次请求仍失败：\(reason)")
                }
                return try Self.parseFeedPage(body: body)
            } catch let error as QzoneError {
                if error.isRetryable, attempt < attempts {
                    lastReason = error.localizedDescription
                    try await Task.sleep(nanoseconds: UInt64(Self.feedRetryDelayMs(attempt: attempt)) * 1_000_000)
                    continue
                }
                throw error
            } catch {
                lastReason = "请求超时（第 \(attempt)/\(attempts) 次）"
                if attempt < attempts {
                    try await Task.sleep(nanoseconds: UInt64(Self.feedRetryDelayMs(attempt: attempt)) * 1_000_000)
                    continue
                }
                throw QzoneError.networkUnavailable
            }
        }
        throw QzoneError.networkUnavailable
    }

    /// 只请求一次, 供引擎判定单页错误
    func fetchFeedsOnce(refreshType: FeedRefreshType, attachInfo: String?) async throws -> QzoneFeedPage {
        let auth = try await credentials()
        let feedCredentials = QzoneFeedCredentials(
            gTk: auth.gTk,
            cookies: auth.cookies,
            userAgent: auth.userAgent
        )
        let (data, response) = try await performFeedRequest(
            refreshType: refreshType,
            attachInfo: attachInfo,
            feedCredentials: feedCredentials
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = Self.decodeText(data)
        if let reason = Self.retryableResponseReason(status: status, body: body) {
            throw QzoneError.apiError(code: 0, message: reason)
        }
        return try Self.parseFeedPage(body: body)
    }

    // MARK: - 请求

    private func performFeedRequest(
        refreshType: FeedRefreshType,
        attachInfo: String?,
        feedCredentials: QzoneFeedCredentials
    ) async throws -> (Data, URLResponse) {
        var components = URLComponents(string: feedsURL)!
        var queryItems = [
            URLQueryItem(name: "g_tk", value: String(feedCredentials.gTk)),
            URLQueryItem(name: "res_type", value: "1"),
            URLQueryItem(name: "refresh_type", value: String(refreshType.rawValue)),
            URLQueryItem(name: "format", value: "json"),
        ]
        if let attachInfo, !attachInfo.trimmingCharacters(in: .whitespaces).isEmpty {
            queryItems.append(URLQueryItem(name: "res_attach", value: attachInfo))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw QzoneError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let headers = feedHeaders(feedCredentials: feedCredentials)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await urlSession.data(for: request)
    }

    /// 组装请求头, 逐项与原基准一致
    private func feedHeaders(feedCredentials: QzoneFeedCredentials) -> [String: String] {
        var headers: [String: String] = [
            "Accept": "application/json",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
            "Origin": "https://mobile.qzone.qq.com",
            "Referer": "https://mobile.qzone.qq.com/",
            "User-Agent": feedCredentials.userAgent,
            "Cookie": feedCredentials.cookieHeader,
            "Sec-Fetch-Dest": "empty",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Site": "same-site",
            "Sec-Ch-Ua": Self.secChUa(feedCredentials.userAgent),
            "Sec-Ch-Ua-Mobile": "?1",
            "Sec-Ch-Ua-Platform": Self.secPlatform(feedCredentials.userAgent),
        ]
        return headers
    }

    // MARK: - 静态纯函数

    /// 判断响应是否值得重试
    static func retryableResponseReason(status: Int, body: String) -> String? {
        if status == 429 || (status >= 500 && status <= 599) {
            return "HTTP \(status)"
        }
        if status < 200 || status > 299 { return nil }
        guard let data = body.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data)
        else { return "响应不是有效 JSON" }
        guard let object = value as? [String: Any] else { return "响应中暂时缺少 data" }
        if let code = numericInteger(object["code"]), code != 0 {
            let message = responseMessage(object)
            let permanent = ["未登录", "登录失效", "权限", "封禁", "禁止访问", "p_skey"]
            if permanent.contains(where: { message.contains($0) }) { return nil }
            return "接口错误 \(code)：\(message)"
        }
        if object["data"] == nil { return "响应中暂时缺少 data" }
        return nil
    }

    /// 第 n 次重试前的退避毫秒数
    static func feedRetryDelayMs(attempt: Int) -> Int {
        1500 * Int(pow(2.0, Double(max(1, attempt) - 1)))
    }

    /// 按 UA 推断 sec-ch-ua 头
    static func secChUa(_ userAgent: String) -> String {
        guard let range = userAgent.range(of: "Chrome/") else {
            return "\"Not;A=Brand\";v=\"8\", \"Apple\";v=\"0\", \"Safari\";v=\"18\""
        }
        let suffix = String(userAgent[range.upperBound...])
        let major = String(suffix.prefix(while: { $0.isNumber }))
        let version = major.isEmpty ? "131" : major
        return "\"Not;A=Brand\";v=\"8\", \"Chromium\";v=\"\(version)\", \"Microsoft Edge\";v=\"\(version)\""
    }

    /// 按 UA 推断 sec-ch-ua-platform
    static func secPlatform(_ userAgent: String) -> String {
        userAgent.contains("iPhone") ? "\"iOS\"" : "\"Android\""
    }

    /// 正文解码: 优先 UTF-8, 失败时按 GB18030
    static func decodeText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: encoding)) ?? ""
    }

    /// 取整数字段
    static func numericInteger(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber {
            let doubleValue = number.doubleValue
            if doubleValue == doubleValue.rounded() { return number.intValue }
        }
        if let string = value as? String, let number = Int(string) { return number }
        return nil
    }

    /// 取错误描述
    static func responseMessage(_ object: [String: Any]) -> String {
        let keys = ["message", "msg", "error", "detail", "desc"]
        for key in keys {
            if let string = object[key] as? String, !string.isEmpty { return string }
            if let number = object[key] as? NSNumber { return number.stringValue }
        }
        return "未知错误"
    }

    /// 解析互动响应
    static func parseFeedPage(body: String) throws -> QzoneFeedPage {
        guard let data = body.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any]
        else { throw QzoneError.invalidResponse }
        if let code = numericInteger(object["code"]), code != 0 {
            throw QzoneError.apiError(code: code, message: responseMessage(object))
        }
        guard let dataValue = object["data"] else { throw QzoneError.invalidResponse }
        let feeds = readFeedRecords(dataValue)
        let attachInfo = readAttachInfo(dataValue)
        let hasMore = readHasMore(dataValue) && !feeds.isEmpty && attachInfo != nil
        return QzoneFeedPage(feeds: feeds, attachInfo: attachInfo, hasMore: hasMore)
    }

    /// 读取动态数组
    static func readFeedRecords(_ data: Any) -> [[String: Any]] {
        if let array = data as? [[String: Any]] { return array }
        if let object = data as? [String: Any] {
            let keys = ["feeds", "list", "data", "items", "msg_list", "feed_list"]
            for key in keys {
                if let array = object[key] as? [[String: Any]] { return array }
            }
            for value in object.values {
                if let array = value as? [[String: Any]] { return array }
            }
        }
        return []
    }

    /// 读取分页游标
    static func readAttachInfo(_ data: Any) -> String? {
        guard let object = data as? [String: Any] else { return nil }
        let keys = ["attach_info", "attachInfo", "attach", "next_attach"]
        for key in keys {
            if let string = object[key] as? String, !string.isEmpty { return string }
            if let nested = object[key] as? [String: Any], let string = nested["attach_info"] as? String, !string.isEmpty {
                return string
            }
        }
        return nil
    }

    /// 读取是否还有更多
    static func readHasMore(_ data: Any) -> Bool {
        guard let object = data as? [String: Any] else { return false }
        let keys = ["has_more", "hasMore", "hasmore"]
        for key in keys {
            if let number = object[key] as? NSNumber { return number.boolValue }
            if let string = object[key] as? String { return string == "1" || string.lowercased() == "true" }
        }
        return false
    }
}
