//
//  ArchiveEngine.swift
//  QzoneArchive
//
//  归档引擎: 拉取, 分页, 断点续传, 频率保护, 异常跳过与找回
//
//  行为对齐桌面端 core/archiveEngine.ts 与归档设计细节常量
//

import Foundation

/// 归档进度
struct ArchiveProgress {
    var status: ArchiveTask.Status
    var pages: Int = 0
    var fetched: Int = 0
    var saved: Int = 0
    var skipped: Int = 0
    var failed: Int = 0
    var downloaded: Int = 0
    var message: String = "尚未开始归档"
    var retryAt: Date?
    var started: Date?
    var batchRetry: BatchRetryProgress?

    struct BatchRetryProgress {
        var current: Int
        var total: Int
        var recovered: Int
        var failed: Int
        var recoveredRecords: Int
    }

    static let idle = ArchiveProgress(status: .pending, message: "尚未开始归档")
}

/// 进度快照转任务模型, 供界面直接使用
extension ArchiveProgress {
    func asTask() -> ArchiveTask {
        var task = ArchiveTask(accountID: UUID(), taskType: "feed")
        task.status = status
        task.currentPage = pages
        task.discoveredCount = fetched
        task.savedCount = saved
        task.skippedCount = skipped
        task.failedCount = failed
        task.downloadedCount = downloaded
        task.lastError = message
        return task
    }
}

/// 异常跳过结果
struct ArchiveSkipRetryResult {
    var success: Bool
    var message: String
    var recoveredRecords: Int
}

/// 归档引擎
actor ArchiveEngine {
    /// 频率保护窗口, 单位秒
    static let rateWindowSeconds: TimeInterval = 10 * 60
    /// 频率保护窗口内允许请求的最大页数
    static let ratePageLimit = 300
    /// 归档请求间隔下限与上限, 单位毫秒
    static let intervalMinMs = 2000
    static let intervalMaxMs = 30_000
    /// 归档请求间隔默认值, 单位毫秒
    static let intervalDefaultMs = 3000
    /// 异常跳过时单次向前探测的最大偏移推进
    static let skipMaxOffsetAdvance = 4096
    /// 首页失败时的重试次数
    static let firstPageRetryAttempts = 3
    /// 首页失败时的重试退避, 单位毫秒
    static let firstPageRetryDelaysMs = [3000, 6000]

    private let api: QzoneAPIClient
    private let repository: ArchiveRepository
    private let mediaManager: MediaDownloadManager
    private let logger: AppLogger

    private var progress = ArchiveProgress.idle
    private var isCancelled = false
    private var isBatchRetrying = false
    private var batchCancel = false
    /// 最近一次启动归档的账号与参数, 供前台恢复使用
    private var lastAccount: Account?
    private var lastSettings: ArchiveSettings?

    init(api: QzoneAPIClient, database: ArchiveDatabase, mediaManager: MediaDownloadManager, logger: AppLogger) {
        self.api = api
        self.repository = SQLiteArchiveRepository(database: database)
        self.mediaManager = mediaManager
        self.logger = logger
    }

    /// 当前进度快照
    func currentProgress() -> ArchiveProgress { progress }

    // MARK: - 主流程

    /// 开始或继续归档
    func startArchive(account: Account, settings: ArchiveSettings) async throws -> ArchiveProgress {
        guard !isCancelled else { return progress }
        isCancelled = false
        lastAccount = account
        lastSettings = settings
        progress.status = .running
        progress.message = "正在准备归档"
        progress.startedAt()

        var cursor: String?

        if let checkpoint = try? repository.loadCheckpoint(account: account) {
            if Date().timeIntervalSince(checkpoint.updatedAt) > Self.rateWindowSeconds {
                try? repository.clearCheckpoint(account: account)
            } else {
                cursor = checkpoint.attachInfo
                progress.pages = checkpoint.pages
                progress.fetched = checkpoint.fetched
                progress.saved = checkpoint.saved
                progress.message = "从上次中断的位置继续归档"
            }
        }

        var refreshType: FeedRefreshType = cursor == nil ? .firstPage : .normal
        var attachInfo: String? = cursor
        var seenCursors: Set<String> = []
        if let cursor, !cursor.isEmpty { seenCursors.insert(cursor) }
        progress.skipped = (try? repository.listPendingSkipIDs(account: account).count) ?? 0

        while progress.status == .running {
            try Task.checkCancellation()
            if isCancelled { break }

            // 频率保护: 原版在每次取页前 reservePage, 首页同样计入
            guard try await enforceRateLimit(account: account) else {
                progress.status = .paused
                return progress
            }

            let page: QzoneFeedPage
            var skipped: (cursor: String, offsetAdvance: Int)?
            do {
                if refreshType == .firstPage {
                    page = try await fetchFirstPage()
                } else {
                    let result = try await fetchCursorPage(account: account, cursor: attachInfo)
                    page = result.page
                    skipped = result.skipped
                }
            } catch let error as QzoneError {
                progress.status = .failed
                progress.message = error.localizedDescription
                return progress
            }

            // 原版: hasMore 必须带回游标, 重复游标视为死循环
            var next: String?
            if page.hasMore {
                guard let attach = page.attachInfo, !attach.isEmpty else {
                    progress.status = .failed
                    progress.message = "接口表示还有数据，但未返回分页游标"
                    return progress
                }
                next = attach
            }
            if let next {
                guard !seenCursors.contains(next) else {
                    progress.status = .failed
                    progress.message = "检测到重复分页游标，已停止以避免死循环"
                    return progress
                }
                seenCursors.insert(next)
            }
            if let skipped {
                let details = try? FeedCursor.parse(skipped.cursor)
                try? repository.recordSkip(
                    account: account,
                    pageNumber: progress.pages + 1,
                    cursorOffset: details?.offset ?? 0,
                    offsetAdvance: skipped.offsetAdvance,
                    baseTime: details?.baseTime ?? 0,
                    error: "已跳过异常位置",
                    cursor: skipped.cursor
                )
            }

            // 原始记录按 feed_key 落库, 动态与互动由记录派生, 重复归档不会重复计数
            let saved = try repository.saveFeedPage(page.feeds, account: account)
            let posts = FeedParser.parsePosts(page.feeds, account: account)
            progress.pages += 1
            progress.fetched += page.feeds.count
            progress.saved += saved
            progress.skipped = (try? repository.listPendingSkipIDs(account: account).count) ?? progress.skipped
            progress.message = skipped != nil
                ? "已跳过 1 个异常位置并继续归档；当前 \(progress.pages) 页，共 \(progress.fetched) 条记录"
                : "已归档 \(progress.pages) 页，共 \(progress.fetched) 条记录"

            if !page.hasMore {
                progress.status = .completed
                progress.message = progress.skipped > 0
                    ? "归档完成，共保存 \(progress.saved) 条记录；另有 \(progress.skipped) 个异常位置已跳过，可在下方单独重试"
                    : "归档完成，共保存 \(progress.saved) 条记录"
                try? repository.clearCheckpoint(account: account)
                return progress
            }

            let nextCursor = next ?? ""
            try repository.saveCheckpoint(
                account: account,
                attachInfo: nextCursor,
                pages: progress.pages,
                fetched: progress.fetched,
                saved: progress.saved
            )

            // 媒体下载
            if settings.downloadImages || settings.downloadVideos {
                let mediaPosts = posts.filter { !$0.pictureURLs.isEmpty || !$0.videoURLs.isEmpty }
                if !mediaPosts.isEmpty {
                    let downloaded = try? await mediaManager.downloadMedia(
                        for: mediaPosts,
                        account: account,
                        settings: settings
                    )
                    progress.downloaded += downloaded ?? 0
                }
            }

            try repository.saveTaskStatus(
                account: account,
                status: progress.status,
                cursor: nextCursor,
                page: progress.pages,
                progress: progress
            )

            // 每页之间的等待, 避免触发频率保护
            let delayMs = archivePageDelayMs(intervalMs: settings.requestIntervalMs)
            try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            attachInfo = nextCursor
            refreshType = .normal
        }
        return progress
    }

    /// 取消归档
    func cancel() {
        isCancelled = true
        progress.status = .cancelled
        progress.message = "任务已取消"
    }

    /// 从上次检查点继续归档(供前台恢复使用)
    func startArchiveFromCheckpoint() async throws {
        guard let account = lastAccount else { return }
        let settings = lastSettings ?? ArchiveSettings()
        _ = try await startArchive(account: account, settings: settings)
    }

    /// 暂停归档
    func pause() {
        progress.status = .paused
        progress.message = "已暂停，进度已保存"
    }

    /// 恢复归档
    func resume() {
        progress.status = .running
        progress.message = "继续归档"
    }

    // MARK: - 内部流程

    /// 频率保护: 窗口内超过页数上限时暂停并等待
    private func enforceRateLimit(account: Account) async throws -> Bool {
        let now = Date()
        var window = try? repository.loadRateWindow(account: account)
        if window == nil || now.timeIntervalSince(window!.startedAt) > Self.rateWindowSeconds {
            // 新窗口的首个请求同样计入页数
            try? repository.saveRateWindow(
                account: account,
                startedAt: now,
                pages: 1,
                retryAt: nil
            )
            return true
        }
        if window!.pages >= Self.ratePageLimit {
            let retryAt = window!.startedAt.addingTimeInterval(Self.rateWindowSeconds)
            try? repository.saveRateWindow(account: account, startedAt: window!.startedAt,
                                            pages: window!.pages, retryAt: retryAt)
            progress.retryAt = retryAt
            progress.status = .paused
            progress.message = "为防止接口请求过于频繁，每 10 分钟最多归档 300 页。达到限制后已安全暂停，倒计时结束即可从当前进度继续归档。"
            return false
        }
        try? repository.saveRateWindow(account: account, startedAt: window!.startedAt,
                                        pages: window!.pages + 1, retryAt: nil)
        return true
    }

    /// 首页请求: 只对可跳过的错误重试, 最多 3 次, 退避 3 秒与 6 秒
    private func fetchFirstPage() async throws -> QzoneFeedPage {
        var attempt = 1
        while true {
            do {
                return try await api.fetchFeeds(refreshType: .firstPage, attachInfo: nil)
            } catch {
                let message = error.localizedDescription
                guard Self.feedErrorCanSkip(message) else { throw error }
                if attempt >= Self.firstPageRetryAttempts {
                    throw QzoneError.parseFailed("第一页获取空间动态失败（已重试 \(Self.firstPageRetryAttempts) 次）：\(message)")
                }
                progress.message = "第一页请求失败（\(message)），\(attempt)/\(Self.firstPageRetryAttempts) 次重试中…"
                let delay = Self.firstPageRetryDelaysMs[min(attempt - 1, Self.firstPageRetryDelaysMs.count - 1)]
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                attempt += 1
            }
        }
    }

    /// 续传页请求: 可跳过的单页错误先登记再探测, 其余错误直接抛出
    private func fetchCursorPage(
        account: Account,
        cursor: String?
    ) async throws -> (page: QzoneFeedPage, skipped: (cursor: String, offsetAdvance: Int)?) {
        guard let cursor, !cursor.isEmpty else {
            throw QzoneError.parseFailed("分页游标不能为空")
        }
        do {
            return (try await api.fetchFeeds(refreshType: .normal, attachInfo: cursor), nil)
        } catch {
            let message = error.localizedDescription
            // 原版 feedErrorCanSkip: 只有 5xx / 解析失败 / 接口返回错误才跳过, 鉴权与网络错误直接失败
            guard Self.feedErrorCanSkip(message) else { throw error }
            guard let details = try? FeedCursor.parse(cursor) else {
                throw QzoneError.parseFailed("\(message)；且无法自动跳过该页：分页游标无法解析")
            }
            // 先登记待重试位置 (offsetAdvance 0), 探测成功后再更新实际推进量
            try? repository.recordSkip(
                account: account,
                pageNumber: progress.pages + 1,
                cursorOffset: details.offset,
                offsetAdvance: 0,
                baseTime: details.baseTime,
                error: message,
                cursor: cursor
            )
            progress.skipped = (try? repository.listPendingSkipIDs(account: account).count) ?? progress.skipped
            progress.message = "第 \(progress.pages + 1) 页发生异常，已加入待重试列表，正在寻找后续可恢复位置…"
            guard let recovered = try await recoverSkippedPage(account: account, cursor: cursor, error: message) else {
                throw QzoneError.parseFailed("\(message)；向后探测至偏移 +\(Self.skipMaxOffsetAdvance) 后仍无法取得下一页")
            }
            return (recovered.page, (cursor, recovered.offsetAdvance))
        }
    }

    /// 跳过异常位置: 按 2 的幂次探测, 再用二分缩小跳过范围
    private func recoverSkippedPage(
        account: Account,
        cursor: String,
        error: String
    ) async throws -> (page: QzoneFeedPage, offsetAdvance: Int)? {
        guard let details = try? FeedCursor.parse(cursor) else { return nil }
        let firstAdvance = max(1, details.loadCount > 0 ? details.loadCount : 10)
        var best: (page: QzoneFeedPage, offsetAdvance: Int)?
        var lastFailedAdvance = 0
        for offset in FeedCursor.skipProbeOffsets(firstAdvance: firstAdvance) {
            if isCancelled { return nil }
            guard try await enforceRateLimit(account: account) else { return nil }
            do {
                let advanced = try FeedCursor.advance(cursor, offsetAdvance: offset)
                let page = try await api.fetchFeedsOnce(refreshType: .normal, attachInfo: advanced)
                best = (page, offset)
                break
            } catch {
                guard Self.feedErrorCanSkip(error.localizedDescription) else { throw error }
                lastFailedAdvance = offset
            }
        }
        guard var found = best else { return nil }

        var low = lastFailedAdvance + 1
        var high = found.offsetAdvance - 1
        while low <= high {
            if isCancelled { return nil }
            let offset = low + (high - low) / 2
            progress.message = "已找到可恢复位置，正在缩小跳过范围（偏移 +\(offset)）…"
            guard try await enforceRateLimit(account: account) else { return nil }
            do {
                let advanced = try FeedCursor.advance(cursor, offsetAdvance: offset)
                let page = try await api.fetchFeedsOnce(refreshType: .normal, attachInfo: advanced)
                found = (page, offset)
                high = offset - 1
            } catch {
                guard Self.feedErrorCanSkip(error.localizedDescription) else { throw error }
                low = offset + 1
            }
        }
        try? repository.recordSkip(
            account: account,
            pageNumber: progress.pages + 1,
            cursorOffset: details.offset,
            offsetAdvance: found.offsetAdvance,
            baseTime: details.baseTime,
            error: error,
            cursor: cursor
        )
        return found
    }

    /// 原版 feedErrorCanSkip: 5xx / 解析失败 / 接口返回错误可以跳过, 其余不跳过
    static func feedErrorCanSkip(_ message: String) -> Bool {
        message.contains("HTTP 5")
            || message.contains("解析空间动态失败")
            || message.contains("QQ 空间接口返回错误")
            || message.contains("接口返回错误")
    }

    /// 每页请求前的等待毫秒数, 叠加亚秒抖动
    private func archivePageDelayMs(intervalMs: Int) -> Int {
        let interval = min(max(intervalMs, Self.intervalMinMs), Self.intervalMaxMs)
        let jitter = Double.random(in: 0..<Double(interval) / 4.0)
        return interval + Int(jitter)
    }
    // MARK: - 后台与恢复

    /// 进入后台时保存任务状态
    func checkpointForBackground() {
        guard progress.status == .running else { return }
        progress.status = .paused
        progress.message = "已暂停，进度已保存"
    }

    /// 前台恢复提示
    func resumeNoticeIfNeeded() async -> String? {
        guard progress.status == .paused else { return nil }
        return "上次的归档任务已暂停，可以在任务页继续。"
    }
}

// MARK: - 进度辅助

extension ArchiveProgress {
    mutating func startedAt() {
        started = Date()
    }
}

// MARK: - 任务持久化辅助

extension ArchiveRepository {
    /// 保存任务状态, 只在有活跃账号时使用
    func saveTaskStatus(
        account: Account,
        status: ArchiveTask.Status,
        cursor: String,
        page: Int,
        progress: ArchiveProgress
    ) throws {
        var task = (try? loadTask(account: account, taskType: "feed")) ?? ArchiveTask(accountID: account.id, taskType: "feed")
        task.accountID = account.id
        task.status = status
        task.cursor = cursor
        task.currentPage = page
        task.discoveredCount = progress.fetched
        task.savedCount = progress.saved
        task.skippedCount = progress.skipped
        task.failedCount = progress.failed
        task.downloadedCount = progress.downloaded
        try upsertTask(task, account: account)
    }
}
