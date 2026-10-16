//
//  LoginSession.swift
//  QzoneArchive
//
//  登录会话: 二维码登录状态机 + 凭证持久化
//

import Foundation

/// 二维码登录状态
enum LoginStatusKind: Equatable {
    case waiting
    case scanned
    case expired
    case success
    case error
    case loggedOut
}

struct LoginStatus: Equatable {
    var status: LoginStatusKind
    var message: String
}

/// 登录会话状态机, 对应桌面端 core/login.ts
actor LoginSession {
    /// 登录接口地址
    private let xloginURL = "https://xui.ptlogin2.qq.com/cgi-bin/xlogin"
    private let ptqrshowURL = "https://ssl.ptlogin2.qq.com/ptqrshow"
    private let ptqrloginURL = "https://ssl.ptlogin2.qq.com/ptqrlogin"
    private let checkSigURL = "https://ptlogin2.qzone.qq.com/check_sig"
    private let sURL = "https://h5.qzone.qq.com/mqzone/index"

    /// 当前会话内存态, 不落盘
    private var session: QzoneLoginSession?
    /// 最近一次使用的 UA
    private var lastUserAgent: String?

    private let credentials: CredentialStore
    private let logger: AppLogger
    private let urlSession: URLSession
    /// 登录接口专用 cookie storage, 收集 Set-Cookie 供手工读取
    private let loginCookieStorage = HTTPCookieStorage()

    init(credentials: CredentialStore, logger: AppLogger) {
        self.credentials = credentials
        self.logger = logger
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = loginCookieStorage
        config.httpMaximumConnectionsPerHost = 1
        urlSession = URLSession(configuration: config)
    }

    // MARK: - 会话状态

    /// 是否已登录
    func isLoggedIn() async -> Bool {
        if session != nil { return true }
        return await credentials.hasCredentials()
    }

    /// 当前账号
    func currentAccount() async -> Account? {
        await credentials.loadAccount()
    }

    /// 保存账号
    func saveAccount(_ account: Account) async throws {
        try await credentials.saveAccount(account)
    }

    /// 退出登录: 清空本地凭证与内存会话
    func logout() async {
        try? await credentials.clear()
        self.session = nil
    }

    /// 本地保存的账号列表
    func listAccounts() async -> [Account] {
        guard let account = await credentials.loadAccount() else { return [] }
        return [account]
    }

    /// 当前凭证, 未登录返回 nil
    func currentCredentials() async -> QzoneAuth? {
        if let session {
            return QzoneAuth(
                uin: session.uin ?? "",
                gTk: session.gTk ?? 0,
                cookies: session.cookies,
                userAgent: session.userAgent
            )
        }
        return await credentials.loadCredentials().map {
            QzoneAuth(uin: $0.uin, gTk: $0.gTk, cookies: $0.cookies, userAgent: $0.userAgent)
        }
    }

    // MARK: - 二维码登录

    /// 开始二维码登录: 取 pt_login_sig, 再取二维码图片与 qrsig
    func startQRLogin() async throws -> Data {
        let userAgent = QzoneLoginPrimitives.selectMobileUserAgent(previous: lastUserAgent)
        lastUserAgent = userAgent

        let (_, sigCookies) = try await requestText(
            xloginQuery(),
            headers: ["User-Agent": userAgent],
            failurePrefix: "xlogin 请求失败: "
        )
        guard let loginSig = sigCookies["pt_login_sig"] else {
            throw QzoneError.loginFailed("xlogin 响应中缺少 pt_login_sig cookie")
        }
        var cookies = sigCookies
        cookies.removeValue(forKey: "pt_login_sig")

        let (qrData, qrCookies) = try await requestBytes(
            ptqrshowQuery(),
            headers: ["User-Agent": userAgent, "Cookie": QzoneLoginPrimitives.cookieHeader(cookies)],
            failurePrefix: "获取登录二维码失败："
        )
        guard let qrsig = qrCookies["qrsig"] else {
            throw QzoneError.loginFailed("二维码响应中缺少 qrsig")
        }
        mergeCookies(qrCookies, into: &cookies)
        applyQRFingerprintCookies(&cookies)
        session = QzoneLoginSession(
            ptqrToken: QzoneLoginPrimitives.ptqrToken(qrsig),
            cookies: cookies,
            uin: nil,
            gTk: nil,
            userAgent: userAgent,
            loginSig: loginSig
        )
        return qrData
    }

    /// 轮询扫码状态
    func pollQRLogin() async throws -> LoginStatus {
        guard let stored = session else { throw QzoneError.loginFailed("请先获取登录二维码") }
        let (text, setCookie) = try await requestText(
            ptqrloginQuery(stored),
            headers: ["User-Agent": stored.userAgent, "Cookie": QzoneLoginPrimitives.cookieHeader(stored.cookies)],
            failurePrefix: "检查扫码状态失败："
        )
        var current = stored
        mergeCookies(setCookie, into: &current.cookies)

        if text.contains("'66'") || text.contains("二维码未失效") {
            session = current
            return LoginStatus(status: .waiting, message: "请使用手机 QQ 扫描二维码")
        }
        if text.contains("'67'") || text.contains("二维码认证中") {
            session = current
            return LoginStatus(status: .scanned, message: "已扫码，请在手机上确认登录")
        }
        if text.contains("'65'") || text.contains("二维码已失效") {
            session = current
            return LoginStatus(status: .expired, message: "二维码已失效，请刷新后重试")
        }
        if !text.contains("'0'") && !text.contains("登录成功") {
            session = current
            return LoginStatus(status: .error, message: "QQ 登录返回了无法识别的状态")
        }

        guard let callbackUin = QzoneLoginPrimitives.callbackQueryValue(text, name: "uin") else {
            throw QzoneError.loginFailed("登录成功响应中缺少 uin")
        }
        let loginURLString = QzoneLoginPrimitives.pollLoginURL(text) ?? fallbackCheckSigURL(text: text)
        let (_, confirmCookies) = try await requestText(
            URL(string: loginURLString) ?? URL(string: sURL)!,
            headers: ["User-Agent": current.userAgent, "Cookie": QzoneLoginPrimitives.cookieHeader(current.cookies)],
            failurePrefix: "确认 QQ 登录失败："
        )
        mergeCookies(confirmCookies, into: &current.cookies)

        guard let pSkey = current.cookies["p_skey"], !pSkey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw QzoneError.loginFailed("登录 Cookie 中缺少有效的 p_skey")
        }
        let uin = QzoneLoginPrimitives.normalizedUin(callbackUin)
        let userAgent = QzoneLoginPrimitives.accountUserAgent(uin: uin)
        current.uin = uin
        current.gTk = Int(QzoneLoginPrimitives.bkn(pSkey))
        current.userAgent = userAgent
        await warmupQzoneSession(cookies: &current.cookies, userAgent: userAgent, uin: uin)
        session = current

        let credentialCookies = QzoneLoginPrimitives.loginCredentials(from: current.cookies, uin: uin)
        guard !credentialCookies.isEmpty else { throw QzoneError.loginFailed("登录凭证不完整") }
        let credentialRecord = QzoneStoredCredentials(
            uin: uin,
            gTk: Int(QzoneLoginPrimitives.bkn(pSkey)),
            cookies: credentialCookies,
            userAgent: userAgent,
            savedAt: Date()
        )
        try await credentials.saveCredentials(credentialRecord)
        try await credentials.saveAccount(Account(qqUin: uin, nickname: nil, lastLoginAt: Date(), createdAt: Date(), updatedAt: Date()))
        logger.info("二维码登录成功 \(uin)")
        return LoginStatus(status: .success, message: "登录成功")
    }

    // MARK: - 内部实现

    private func fallbackCheckSigURL(text: String) -> String {
        let ptsigx = QzoneLoginPrimitives.callbackQueryValue(text, name: "ptsigx") ?? ""
        let uin = QzoneLoginPrimitives.callbackQueryValue(text, name: "uin") ?? ""
        return "\(checkSigURL)?pttype=1&uin=\(uin)&service=ptqrlogin&nodirect=0&ptsigx=\(ptsigx)&s_url=\(sURL)&f_url=&ptlang=2052&ptredirect=100&aid=\(QzoneLoginPrimitives.appID)&daid=\(QzoneLoginPrimitives.daID)"
    }

    private func xloginQuery() throws -> URL {
        var components = URLComponents(string: xloginURL)!
        components.queryItems = [
            URLQueryItem(name: "target", value: "self"),
            URLQueryItem(name: "s_url", value: sURL),
            URLQueryItem(name: "proxy_url", value: ""),
            URLQueryItem(name: "pt_no_auth", value: "1"),
        ]
        return components.url!
    }

    private func ptqrshowQuery() throws -> URL {
        var components = URLComponents(string: ptqrshowURL)!
        components.queryItems = [
            URLQueryItem(name: "appid", value: QzoneLoginPrimitives.appID),
            URLQueryItem(name: "e", value: "2"),
            URLQueryItem(name: "l", value: "M"),
            URLQueryItem(name: "s", value: "3"),
            URLQueryItem(name: "d", value: "72"),
            URLQueryItem(name: "v", value: "4"),
            URLQueryItem(name: "t", value: String(QzoneLoginPrimitives.unixMillis())),
            URLQueryItem(name: "daid", value: QzoneLoginPrimitives.daID),
            URLQueryItem(name: "pt_3rd_aid", value: "0"),
            URLQueryItem(name: "u1", value: sURL),
        ]
        return components.url!
    }

    private func ptqrloginQuery(_ current: QzoneLoginSession) throws -> URL {
        var components = URLComponents(string: ptqrloginURL)!
        components.queryItems = [
            URLQueryItem(name: "u1", value: sURL),
            URLQueryItem(name: "ptqrtoken", value: String(current.ptqrToken)),
            URLQueryItem(name: "ptredirect", value: "0"),
            URLQueryItem(name: "h", value: "1"),
            URLQueryItem(name: "t", value: "1"),
            URLQueryItem(name: "g", value: "1"),
            URLQueryItem(name: "from_ui", value: "1"),
            URLQueryItem(name: "ptlang", value: "2052"),
            URLQueryItem(name: "action", value: "0-0-\(QzoneLoginPrimitives.unixMillis())"),
            URLQueryItem(name: "js_ver", value: "20032614"),
            URLQueryItem(name: "js_type", value: "1"),
            URLQueryItem(name: "login_sig", value: current.loginSig),
            URLQueryItem(name: "pt_uistyle", value: "40"),
            URLQueryItem(name: "has_onekey", value: "1"),
            URLQueryItem(name: "o1vId", value: ""),
            URLQueryItem(name: "aid", value: QzoneLoginPrimitives.appID),
            URLQueryItem(name: "daid", value: QzoneLoginPrimitives.daID),
        ]
        return components.url!
    }

    /// 文本请求, 返回正文与本次请求收集到的 Cookie
    private func requestText(
        _ url: URL,
        headers: [String: String],
        failurePrefix: String
    ) async throws -> (String, [String: String]) {
        let (data, response) = try await performRequest(url, headers: headers)
        guard let http = response as? HTTPURLResponse else { throw QzoneError.invalidResponse }
        return (Self.decodeText(data), cookiesForRequest(url: url))
    }

    /// 二进制请求, 返回数据与本次请求收集到的 Cookie
    private func requestBytes(
        _ url: URL,
        headers: [String: String],
        failurePrefix: String
    ) async throws -> (Data, [String: String]) {
        let (data, response) = try await performRequest(url, headers: headers)
        guard let http = response as? HTTPURLResponse else { throw QzoneError.invalidResponse }
        return (data, cookiesForRequest(url: url))
    }

    private func performRequest(_ url: URL, headers: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        do {
            return try await urlSession.data(for: request)
        } catch {
            throw QzoneError.networkUnavailable
        }
    }

    /// 从 cookie storage 中读取该域下的 Cookie
    private func cookiesForRequest(url: URL) -> [String: String] {
        var result: [String: String] = [:]
        for cookie in loginCookieStorage.cookies(for: url) ?? [] {
            result[cookie.name] = cookie.value
        }
        return result
    }

    /// 合并 Cookie, 空值不覆盖已有有效值
    private func mergeCookies(_ setCookie: [String: String], into cookies: inout [String: String]) {
        for (name, value) in setCookie {
            if !value.trimmingCharacters(in: .whitespaces).isEmpty {
                cookies[name] = value
            }
        }
    }

    /// 补齐移动端指纹 Cookie
    private func applyQRFingerprintCookies(_ cookies: inout [String: String]) {
        cookies["_qimei_fingerprint"] = QzoneLoginPrimitives.randomHex(length: 32)
        cookies["_qimei_uuid42"] = QzoneLoginPrimitives.randomHex(length: 42)
        cookies["_qimei_i_3"] = QzoneLoginPrimitives.randomHex(length: 87)
        cookies["_qimei_h38"] = "\(QzoneLoginPrimitives.randomHex(length: 25))0\(QzoneLoginPrimitives.randomHex(length: 12))"
        cookies["_qimei_i_1"] = QzoneLoginPrimitives.randomHex(length: 97)
        cookies["_qpsvr_localtk"] = String(format: "%.16f", Double(QzoneLoginPrimitives.unixMillis()) / 1e18)
        if cookies["RK"] == nil { cookies["RK"] = QzoneLoginPrimitives.randomAlphanumeric(length: 10) }
        if cookies["ptcz"] == nil { cookies["ptcz"] = QzoneLoginPrimitives.randomHex(length: 64) }
        let timestamp = QzoneLoginPrimitives.unixMillis()
        if cookies["pgv_pvid"] == nil { cookies["pgv_pvid"] = String((timestamp % 9_000_000_000) + 1_000_000_000) }
        if cookies["pgv_info"] == nil { cookies["pgv_info"] = "ssid=s\(timestamp)" }
        if cookies["QZ_FE_WEBP_SUPPORT"] == nil { cookies["QZ_FE_WEBP_SUPPORT"] = "1" }
        if cookies["cpu_performance_v8"] == nil { cookies["cpu_performance_v8"] = "0" }
        if cookies["__Q_w_s_hat_seed"] == nil { cookies["__Q_w_s_hat_seed"] = "1" }
        if cookies["domainid"] == nil { cookies["domainid"] = "5" }
        if cookies["fqm_pvqid"] == nil { cookies["fqm_pvqid"] = QzoneLoginPrimitives.randomUUIDLike() }
        if cookies["fqm_sessionid"] == nil { cookies["fqm_sessionid"] = QzoneLoginPrimitives.randomUUIDLike() }
    }

    /// 登录后预热空间会话
    private func warmupQzoneSession(cookies: inout [String: String], userAgent: String, uin: String) async {
        if let url = URL(string: sURL) {
            do {
                let (_, response) = try await performRequest(
                    url,
                    headers: ["User-Agent": userAgent, "Cookie": QzoneLoginPrimitives.cookieHeader(cookies)]
                )
                if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                    mergeCookies(cookiesForRequest(url: url), into: &cookies)
                }
            } catch {
                // 预热失败不影响登录
            }
        }
        if cookies["ptui_loginuin"] == nil { cookies["ptui_loginuin"] = uin }
        if cookies["QZ_FE_WEBP_SUPPORT"] == nil { cookies["QZ_FE_WEBP_SUPPORT"] = "1" }
        if cookies["cpu_performance_v8"] == nil { cookies["cpu_performance_v8"] = "0" }
        if cookies["__Q_w_s_hat_seed"] == nil { cookies["__Q_w_s_hat_seed"] = "1" }
        if cookies["domainid"] == nil { cookies["domainid"] = "5" }
    }

    /// 正文解码: 优先 UTF-8, 失败时按 GB18030
    nonisolated static func decodeText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: encoding)) ?? ""
    }
}

/// 内存中的登录会话
struct QzoneLoginSession {
    var ptqrToken: UInt32
    var cookies: [String: String]
    var uin: String?
    var gTk: Int?
    var userAgent: String
    var loginSig: String
}

/// 归档模块使用的凭证视图
struct QzoneAuth {
    var uin: String
    var gTk: Int
    var cookies: [String: String]
    var userAgent: String

    var cookieHeader: String { QzoneLoginPrimitives.cookieHeader(cookies) }
}
