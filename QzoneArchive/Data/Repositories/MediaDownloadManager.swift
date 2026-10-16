//
//  MediaDownloadManager.swift
//  QzoneArchive
//
//  媒体下载: 图片并发闸门, 占位图识别, 视频缓存
//
//  行为对齐桌面端 core/archiveMedia.ts
//

import Foundation
import CoreGraphics
import ImageIO
import UIKit

/// 媒体下载管理器
actor MediaDownloadManager {
    /// 图片下载并发上限
    static let imageConcurrency = 4
    /// 图片缓存上限, 单位字节
    static let imageMaxBytes = 50 * 1024 * 1024
    /// 图片与视频下载的超时
    static let imageTimeout: TimeInterval = 90
    static let videoTimeout: TimeInterval = 180
    /// 图片扩展名顺序
    static let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "webp"]
    /// 有效图片的最小字节数
    static let minImageBytes = 33
    /// 有效视频的最小字节数
    static let minVideoBytes = 1024
    /// 请求头候选组合
    static let requestVariants: [(withCookie: Bool, withReferer: Bool)] = [
        (true, true), (true, false), (false, true), (false, false),
    ]
    /// QQ 图片不存在占位图的像素尺寸
    static let missingImageSize = (width: 26, height: 26)

    private let storage: FileStorageService
    private let logger: AppLogger
    private let session: URLSession
    private var activeDownloads = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// 最近一次登录的 Cookie 头, 供媒体请求复用
    private var cookieHeader: String?
    private var userAgent: String?

    init(storage: FileStorageService, logger: AppLogger) {
        self.storage = storage
        self.logger = logger
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.imageTimeout
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpMaximumConnectionsPerHost = Self.imageConcurrency
        session = URLSession(configuration: config)
    }

    /// 由登录会话注入凭证, 只保留在内存中
    func updateCredentials(cookieHeader: String, userAgent: String) {
        self.cookieHeader = cookieHeader
        self.userAgent = userAgent
    }

    func clearCredentials() {
        cookieHeader = nil
        userAgent = nil
    }

    // MARK: - 批量下载

    /// 下载一组动态的媒体, 返回成功下载的数量
    func downloadMedia(
        for posts: [ArchivePost],
        account: Account,
        settings: ArchiveSettings
    ) async throws -> Int {
        var downloaded = 0
        let imageDir = storage.imageDirectory(uin: account.qqUin)
        for post in posts {
            if settings.downloadImages {
                for (index, url) in post.pictureURLs.enumerated() {
                    if Task.isCancelled { return downloaded }
                    if existingArchivedImage(directory: imageDir, fileStem: "\(post.id)-\(index)") != nil { continue }
                    do {
                        if try await loadArchivedImage(
                            url: url,
                            imageDir: imageDir,
                            fileStem: "\(post.id)-\(index)"
                        ) != nil { downloaded += 1 }
                    } catch {
                        logger.error("图片下载失败: \(QzoneError.redact(error.localizedDescription))", "media")
                    }
                }
            }
            if settings.downloadVideos, let videoURL = post.videoURLs.first {
                if Task.isCancelled { return downloaded }
                do {
                    if try await loadArchivedVideo(
                        url: videoURL,
                        ownerUin: account.qqUin,
                        postID: post.id
                    ) != nil { downloaded += 1 }
                } catch {
                    logger.error("视频下载失败: \(QzoneError.redact(error.localizedDescription))", "media")
                }
            }
        }
        return downloaded
    }

    // MARK: - 图片

    /// 检查本地是否已有该图片
    func existingArchivedImage(directory: URL, fileStem: String) -> URL? {
        for extensionName in Self.imageExtensions {
            let url = directory.appendingPathComponent("\(fileStem).\(extensionName)")
            guard let size = fileSize(url), size > Self.minImageBytes else { continue }
            if extensionName == "gif", gifIsMissingPlaceholder(url) {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            return url
        }
        return nil
    }

    /// 下载单张图片, 返回本地路径
    func loadArchivedImage(url: String, imageDir: URL, fileStem: String) async throws -> URL? {
        if let existing = existingArchivedImage(directory: imageDir, fileStem: fileStem) { return existing }
        guard let remoteURL = URL(string: url) else { throw QzoneError.unknown("图片地址无效") }

        await acquireSlot()
        defer { Task { await releaseSlot() } }
        if let rechecked = existingArchivedImage(directory: imageDir, fileStem: fileStem) { return rechecked }

        var lastError = ""
        for variant in Self.requestVariants {
            do {
                var request = URLRequest(url: remoteURL)
                request.timeoutInterval = Self.imageTimeout
                applyMediaHeaders(
                    &request,
                    accept: "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
                    withCookie: variant.withCookie,
                    withReferer: variant.withReferer
                )
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status != 200 {
                    lastError = "HTTP \(status)"
                    continue
                }
                if data.count > Self.imageMaxBytes {
                    lastError = "图片超过 50 MB 安全限制"
                    continue
                }
                guard let extensionName = archivedImageExtension(data) else {
                    lastError = "QQ 返回了非图片内容"
                    continue
                }
                if isQQMissingImagePlaceholder(data) {
                    lastError = "QQ 返回了图片不存在占位图"
                    continue
                }
                let target = imageDir.appendingPathComponent("\(fileStem).\(extensionName)")
                try storage.atomicWrite(data, to: target)
                return target
            } catch {
                lastError = "请求图片失败：\(error.localizedDescription)"
                continue
            }
        }
        throw QzoneError.unknown("所有 QQ 图片地址均加载失败：\(lastError)")
    }

    // MARK: - 视频

    /// 下载单个视频, 返回本地路径
    func loadArchivedVideo(url: String, ownerUin: String, postID: Int) async throws -> URL? {
        let videoDir = storage.videoDirectory()
        let cachePath = videoDir.appendingPathComponent("\(ownerUin)-\(postID).mp4")
        if let size = fileSize(cachePath), size > Self.minVideoBytes { return cachePath }
        guard let remoteURL = URL(string: url) else { throw QzoneError.unknown("视频地址无效") }

        var lastError = ""
        var rejected = false
        for variant in Self.requestVariants {
            do {
                var request = URLRequest(url: remoteURL)
                request.timeoutInterval = Self.videoTimeout
                applyMediaHeaders(
                    &request,
                    accept: "video/mp4,video/*,*/*;q=0.8",
                    withCookie: variant.withCookie,
                    withReferer: variant.withReferer
                )
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                if status != 200 {
                    if status == 403 { rejected = true }
                    lastError = "HTTP \(status)"
                    continue
                }
                if contentType.hasPrefix("video/") || contentType.contains("octet-stream") || videoBytesLookLikeMp4(data) {
                    try storage.atomicWrite(data, to: cachePath)
                    return cachePath
                }
                lastError = "QQ 返回了非视频内容（\(contentType.isEmpty ? "未知类型" : contentType)）"
            } catch {
                lastError = "请求视频失败：\(error.localizedDescription)"
                continue
            }
        }
        if rejected {
            throw QzoneError.unknown("QQ 拒绝了视频请求（HTTP 403），该归档的视频临时签名可能已经过期，请重新归档以更新视频地址")
        }
        throw QzoneError.unknown("所有视频地址均加载失败：\(lastError)")
    }

    // MARK: - 请求头与闸门

    private func applyMediaHeaders(
        _ request: inout URLRequest,
        accept: String,
        withCookie: Bool,
        withReferer: Bool
    ) {
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if withCookie, let cookieHeader { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        if withReferer {
            request.setValue("https://mobile.qzone.qq.com/", forHTTPHeaderField: "Referer")
        }
    }

    private func acquireSlot() async {
        if activeDownloads < Self.imageConcurrency {
            activeDownloads += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        activeDownloads += 1
    }

    private func releaseSlot() {
        activeDownloads -= 1
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    // MARK: - 图片识别

    /// 按文件头判断扩展名
    func archivedImageExtension(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count >= 4 else { return nil }
        if bytes[0] == 0xFF, bytes[1] == 0xD8 { return "jpg" }
        if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return "png" }
        if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { return "gif" }
        if bytes[0] == 0x42, bytes[1] == 0x4D { return "bmp" }
        if bytes.count >= 12,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 { return "webp" }
        return nil
    }

    /// 判断是否为 QQ 的图片不存在占位图
    ///
    /// 占位图是 26×26 的 JPEG, 通过 ImageIO 解码后按尺寸判定
    func isQQMissingImagePlaceholder(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return false
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int
            ?? properties[kCGImagePropertyPixelWidth] as? NSNumber as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
            ?? properties[kCGImagePropertyPixelHeight] as? NSNumber as? Int
        if let width, let height {
            return width == Self.missingImageSize.width && height == Self.missingImageSize.height
        }
        return false
    }

    /// 判断 GIF 是否为占位图
    func gifIsMissingPlaceholder(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return isQQMissingImagePlaceholder(data)
    }

    /// mp4 判定
    func videoBytesLookLikeMp4(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 12 else { return false }
        var offset = 4
        while offset + 4 <= 12 {
            if bytes[offset] == 0x66, bytes[offset + 1] == 0x74, bytes[offset + 2] == 0x79, bytes[offset + 3] == 0x70 {
                return true
            }
            offset += 1
        }
        return false
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64
        else { return nil }
        return size
    }
}
