//
//  SettingsView.swift
//  QzoneArchive
//
//  设置: 归档范围, 媒体下载, 频率控制, 日志, 账号
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var appState: AppState
    @State private var settings = ArchiveSettings()
    @State private var showingClearConfirm = false
    @State private var showingLogs = false
    @State private var notice: String?

    var body: some View {
        Form {
            accountSection
            archiveSection
            mediaSection
            controlSection
            logSection
            dangerSection
        }
        .navigationTitle("设置")
        .onAppear { settings = environment.settings.archiveSettings }
        .onChange(of: settings) { _, _ in save() }
        .alert("提示", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("好", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
        .confirmationDialog("确认清空所有本地归档数据？", isPresented: $showingClearConfirm, titleVisibility: .visible) {
            Button("删除全部数据", role: .destructive) { clearData() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("归档的正文, 评论, 点赞与已下载的媒体都会被删除，且无法恢复。")
        }
        .sheet(isPresented: $showingLogs) {
            NavigationStack {
                ScrollView {
                    Text(AppLogger.redact(environment.logger.exportLogs()))
                        .font(.system(size: 10).monospaced())
                        .padding()
                }
                .navigationTitle("运行日志")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showingLogs = false }
                    }
                }
            }
        }
    }

    private var accountSection: some View {
        Section {
            if let account = appState.account {
                LabeledContent("QQ 账号", value: account.qqUin)
                if let nickname = account.nickname {
                    LabeledContent("昵称", value: nickname)
                }
                Button("退出登录") { logout() }
                    .foregroundColor(.red)
            } else {
                Text("未登录")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("账号")
        }
    }

    private var archiveSection: some View {
        Section {
            Toggle("归档本人动态", isOn: $settings.archiveSelfPosts)
            Toggle("归档好友动态", isOn: $settings.archiveFriendPosts)
            Toggle("归档留言板", isOn: $settings.archiveGuestbook)
        } header: {
            Text("归档范围")
        } footer: {
            Text("关闭的分类不会写入归档库，但已归档的内容仍会保留。")
        }
    }

    private var mediaSection: some View {
        Section {
            Toggle("下载图片", isOn: $settings.downloadImages)
            Toggle("下载视频", isOn: $settings.downloadVideos)
            Toggle("保存评论与点赞", isOn: $settings.downloadComments)
            Stepper("并发下载上限: \(settings.maxConcurrentDownloads)",
                    value: $settings.maxConcurrentDownloads, in: 1...4)
        } header: {
            Text("媒体下载")
        } footer: {
            Text("视频文件较大，建议在 Wi-Fi 下开启。"
        )
        }
    }

    private var controlSection: some View {
        Section {
            Stepper("请求间隔 \(String(format: "%.1f", Double(settings.requestIntervalMs) / 1000)) 秒",
                    value: $settings.requestIntervalMs, in: 2000...30000, step: 500)
            Stepper("失败重试次数 \(settings.retryLimit)", value: $settings.retryLimit, in: 1...6)
        } header: {
            Text("频率控制")
        } footer: {
            Text("间隔过短会触发 QQ 空间风控，归档任务将自动暂停。")
        }
    }

    private var logSection: some View {
        Section {
            Button("查看运行日志") { showingLogs = true }
            Button("清空日志") {
                environment.logger.clearLogs()
                notice = "日志已清空"
            }
        } header: {
            Text("日志")
        } footer: {
            Text("日志已自动脱敏，不包含 Cookie, 令牌或密码。")
        }
    }

    private var dangerSection: some View {
        Section {
            Button("重新查看免责声明") { appState.resetDisclaimer() }
            Button("清空所有本地数据", role: .destructive) {
                showingClearConfirm = true
            }
        } header: {
            Text("数据管理")
        } footer: {
            Text("当前占用 \(viewModelDiskText())，设备可用空间 \(ByteCountFormatter.string(fromByteCount: environment.storage.availableDiskSpace, countStyle: .file))。")
        }
    }

    // MARK: - 操作

    private func viewModelDiskText() -> String {
        let bytes = environment.storage.directorySize(environment.storage.appDataRoot)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func save() {
        environment.settings.archiveSettings = settings
    }

    private func logout() {
        Task {
            await environment.session.logout()
            await MainActor.run {
                appState.isLoggedIn = false
                appState.account = nil
                appState.hasAcceptedDisclaimer = false
            }
        }
    }

    private func clearData() {
        do {
            try environment.storage.clearAllData()
            try environment.database.resetDatabase()
            notice = "本地数据已清空"
            environment.refreshLoginState { _ in }
        } catch {
            notice = "清空失败：\(error.localizedDescription)"
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppEnvironment.live())
        .environmentObject(AppState(environment: AppEnvironment.live()))
}
