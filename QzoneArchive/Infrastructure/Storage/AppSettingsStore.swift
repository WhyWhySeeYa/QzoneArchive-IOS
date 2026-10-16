//
//  AppSettingsStore.swift
//  QzoneArchive
//
//  本地设置存储: 免责声明, 归档参数, 外观
//

import Foundation

/// 外观模式
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

/// 归档设置
struct ArchiveSettings: Codable, Equatable {
    var archiveSelfPosts: Bool = true
    var archiveFriendPosts: Bool = true
    var archiveGuestbook: Bool = true
    var downloadImages: Bool = true
    var downloadVideos: Bool = true
    var downloadComments: Bool = true
    var downloadLikes: Bool = true
    var maxConcurrentDownloads: Int = 2
    var requestIntervalMs: Int = 3000
    var retryLimit: Int = 3
    var skipExisting: Bool = true
    /// 归档时间范围下限, 0 表示不限
    var startTimestamp: Int = 0
    var endTimestamp: Int = 0

    private enum CodingKeys: String, CodingKey {
        case archiveSelfPosts, archiveFriendPosts, archiveGuestbook
        case downloadImages, downloadVideos, downloadComments, downloadLikes
        case maxConcurrentDownloads, requestIntervalMs, retryLimit, skipExisting
        case startTimestamp, endTimestamp
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        archiveSelfPosts = try container.decodeIfPresent(Bool.self, forKey: .archiveSelfPosts) ?? true
        archiveFriendPosts = try container.decodeIfPresent(Bool.self, forKey: .archiveFriendPosts) ?? true
        archiveGuestbook = try container.decodeIfPresent(Bool.self, forKey: .archiveGuestbook) ?? true
        downloadImages = try container.decodeIfPresent(Bool.self, forKey: .downloadImages) ?? true
        downloadVideos = try container.decodeIfPresent(Bool.self, forKey: .downloadVideos) ?? true
        downloadComments = try container.decodeIfPresent(Bool.self, forKey: .downloadComments) ?? true
        downloadLikes = try container.decodeIfPresent(Bool.self, forKey: .downloadLikes) ?? true
        maxConcurrentDownloads = try container.decodeIfPresent(Int.self, forKey: .maxConcurrentDownloads) ?? 2
        requestIntervalMs = try container.decodeIfPresent(Int.self, forKey: .requestIntervalMs) ?? 3000
        retryLimit = try container.decodeIfPresent(Int.self, forKey: .retryLimit) ?? 3
        skipExisting = try container.decodeIfPresent(Bool.self, forKey: .skipExisting) ?? true
        startTimestamp = try container.decodeIfPresent(Int.self, forKey: .startTimestamp) ?? 0
        endTimestamp = try container.decodeIfPresent(Int.self, forKey: .endTimestamp) ?? 0
    }
}

/// 设置读写, 全部落在 UserDefaults
final class AppSettingsStore: ObservableObject {
    private let defaults: UserDefaults

    enum Key {
        static let disclaimerAccepted = "qza.disclaimer.accepted"
        static let appearance = "qza.appearance"
        static let settings = "qza.archive.settings"
    }

    init(userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
        _hasAcceptedDisclaimer = defaults.bool(forKey: Key.disclaimerAccepted)
        let raw = defaults.string(forKey: Key.appearance) ?? AppearanceMode.system.rawValue
        _appearance = AppearanceMode(rawValue: raw) ?? .system
        if let data = defaults.data(forKey: Key.settings),
           let decoded = try? JSONDecoder().decode(ArchiveSettings.self, from: data) {
            _archiveSettings = decoded
        } else {
            _archiveSettings = ArchiveSettings()
        }
    }

    @Published var hasAcceptedDisclaimer: Bool {
        didSet { defaults.set(hasAcceptedDisclaimer, forKey: Key.disclaimerAccepted) }
    }

    @Published var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    @Published var archiveSettings: ArchiveSettings {
        didSet {
            if let data = try? JSONEncoder().encode(archiveSettings) {
                defaults.set(data, forKey: Key.settings)
            }
        }
    }
}
