//
//  DashboardViewModel.swift
//  QzoneArchive
//
//  概览页状态
//

import Foundation
import SwiftUI

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var overview = ArchiveOverview(dynamics: 0, pictures: 0, videos: 0, comments: 0, likes: 0, databaseBytes: 0, mediaBytes: 0)
    @Published var runningTask: ArchiveTask?
    @Published var isLoading = false
    @Published var notice: String?

    private let environment: AppEnvironment
    private let repository: ArchiveRepository

    init(environment: AppEnvironment) {
        self.environment = environment
        self.repository = SQLiteArchiveRepository(database: environment.database)
    }

    /// 刷新概览
    func refresh() {
        guard let account = environment.sessionAccount else { return }
        isLoading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let repo = SQLiteArchiveRepository(database: self.environment.database)
                return (try? repo.overview(
                    account: account,
                    mediaBytes: self.environment.storage.directorySize(
                        self.environment.storage.imagesRoot
                    )
                )) ?? ArchiveOverview(
                    dynamics: 0, pictures: 0, videos: 0, comments: 0, likes: 0, databaseBytes: 0, mediaBytes: 0
                )
            }.value
            await MainActor.run {
                self.overview = result
                self.isLoading = false
            }
        }
    }

    /// 开始全量归档
    func startArchive() {
        guard let account = environment.sessionAccount else { return }
        let settings = environment.settings.archiveSettings
        Task {
            do {
                try await environment.archiveEngine.startArchive(account: account, settings: settings)
                notice = "归档任务已开始"
            } catch {
                notice = error.localizedDescription
            }
            refreshProgress()
            refresh()
        }
    }

    /// 暂停当前任务
    func pauseArchive() {
        Task { await environment.archiveEngine.pause() ; await self.refreshProgress() }
    }

    /// 继续当前任务
    func resumeArchive() {
        guard let account = environment.sessionAccount else { return }
        let settings = environment.settings.archiveSettings
        Task {
            await environment.archiveEngine.resume()
            refreshProgress()
        }
    }

    /// 取消当前任务
    func cancelArchive() {
        Task { await environment.archiveEngine.cancel() ; await self.refreshProgress() }
    }

    /// 读取引擎当前进度
    func refreshProgress() async {
        let progress = await environment.archiveEngine.currentProgress()
        runningTask = progress.asTask()
    }

    /// 总占用空间描述
    var storageDescription: String {
        let total = overview.databaseBytes + overview.mediaBytes
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    var diskDescription: String {
        ByteCountFormatter.string(fromByteCount: environment.storage.availableDiskSpace, countStyle: .file)
    }
}
