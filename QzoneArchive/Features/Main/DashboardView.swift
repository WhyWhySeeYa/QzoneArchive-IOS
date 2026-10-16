//
//  DashboardView.swift
//  QzoneArchive
//
//  概览页: 统计卡片, 账号信息, 归档任务控制
//

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel: DashboardViewModel

    init(environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: DashboardViewModel(environment: environment))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                accountCard
                statsGrid
                taskCard
                storageCard
            }
            .padding(20)
        }
        .navigationTitle("概览")
        .onAppear { Task { await viewModel.refresh() } }
        .refreshable { await viewModel.refresh() }
        .alert("提示", isPresented: Binding(
            get: { viewModel.notice != nil },
            set: { if !$0 { viewModel.notice = nil } }
        )) {
            Button("好", role: .cancel) { viewModel.notice = nil }
        } message: {
            Text(viewModel.notice ?? "")
        }
    }

    // MARK: - 账号

    private var accountCard: some View {
        HStack(spacing: 14) {
            AsyncImage(url: environment.sessionAccount?.avatarURL.flatMap(URL.init(string:))) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: Color.gray.opacity(0.25)
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(environment.sessionAccount?.nickname ?? "未登录")
                    .font(.headline)
                Text("QQ \(environment.sessionAccount?.qqUin ?? "-")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if environment.sessionAccount != nil {
                Label("已登录", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Label("未登录", systemImage: "xmark.seal.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 统计

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            StatCard(title: "动态", value: "\(viewModel.overview.dynamics)", icon: "text.bubble.fill", color: .blue)
            StatCard(title: "图片", value: "\(viewModel.overview.pictures)", icon: "photo.fill", color: .mint)
            StatCard(title: "视频", value: "\(viewModel.overview.videos)", icon: "video.fill", color: .purple)
            StatCard(title: "评论", value: "\(viewModel.overview.comments)", icon: "bubble.left.fill", color: .orange)
            StatCard(title: "点赞", value: "\(viewModel.overview.likes)", icon: "heart.fill", color: .pink)
            StatCard(title: "本地占用", value: viewModel.storageDescription, icon: "internaldrive.fill", color: .gray)
        }
    }

    // MARK: - 任务

    @ViewBuilder
    private var taskCard: some View {
        if let task = viewModel.runningTask {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(task.status.displayName)
                        .font(.headline)
                        .foregroundColor(statusColor(task.status))
                    Spacer()
                    Text(task.lastError ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                ProgressRow(title: "已保存", value: task.savedCount)
                ProgressRow(title: "已跳过", value: task.skippedCount)
                ProgressRow(title: "已失败", value: task.failedCount)
                if task.downloadedCount > 0 {
                    ProgressRow(title: "已下载媒体", value: task.downloadedCount)
                }
                HStack(spacing: 10) {
                    if task.status == .running {
                        Button("暂停") { viewModel.pauseArchive() }
                            .buttonStyle(.bordered)
                    } else if task.status == .paused {
                        Button("继续") { viewModel.resumeArchive() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("取消", role: .destructive) { viewModel.cancelArchive() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("开始归档")
                    .font(.headline)
                Text("将从当前账号的全部历史动态开始归档，支持断点续传。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button {
                    viewModel.startArchive()
                } label: {
                    Label("开始全量归档", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(environment.sessionAccount == nil)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - 存储

    private var storageCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("iPhone 可用空间")
                    .font(.headline)
                Text(viewModel.diskDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "externaldrive.fill")
                .foregroundColor(.accentColor)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func statusColor(_ status: ArchiveTask.Status) -> Color {
        switch status {
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .paused: return .orange
        case .cancelled: return .gray
        case .pending: return .secondary
        }
    }
}

/// 统计卡片
struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(value)
                .font(.title3.weight(.bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// 进度行
private struct ProgressRow: View {
    let title: String
    let value: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text("\(value)")
                .font(.caption.weight(.semibold))
        }
    }
}
