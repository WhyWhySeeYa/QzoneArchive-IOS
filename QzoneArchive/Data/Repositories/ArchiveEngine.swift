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
        var resetCheckpointStats = false

        if let checkpoint = try? repository.loadCheckpoint(account: account) {
            if Date().timeIntervalSince(checkpoint.updatedAt) > Self.rateWindowSeconds {
                try? repository.clearCheckpoint(account: account)
                resetCheckpointStats = true
            } else {
                cursor = checkpoint.attachInfo
                progress.pages = checkpoint.pages
                progress.fetched = checkpoint.fetched
                progress.saved = checkpoint.saved
                progress.message = "从上次中断的位置继续归档"
            }
        } else {
            resetCheckpointStats = true
        }

        var refreshType: FeedRefreshType = cursor == nil ? .firstPage : .normal
        var attachInfo: String? = cursor
        var seenCursors: Set<String> = []

        while progress.status == .running {
            try Task.checkCancellation()
            if isCancelled { break }
            if let attachInfo, !attachInfo.isEmpty {
                if seenCursors.contains(attachInfo) {
                    progress.status = .completed
                    progress.message = "已到最后一页"
                    break
                }
                seenCursors.insert(attachInfo)
            }

            // 频率保护
            if try await enforceRateLimit(account: account) == false {
                progress.status = .paused
                return progress
            }

            let page: QzoneFeedPage
            let attemptDelay: Int
            do {
                (page, attemptDelay) = try await fetchPageWithFirstPageRetry(
                    refreshType: refreshType,
                    attachInfo: attachInfo
                )
            } catch let error as QzoneError {
                if error.isAuthError {
                    progress.status = .failed
                    progress.message = error.localizedDescription
                    return progress
                }
                if let result = try await handlePageError(
                    account: account,
                    error: error,
                    attachInfo: attachInfo,
                    pageNumber: progress.pages + 1
                ) {
                    attachInfo = result.cursor
                    refreshType = .normal
                    continue
                }
                progress.status = .failed
                progress.message = error.localizedDescription
                return progress
            }
            if attemptDelay > 0 {
                progress.message = "接口暂时不可用，正在重试"
            }

            let posts = FeedParser.parsePosts(page.feeds, account: account)
            let saved = try repository.savePosts(posts, account: account)
            progress.pages += 1
            progress.fetched += page.feeds.count
            progress.saved += saved
            progress.message = "已归档 \(progress.saved) 条"

            if !page.hasMore || page.attachInfo == nil {
                progress.status = .completed
                progress.message = "归档完成，共 \(progress.saved) 条"
                try? repository.clearCheckpoint(account: account)
                return progress
            }

            let nextCursor = page.attachInfo ?? ""
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
            try? repository.saveRateWindow(
                account: account,
                startedAt: now,
                pages: 0,
                retryAt: nil
            )
            window = (now, 0, nil)
            return true
        }
        if window!.pages >= Self.ratePageLimit {
            let retryAt = window!.startedAt.addingTimeInterval(Self.rateWindowSeconds)
            try? repository.saveRateWindow(account: account, startedAt: window!.startedAt,
                                            pages: window!.pages, retryAt: retryAt)
            progress.retryAt = retryAt
            progress.message = "为防止接口请求过于频繁，每 10 分钟最多归档 300 页。达到限制后已安全暂停，倒计时结束即可从当前进度继续归档。"
            return false
        }
        try? repository.saveRateWindow(account: account, startedAt: window!.startedAt,
                                        pages: window!.pages + 1, retryAt: nil)
        return true
    }

    /// 首页失败时按固定退避重试
    private func fetchPageWithFirstPageRetry(
        refreshType: FeedRefreshType,
        attachInfo: String?
    ) async throws -> (page: QzoneFeedPage, waited: Int) {
        var attempt = 1
        var totalWait = 0
        while true {
            do {
                let page = try await api.fetchFeeds(refreshType: refreshType, attachInfo: attachInfo)
                return (page, totalWait)
            } catch {
                if attempt >= Self.firstPageRetryAttempts { throw error }
                let delay = Self.firstPageRetryDelaysMs[min(attempt - 1, Self.firstPageRetryDelaysMs.count - 1)]
                totalWait += delay
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                attempt += 1
            }
        }
    }

    /// 单页错误处理: 能跳过则返回新的游标
    private func handlePageError(
        account: Account,
        error: QzoneError,
        attachInfo: String?,
        pageNumber: Int
    ) async throws -> (cursor: String, offsetAdvance: Int)? {
        guard let cursor = attachInfo, !cursor.isEmpty else { return nil }
        let details: FeedCursorDetails
        do { details = try FeedCursor.parse(cursor) } catch { return nil }

        // 频率保护类错误直接暂停
        if case .apiError(let code, let message) = error,
           code == 1100 || message.contains("操作太频繁") || message.contains("请稍后再试") {
            let retryAt = Date().addingTimeInterval(10 * 60)
            try? repository.saveRateWindow(
                account: account,
                startedAt: Date(),
                pages: Self.ratePageLimit,
                retryAt: retryAt
            )
            progress.retryAt = retryAt
            progress.message = "QQ 空间提示请求过于频繁，已自动暂停。"
            return nil
        }

        // 值得跳过的单页错误: 按偏移序列向前探测
        let firstAdvance = max(1, details.loadCount > 0 ? details.loadCount : 10)
        for offset in FeedCursor.skipProbeOffsets(firstAdvance: firstAdvance) {
            if isCancelled { return nil }
            do {
                let advanced = try FeedCursor.advance(cursor, offsetAdvance: offset)
                let page = try await api.fetchFeeds(refreshType: .normal, attachInfo: advanced)
                try? repository.recordSkip(
                    account: account,
                    pageNumber: pageNumber,
                    cursorOffset: details.offset,
                    offsetAdvance: offset,
                    baseTime: details.baseTime,
                    error: error.localizedDescription,
                    cursor: cursor
                )
                return (advanced, offset)
            } catch {
                continue
            }
        }
        return nil
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
