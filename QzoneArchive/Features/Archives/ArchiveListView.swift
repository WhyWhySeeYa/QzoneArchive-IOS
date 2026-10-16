//
//  ArchiveListView.swift
//  QzoneArchive
//
//  归档库: 分类筛选, 列表, 详情, 导出, 删除
//

import SwiftUI

struct ArchiveListView: View {
    @EnvironmentObject var environment: AppEnvironment
    @StateObject private var viewModel: ArchiveListViewModel

    init(environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: ArchiveListViewModel(environment: environment))
    }

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                categoryPicker
                searchBar
                if viewModel.isLoading {
                    ProgressView().padding(.top, 40)
                } else if viewModel.posts.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .padding(16)
        }
        .navigationTitle("归档库")
        .onAppear { viewModel.load() }
        .searchable(text: $viewModel.keyword, placement: .navigationBarDrawer(displayMode: .inline)) {
            Button("搜索") { viewModel.search() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !viewModel.selection.isEmpty {
                    Button("导出") { viewModel.showingExport = true }
                    Button("删除", role: .destructive) { viewModel.showingDeleteConfirm = true }
                }
                Menu {
                    Button("导出当前分类") { viewModel.exportSelected() }
                    Button("清空当前分类", role: .destructive) { viewModel.showingClearConfirm = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("确认删除", isPresented: $viewModel.showingDeleteConfirm) {
            Button("删除 \(viewModel.selection.count) 条归档", role: .destructive) { viewModel.deleteSelected() }
        } message: {
            Text("删除后无法恢复，媒体文件也会一并清理。")
        }
        .confirmationDialog("确认清空", isPresented: $viewModel.showingClearConfirm) {
            Button("清空「\(viewModel.selectedCategory.displayName)」", role: .destructive) { viewModel.clearCategory() }
        } message: {
            Text("该分类下的全部归档与媒体都会被删除。")
        }
        .sheet(isPresented: $viewModel.showingExport) {
            ShareSheet(items: [viewModel.exportedURL].compactMap { $0 })
        }
        .alert("提示", isPresented: Binding(
            get: { viewModel.notice != nil },
            set: { if !$0 { viewModel.notice = nil } }
        )) {
            Button("好", role: .cancel) { viewModel.notice = nil }
        } message: {
            Text(viewModel.notice ?? "")
        }
        .onChange(of: viewModel.selectedCategory) { _, _ in viewModel.load() }
    }

    private var categoryPicker: some View {
        Picker("分类", selection: $viewModel.selectedCategory) {
            ForEach(ArchiveCategory.allCases, id: \.self) { category in
                Text(category.displayName).tag(category)
            }
        }
        .pickerStyle(.segmented)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("搜索正文、作者或 QQ 号", text: $viewModel.keyword)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .onSubmit(viewModel.search)
            if !viewModel.keyword.isEmpty {
                Button {
                    viewModel.keyword = ""
                    viewModel.search()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(viewModel.posts) { post in
                PostCard(
                    post: post,
                    isSelected: viewModel.selection.contains(post.id),
                    onTap: {
                        if viewModel.selection.isEmpty {
                            viewModel.selectedPost = post
                        } else {
                            toggle(post)
                        }
                    },
                    onLongPress: { toggle(post) }
                )
                .onAppear { viewModel.loadMoreIfNeeded(current: post) }
            }
            if viewModel.isLoadingMore {
                ProgressView().gridCellColumns(2)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("还没有归档内容")
                .font(.headline)
            Text("在概览页开始归档后，内容会自动出现在这里。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func toggle(_ post: ArchivePost) {
        if viewModel.selection.contains(post.id) {
            viewModel.selection.remove(post.id)
        } else {
            viewModel.selection.insert(post.id)
        }
    }
}

/// 动态卡片
private struct PostCard: View {
    let post: ArchivePost
    let isSelected: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(post.authorName ?? "QQ 用户")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if post.pictureURLs.count > 0 {
                        Label("\(post.pictureURLs.count)", systemImage: "photo")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if !post.videoURLs.isEmpty {
                        Image(systemName: "video.fill")
                            .font(.caption2)
                            .foregroundColor(.purple)
                    }
                }
                Text(post.contentText.isEmpty ? "（无文字内容）" : post.contentText)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxHeight: 84, alignment: .topLeading)
                HStack(spacing: 10) {
                    Label("\(post.likeCount)", systemImage: "heart")
                    Label("\(post.commentCount)", systemImage: "bubble.left")
                    Spacer()
                    Text(post.publishedAt?.formatted(date: .abbreviated, time: .omitted) ?? "")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .onLongPressGesture(perform: onLongPress)
    }
}

/// 分享面板
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
