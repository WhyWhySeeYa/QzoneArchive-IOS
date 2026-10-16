//
//  TasksView.swift
//  QzoneArchive
//
//  任务中心: 进度, 暂停/继续/取消, 失败记录与重试
//

import SwiftUI

struct TasksView: View {
    @EnvironmentObject var environment: AppEnvironment
    @StateObject private var viewModel: DashboardViewModel
    @State private var failures: [TaskFailure] = []

    init(environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: DashboardViewModel(environment: environment))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                progressCard
                controlCard
                if !failures.isEmpty {
                    failuresCard
                }
            }
            .padding(16)
        }
        .navigationTitle("任务")
        .onAppear {
            viewModel.refresh()
            loadFailures()
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(viewModel.runningTask?.status.title ?? "无任务")
                    .font(.headline)
                Spacer()
                if viewModel.isLoading { ProgressView() }
            }
            Text(viewModel.runningTask?.lastError ?? "尚未开始归档")
                .font(.caption)
                .foregroundColor(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    metric(title: "已处理页数", value: viewModel.runningTask?.currentPage ?? 0)
                    metric(title: "发现动态", value: viewModel.runningTask?.discoveredCount ?? 0)
                }
                GridRow {
                    metric(title: "已保存", value: viewModel.runningTask?.savedCount ?? 0)
                    metric(title: "已下载", value: viewModel.runningTask?.downloadedCount ?? 0)
                }
                GridRow {
                    metric(title: "跳过", value: viewModel.runningTask?.skippedCount ?? 0)
                    metric(title: "失败", value: viewModel.runningTask?.failedCount ?? 0)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func metric(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var controlCard: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.pauseArchive()
            } label: {
                Label("暂停", systemImage: "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.resumeArchive()
            } label: {
                Label("继续", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.cancelArchive()
            } label: {
                Label("取消", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    private var failuresCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近失败")
                .font(.headline)
            ForEach(failures.prefix(20)) { failure in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.resourceType.rawValue == "media" ? "媒体下载失败" : "动态处理失败")
                            .font(.caption.weight(.medium))
                        Text(failure.errorMessage)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func loadFailures() {
        guard let account = environment.sessionAccount else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let repo = SQLiteArchiveRepository(database: self.environment.database)
                return (try? repo.listFailures(account: account, resolved: false)) ?? []
            }.value
            await MainActor.run { failures = result }
        }
    }
}

extension ArchiveTask.Status {
    var title: String {
        switch self {
        case .pending: return "等待中"
        case .running: return "正在归档"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

#Preview {
    TasksView(environment: AppEnvironment.live())
        .environmentObject(AppEnvironment.live())
}
