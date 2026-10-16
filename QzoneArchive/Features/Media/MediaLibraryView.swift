//
//  MediaLibraryView.swift
//  QzoneArchive
//
//  媒体库: 时间线浏览, 年份筛选, 保存到相册, 按发布范围归档
//

import SwiftUI
import Photos

struct MediaLibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var items: [MediaTimelineItem] = []
    @State private var years: [Int] = []
    @State private var selectedYear: Int?
    @State private var isLoading = false
    @State private var notice: String?
    @State private var fullScreenItem: MediaTimelineItem?

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 4)]

    init() {}

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                yearPicker
                if isLoading {
                    ProgressView().padding(.top, 40)
                } else if items.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
        }
        .navigationTitle("媒体库")
        .onAppear { Task { await load() } }
        .alert("提示", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("好", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
        .sheet(item: $fullScreenItem) { item in
            MediaDetailView(item: item)
        }
    }

    private var yearPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "全部", isSelected: selectedYear == nil) { selectedYear = nil; Task { await load() } }
                ForEach(years, id: \.self) { year in
                    FilterChip(title: "\(year)", isSelected: selectedYear == year) {
                        selectedYear = year
                        Task { await load() }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(items) { item in
                Button { fullScreenItem = item } label: {
                    ZStack(alignment: .bottomTrailing) {
                        mediaThumb(item)
                        if item.mediaType == .video {
                            Image(systemName: "video.fill")
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(6)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func mediaThumb(_ item: MediaTimelineItem) -> some View {
        if let cover = item.coverURL, let url = URL(string: cover) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.gray.opacity(0.2)
            }
            .frame(height: 105)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            AsyncImage(url: URL(string: item.url)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.gray.opacity(0.2)
            }
            .frame(height: 105)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("媒体库为空")
                .font(.headline)
            Text("归档动态时会自动保存可用的图片与视频。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func load() async {
        guard let account = environment.sessionAccount else { return }
        isLoading = true
        let database = environment.database
        let year = selectedYear
        let page = await Task.detached(priority: .userInitiated) {
            let repo = SQLiteArchiveRepository(database: database)
            return (try? repo.mediaTimeline(account: account, limit: 200, offset: 0, year: year))
                ?? MediaTimelinePage(items: [], total: 0, years: [])
        }.value
        self.items = page.items
        self.years = page.years
        self.isLoading = false
    }
}

/// 媒体全屏查看
struct MediaDetailView: View {
    let item: MediaTimelineItem
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                AsyncImage(url: URL(string: item.coverURL ?? item.url)) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.authorName ?? "QQ 用户")
                        .font(.headline)
                    Text(item.content ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                Spacer()
            }
            .navigationTitle(item.mediaType == .image ? "图片" : "视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存到相册") { saveToPhotos() }
                }
            }
            .alert("提示", isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil } }
            )) {
                Button("好", role: .cancel) { notice = nil }
            } message: {
                Text(notice ?? "")
            }
        }
    }

    private func saveToPhotos() {
        guard let url = URL(string: item.url) else { return }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    if item.mediaType == .image {
                        request.addResource(with: .photo, data: data, options: nil)
                    } else {
                        request.addResource(with: .video, data: data, options: nil)
                    }
                }
                await MainActor.run { notice = "已保存到系统相册" }
            } catch {
                await MainActor.run { notice = "保存失败：\(error.localizedDescription)" }
            }
        }
    }
}

/// 筛选胶囊
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                .foregroundColor(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
