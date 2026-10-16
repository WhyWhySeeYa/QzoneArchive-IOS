//
//  AppEnvironment.swift
//  QzoneArchive
//
//  依赖容器: 组装登录, 接口, 归档, 媒体, 数据库, 导出等仓库
//

import Foundation

/// 应用依赖容器, 供 SwiftUI 环境注入
@MainActor
final class AppEnvironment: ObservableObject {
    let settings: AppSettingsStore
    let credentials: CredentialStore
    let session: LoginSession
    let api: QzoneAPIClient
    let database: ArchiveDatabase
    let storage: FileStorageService
    let archiveEngine: ArchiveEngine
    let mediaManager: MediaDownloadManager
    let exportService: ExportService
    let logger: AppLogger

    /// 当前登录账号, 由登录模块维护
    @Published private(set) var sessionAccount: Account?

    init(
        settings: AppSettingsStore,
        credentials: CredentialStore,
        session: LoginSession,
        api: QzoneAPIClient,
        database: ArchiveDatabase,
        storage: FileStorageService,
        archiveEngine: ArchiveEngine,
        mediaManager: MediaDownloadManager,
        exportService: ExportService,
        logger: AppLogger
    ) {
        self.settings = settings
        self.credentials = credentials
        self.session = session
        self.api = api
        self.database = database
        self.storage = storage
        self.archiveEngine = archiveEngine
        self.mediaManager = mediaManager
        self.exportService = exportService
        self.logger = logger
    }

    /// 组装线上依赖
    static func live() -> AppEnvironment {
        let settings = AppSettingsStore(userDefaults: .standard)
        let logger = AppLogger()
        let credentials = KeychainCredentialStore()
        let session = LoginSession(credentials: credentials, logger: logger)
        let api = QzoneAPIClient(session: session, logger: logger)
        let database = ArchiveDatabase()
        let storage = FileStorageService()
        let mediaManager = MediaDownloadManager(storage: storage, logger: logger)
        let archiveEngine = ArchiveEngine(api: api, database: database, mediaManager: mediaManager, logger: logger)
        let exportService = ExportService(database: database, storage: storage)
        return AppEnvironment(
            settings: settings,
            credentials: credentials,
            session: session,
            api: api,
            database: database,
            storage: storage,
            archiveEngine: archiveEngine,
            mediaManager: mediaManager,
            exportService: exportService,
            logger: logger
        )
    }

    /// 刷新登录态, 供前台恢复使用
    func refreshLoginState(completion: @escaping (Account?) -> Void) {
        Task.detached(priority: .userInitiated) { [session] in
            let account = await session.currentAccount()
            await MainActor.run {
                self.sessionAccount = account
                completion(account)
            }
        }
    }

    /// 登录成功后同步账号状态
    func handleLoginSuccess(_ account: Account) {
        sessionAccount = account
        Task { [session] in
            var updated = account
            updated.lastLoginAt = Date()
            updated.updatedAt = Date()
            try? await session.saveAccount(updated)
            await MainActor.run { self.sessionAccount = updated }
        }
    }

    /// 尝试继续上次未完成的任务
    func resumeInterruptedTaskIfNeeded(completion: @escaping (String?) -> Void) {
        Task.detached(priority: .utility) { [archiveEngine = self.archiveEngine, session = self.session] in
            guard await session.isLoggedIn() else {
                await MainActor.run { completion(nil) }
                return
            }
            let notice = await archiveEngine.resumeNoticeIfNeeded()
            await MainActor.run { completion(notice) }
        }
    }

    /// 进入后台时保存任务状态
    func persistRunningTaskForBackground() {
        Task.detached(priority: .utility) { [archiveEngine = self.archiveEngine] in
            await archiveEngine.checkpointForBackground()
        }
    }
}
