//
//  ArchiveListViewModel.swift
//  QzoneArchive
//
//  归档浏览: 列表, 分页, 搜索, 删除, 导出
//

import Foundation

@MainActor
final class ArchiveListViewModel: ObservableObject {
    @Published var posts: [ArchivePost] = []
    @Published var total = 0
    @Published var selectedCategory: ArchiveCategory = .self_
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var keyword = ""
    @Published var notice: String?
    @Published var selection: Set<Int> = []
    @Published var showingDeleteConfirm = false
    @Published var showingClearConfirm = false
    @Published var showingExport = false
    @Published var exportedURL: URL?
    @Published var selectedPost: ArchivePost?

    private let environment: AppEnvironment
    private let pageSize = 40

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// 加载第一页
    func load() {
        guard let account = environment.sessionAccount else { return }
        isLoading = true
        selection.removeAll()
        let database = environment.database
        let category = selectedCategory
        let limit = pageSize
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([ArchivePost], Int) in
                let repo = SQLiteArchiveRepository(database: database)
                let items = (try? repo.listPosts(account: account, category: category, limit: limit, offset: 0)) ?? []
                let count = (try? repo.countPosts(account: account, category: category)) ?? 0
                return (items, count)
            }.value
            self.posts = result.0
            self.total = result.1
            self.isLoading = false
        }
    }

    /// 加载下一页
    func loadMoreIfNeeded(current item: ArchivePost) {
        guard let account = environment.sessionAccount,
              !isLoadingMore,
              posts.count < total,
              item.id == posts.last?.id
        else { return }
        isLoadingMore = true
        let database = environment.database
        let category = selectedCategory
        let limit = pageSize
        let offset = posts.count
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [ArchivePost] in
                let repo = SQLiteArchiveRepository(database: database)
                return (try? repo.listPosts(account: account, category: category, limit: limit, offset: offset)) ?? []
            }.value
            self.posts.append(contentsOf: result)
            self.isLoadingMore = false
        }
    }

    /// 搜索本地归档
    func search() {
        guard let account = environment.sessionAccount else { return }
        isLoading = true
        let database = environment.database
        let category = selectedCategory
        let limit = pageSize
        let keyword = self.keyword
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([ArchivePost], Int) in
                let repo = SQLiteArchiveRepository(database: database)
                if keyword.trimmingCharacters(in: .whitespaces).isEmpty {
                    let items = (try? repo.listPosts(account: account, category: category, limit: limit, offset: 0)) ?? []
                    let count = (try? repo.countPosts(account: account, category: category)) ?? 0
                    return (items, count)
                }
                let items = (try? repo.searchPosts(account: account, keyword: keyword, limit: 200, offset: 0)) ?? []
                return (items, items.count)
            }.value
            self.posts = result.0
            self.total = result.1
            self.isLoading = false
        }
    }

    /// 删除选中的归档
    func deleteSelected() {
        guard let account = environment.sessionAccount else { return }
        let ids = Array(selection)
        Task {
            do {
                let database = self.environment.database
                let count = try await Task.detached(priority: .userInitiated) {
                    let repo = SQLiteArchiveRepository(database: database)
                    return try repo.deletePosts(account: account, ids: ids)
                }.value
                self.notice = "已删除 \(count) 条归档"
                self.selection.removeAll()
                self.load()
            } catch {
                await MainActor.run { self.notice = error.localizedDescription }
            }
        }
    }

    /// 清空当前分类
    func clearCategory() {
        guard let account = environment.sessionAccount else { return }
        let category = selectedCategory
        Task {
            do {
                let database = self.environment.database
                let count = try await Task.detached(priority: .userInitiated) {
                    let repo = SQLiteArchiveRepository(database: database)
                    return try repo.clearPosts(account: account)
                }.value
                self.notice = "已清空\(category.displayName)共 \(count) 条"
                self.load()
            } catch {
                self.notice = error.localizedDescription
            }
        }
    }

    /// 导出选中的动态
    func exportSelected() {
        guard let account = environment.sessionAccount else { return }
        let ids = selection.isEmpty ? nil : Array(selection)
        Task {
            do {
                let url = try await environment.exportService.exportHTML(
                    account: account,
                    category: selectedCategory,
                    ids: ids
                )
                await MainActor.run { self.exportedURL = url }
            } catch {
                await MainActor.run { self.notice = error.localizedDescription }
            }
        }
    }
}
