//
//  PostDetailView.swift
//  QzoneArchive
//
//  动态详情: 正文, 图片, 视频, 点赞与评论
//

import SwiftUI

struct PostDetailView: View {
    @EnvironmentObject var environment: AppEnvironment
    let post: ArchivePost
    @State private var localMedia: [MediaAsset] = []
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                content
                if !localMedia.isEmpty { media }
                if post.likeCount > 0 { likes }
                if post.commentCount > 0 { comments }
            }
            .padding(16)
        }
        .navigationTitle("动态详情")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadMedia() }
        .alert("提示", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("好", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: "https://qlogo2.store.qq.com/qzone/\(post.authorUin ?? "0")/\(post.authorUin ?? "0")/50")) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { Color.gray.opacity(0.2) }
            }
            .frame(width: 42, height: 42)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(post.authorName ?? "QQ 用户")
                    .font(.subheadline.weight(.semibold))
                Text("QQ \(post.authorUin ?? "-") · \(post.category.displayName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(post.publishedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var content: some View {
        Text(QzoneTextFormatter.render(post.contentText))
            .font(.body)
            .textSelection(.enabled)
    }

    private var media: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
            ForEach(localMedia) { asset in
                if let path = asset.localRelativePath {
                    let url = environment.storage.imagesRoot.appendingPathComponent(path)
                    if asset.mediaType == .video {
                        VideoThumbnail(url: url)
                    } else {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.gray.opacity(0.2)
                        }
                        .frame(height: 110)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var likes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("赞过 (\(post.likeCount))")
                .font(.subheadline.weight(.semibold))
            FlowLayout(spacing: 6) {
                ForEach(post.likes, id: \.uin) { like in
                    Text(like.nickname ?? like.uin ?? "")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var comments: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("评论 (\(post.commentCount))")
                .font(.subheadline.weight(.semibold))
            ForEach(post.comments) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(comment.authorName ?? "QQ 用户")
                            .font(.caption.weight(.semibold))
                        Text("QQ \(comment.authorUin ?? "-")")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text(QzoneTextFormatter.render(comment.contentText))
                        .font(.caption)
                    if !comment.replies.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(comment.replies.indices, id: \.self) { index in
                                let reply = comment.replies[index]
                                Text("\(reply.nickname ?? "") 回复：\(reply.content)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.leading, 8)
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func loadMedia() {
        Task {
            let page = await Task.detached(priority: .userInitiated) {
                let repo = SQLiteArchiveRepository(database: self.environment.database)
                let account = Account(id: UUID(), qqUin: self.post.authorUin ?? "0")
                return (try? repo.mediaTimeline(account: account, limit: 40, offset: 0, year: nil)) ?? MediaTimelinePage(items: [], total: 0, years: [])
            }.value
            await MainActor.run {
                localMedia = page.items.filter { $0.dynamicID == post.id }.map { item in
                    MediaAsset(
                        postID: post.sourceID,
                        remoteURL: item.url,
                        localRelativePath: "\(post.sourceID)-\(item.pictureIndex ?? 0).jpg",
                        mediaType: item.mediaType
                    )
                }
            }
        }
    }
}

/// 视频封面占位
private struct VideoThumbnail: View {
    let url: URL

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
            Image(systemName: "play.circle.fill")
                .font(.title)
                .foregroundColor(.white)
        }
        .frame(height: 110)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 流式布局
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
