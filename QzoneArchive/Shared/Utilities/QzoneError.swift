//
//  QzoneError.swift
//  QzoneArchive
//
//  统一错误类型, 文案不暴露敏感响应内容
//

import Foundation

/// 登录与接口统一错误
enum QzoneError: LocalizedError {
    case notLoggedIn
    case sessionExpired
    case rateLimited(retryAt: Int)
    case permissionDenied
    case networkUnavailable
    case serverError(status: Int)
    case invalidResponse
    case unsupportedResponse
    case cancelled
    case insufficientStorage(required: Int64)
    case loginFailed(String)
    case parseFailed(String)
    case apiError(code: Int, message: String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "尚未登录 QQ 空间，请先完成登录"
        case .sessionExpired:
            return "登录状态已失效，需要重新登录后继续归档。已保存的内容不会丢失。"
        case .rateLimited(let retryAt):
            if retryAt > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(retryAt))
                let text = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
                return "请求频率受到限制，任务已自动暂停，将在 \(text) 后继续。你也可以稍后手动继续。"
            }
            return "请求频率受到限制，任务已自动暂停，将在等待后继续。你也可以稍后手动继续。"
        case .permissionDenied:
            return "QQ 空间拒绝了该请求（权限或风控）。请稍后重试，不要短时间高频请求。"
        case .networkUnavailable:
            return "网络连接失败，已保存当前进度。请检查网络后继续。"
        case .serverError(let status):
            return "QQ 服务暂时异常（HTTP \(status)），已保存当前进度，稍后会自动重试。"
        case .invalidResponse:
            return "接口返回了无法识别的内容，请稍后重试。"
        case .unsupportedResponse:
            return "该条内容格式暂不兼容，正文已保留，相关媒体或互动信息下载失败。"
        case .cancelled:
            return "任务已取消"
        case .insufficientStorage(let required):
            let text = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            return "iPhone 可用空间不足，已暂停媒体下载。请释放空间或关闭媒体下载后继续。（仍需要约 \(text)）"
        case .loginFailed(let message):
            return "登录失败：\(message)"
        case .parseFailed(let message):
            return "解析失败：\(message)"
        case .apiError(let code, let message):
            return "QQ 空间接口返回错误 \(code)：\(message)"
        case .unknown(let message):
            return message
        }
    }

    /// 是否属于登录态问题
    var isAuthError: Bool {
        switch self {
        case .notLoggedIn, .sessionExpired, .permissionDenied: return true
        default: return false
        }
    }

    /// 是否值得重试
    var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .serverError, .invalidResponse, .insufficientStorage: return true
        case .apiError(_, let message):
            let permanent = ["未登录", "登录失效", "权限", "封禁", "禁止访问", "p_skey"]
            return !permanent.contains { message.contains($0) }
        default: return false
        }
    }
}

extension QzoneError {
    /// 错误文案脱敏, 复用日志脱敏规则
    static func redact(_ text: String) -> String {
        AppLogger.redact(text)
    }
}
