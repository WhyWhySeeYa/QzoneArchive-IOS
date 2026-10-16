//
//  AppLogger.swift
//  QzoneArchive
//
//  日志: 自动脱敏, 不输出 Cookie, Token, 密码
//

import Foundation
import OSLog

/// 日志脱敏与持久化
final class AppLogger {
    private let subsystem = "com.minis.QzoneArchive"
    private let store: OSLogStore?
    private let fileManager = FileManager.default
    private let maxLogFiles = 5

    init() {
        store = nil
    }

    /// 记录一条普通日志
    func info(_ message: String, _ category: String = "app") {
        let sanitized = Self.redact(message)
        os_log("%{public}@", log: OSLog(subsystem: subsystem, category: category), type: .info, sanitized)
        appendLine("[\(category)] \(sanitized)")
    }

    /// 记录一条错误日志
    func error(_ message: String, _ category: String = "app") {
        let sanitized = Self.redact(message)
        os_log("%{public}@", log: OSLog(subsystem: subsystem, category: category), type: .error, sanitized)
        appendLine("[\(category)] ERROR \(sanitized)")
    }

    /// 导出脱敏后的日志文本
    func exportLogs() -> String {
        let url = logFileURL()
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return Self.redact(text)
    }

    /// 清空日志文件
    func clearLogs() {
        try? fileManager.removeItem(at: logFileURL())
    }

    // MARK: - 内部实现

    private func logFileURL() -> URL {
        FileStorageService().logsDirectory.appendingPathComponent("qzonearchive.log")
    }

    private func appendLine(_ line: String) {
        let url = logFileURL()
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp) \(line)\n"
        guard let data = entry.data(using: .utf8) else { return }
        if fileManager.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url)
        }
    }

    /// 脱敏: Cookie 头, Token, 长随机串
    static func redact(_ text: String) -> String {
        var result = text
        // Cookie: name=value; ...
        result = result.replacingOccurrences(
            of: #"(?i)cookie\s*[:=]\s*[^;,\n]+"#,
            with: "Cookie: [已隐藏]",
            options: .regularExpression
        )
        // skey / p_skey / token 一类键值
        let keys = ["p_skey", "skey", "pt4_token", "g_tk", "bkn", "uin", "ptqr_token", "qrsig", "pt_login_sig"]
        for key in keys {
            result = result.replacingOccurrences(
                of: "(?i)\\b\(key)\\s*[:=]\\s*[^;,\\s\\n]+",
                with: "\(key)=[已隐藏]",
                options: .regularExpression
            )
        }
        // 超长十六进制或 base64 串
        result = result.replacingOccurrences(
            of: #"\b[A-Za-z0-9+/_-]{32,}={0,2}\b"#,
            with: "[已隐藏]",
            options: .regularExpression
        )
        return result
    }
}
