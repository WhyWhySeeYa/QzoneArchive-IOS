//
//  ArchiveModels.swift
//  QzoneArchive
//
//  归档领域模型: 动态, 媒体, 评论, 点赞, 任务
//

import Foundation

/// 归档分类
enum ArchiveCategory: String, CaseIterable, Codable {
    case self_
    case other
    case guestbook

    var raw: String {
        switch self {
        case .self_: return "self"
        case .other: return "other"
        case .guestbook: return "guestbook"
        }
    }

    var displayName: String {
        switch self {
        case .self_: return "本人动态"
        case .other: return "好友动态"
        case .guestbook: return "留言"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "self": self = .self_
        case "other": self = .other
        case "guestbook": self = .guestbook
        default: return nil
        }
    }
}

/// 归档动态
struct ArchivePost: Identifiable, Codable {
    var id: Int
    var accountID: UUID
    var sourceID: String
    var authorUin: String?
    var authorName: String?
    var contentText: String
    var publishedAt: Date?
    var archivedAt: Date
    var postType: String
    var sourceURL: String?
    var rawPayloadPath: String?
    var isDeleted: Bool
    /// 图片地址候选, 按基准的候选顺序
    var pictureURLs: [String]
    /// 视频地址候选
    var videoURLs: [String]
    /// 视频封面
    var videoCoverURL: String?
    var likeCount: Int
    var commentCount: Int
    var category: ArchiveCategory
    var likes: [LikeUser]
    var comments: [ArchivedComment]

    init(
        id: Int,
        accountID: UUID,
        sourceID: String,
        authorUin: String?,
        authorName: String?,
        contentText: String,
        publishedAt: Date?,
        archivedAt: Date,
        postType: String,
        sourceURL: String? = nil,
        rawPayloadPath: String? = nil,
        isDeleted: Bool = false,
        pictureURLs: [String] = [],
        videoURLs: [String] = [],
        videoCoverURL: String? = nil,
        likeCount: Int = 0,
        commentCount: Int = 0,
        category: ArchiveCategory = .self_,
        likes: [LikeUser] = [],
        comments: [ArchivedComment] = []
    ) {
        self.id = id
        self.accountID = accountID
        self.sourceID = sourceID
        self.authorUin = authorUin
        self.authorName = authorName
        self.contentText = contentText
        self.publishedAt = publishedAt
        self.archivedAt = archivedAt
        self.postType = postType
        self.sourceURL = sourceURL
        self.rawPayloadPath = rawPayloadPath
        self.isDeleted = isDeleted
        self.pictureURLs = pictureURLs
        self.videoURLs = videoURLs
        self.videoCoverURL = videoCoverURL
        self.likeCount = likeCount
        self.commentCount = commentCount
        self.category = category
        self.likes = likes
        self.comments = comments
    }
}

/// 媒体资源
struct MediaAsset: Identifiable, Codable {
    enum MediaType: String, Codable {
        case image
        case video
        case audio
        case other
    }

    enum DownloadState: String, Codable {
        case pending
        case downloading
        case completed
        case failed
    }

    var id: UUID
    var postID: String
    var remoteURL: String
    var localRelativePath: String?
    var mediaType: MediaType
    var mimeType: String?
    var fileSize: Int64?
    var sha256: String?
    var width: Int?
    var height: Int?
    var downloadState: DownloadState
    var retryCount: Int
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        postID: String,
        remoteURL: String,
        localRelativePath: String? = nil,
        mediaType: MediaType,
        mimeType: String? = nil,
        fileSize: Int64? = nil,
        sha256: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        downloadState: DownloadState = .pending,
        retryCount: Int = 0,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.postID = postID
        self.remoteURL = remoteURL
        self.localRelativePath = localRelativePath
        self.mediaType = mediaType
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.sha256 = sha256
        self.width = width
        self.height = height
        self.downloadState = downloadState
        self.retryCount = retryCount
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 归档评论
struct ArchivedComment: Identifiable, Codable {
    var id: String
    var postID: String
    var parentID: String?
    var authorUin: String?
    var authorName: String?
    var contentText: String
    var publishedAt: Date?
    var createdAt: Date
    var replies: [ArchivedReply]

    init(
        id: String,
        postID: String,
        parentID: String? = nil,
        authorUin: String? = nil,
        authorName: String? = nil,
        contentText: String,
        publishedAt: Date? = nil,
        createdAt: Date = Date(),
        replies: [ArchivedReply] = []
    ) {
        self.id = id
        self.postID = postID
        self.parentID = parentID
        self.authorUin = authorUin
        self.authorName = authorName
        self.contentText = contentText
        self.publishedAt = publishedAt
        self.createdAt = createdAt
        self.replies = replies
    }
}

/// 归档回复
struct ArchivedReply: Codable {
    var uin: String?
    var nickname: String?
    var replyToUin: String?
    var replyToNickname: String?
    var content: String
    var createdAt: Int
}

/// 点赞用户
struct LikeUser: Codable {
    var uin: String?
    var nickname: String?
}

/// 归档任务
struct ArchiveTask: Identifiable, Codable {
    enum Status: String, Codable {
        case pending
        case running
        case paused
        case completed
        case failed
        case cancelled
    }

    var id: UUID
    var accountID: UUID
    var taskType: String
    var status: Status
    var cursor: String?
    var currentPage: Int
    var discoveredCount: Int
    var savedCount: Int
    var skippedCount: Int
    var failedCount: Int
    var downloadedCount: Int
    var startedAt: Date?
    var finishedAt: Date?
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        accountID: UUID,
        taskType: String,
        status: Status = .pending,
        cursor: String? = nil,
        currentPage: Int = 0,
        discoveredCount: Int = 0,
        savedCount: Int = 0,
        skippedCount: Int = 0,
        failedCount: Int = 0,
        downloadedCount: Int = 0,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        lastError: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountID = accountID
        self.taskType = taskType
        self.status = status
        self.cursor = cursor
        self.currentPage = currentPage
        self.discoveredCount = discoveredCount
        self.savedCount = savedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.downloadedCount = downloadedCount
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 任务失败记录
struct TaskFailure: Identifiable, Codable {
    enum ResourceType: String, Codable {
        case post
        case media
        case comment
        case like
    }

    var id: UUID
    var taskID: UUID
    var resourceType: ResourceType
    var resourceID: String
    var errorCode: String?
    var errorMessage: String
    var retryCount: Int
    var resolved: Bool
    var createdAt: Date
    var updatedAt: Date
}

/// 归档概览统计
struct ArchiveOverview {
    var dynamics: Int
    var pictures: Int
    var videos: Int
    var comments: Int
    var likes: Int
    var databaseBytes: Int64
    var mediaBytes: Int64
}

/// 互动排行条目
struct InteractionRank: Identifiable {
    var uin: String
    var id: String { uin }
    var nickname: String
    var interactions: Int
    var likes: Int
    var comments: Int
}

/// 媒体时光轴条目
struct MediaTimelineItem: Identifiable, Hashable {
    var key: String
    var dynamicID: Int
    var mediaType: MediaAsset.MediaType
    var pictureIndex: Int?
    var url: String
    var coverURL: String?
    var publishedAt: Date?
    var authorUin: String?
    var authorName: String?
    var content: String?

    var id: String { key }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }

    static func == (lhs: MediaTimelineItem, rhs: MediaTimelineItem) -> Bool {
        lhs.key == rhs.key
    }
}

/// 媒体时光轴分页
struct MediaTimelinePage {
    var items: [MediaTimelineItem]
    var total: Int
    var years: [Int]
}
