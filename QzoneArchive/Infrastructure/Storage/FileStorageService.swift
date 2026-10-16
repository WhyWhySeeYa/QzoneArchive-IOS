//
//  FileStorageService.swift
//  QzoneArchive
//
//  文件系统: 沙盒目录, 媒体缓存, 导出与日志目录
//

import Foundation

/// 沙盒文件管理
final class FileStorageService {
    private let fileManager = FileManager.default

    /// 数据根目录: AppData
    lazy var appDataRoot: URL = {
        let url = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppData", isDirectory: true)
        ensureDirectory(url)
        return url
    }()

    lazy var databaseDirectory: URL = {
        let url = appDataRoot.appendingPathComponent("Database", isDirectory: true)
        ensureDirectory(url)
        return url
    }()

    lazy var imagesRoot: URL = {
        let url = appDataRoot.appendingPathComponent("Media/Images", isDirectory: true)
        ensureDirectory(url)
        return url
    }()

    lazy var videosRoot: URL = {
        let url = appDataRoot.appendingPathComponent("Media/Videos", isDirectory: true)
        ensureDirectory(url)
        return url
    }()

    lazy var exportsDirectory: URL = {
        let url = appDataRoot.appendingPathComponent("Exports", isDirectory: true)
        ensureDirectory(url)
        return url
    }()

    lazy var logsDirectory: URL = {
        let url = appDataRoot.appendingPathComponent("Logs", isDirectory: true)
        ensureDirectory(url)
        return url
    }()

    lazy var tempDirectory: URL = {
        let url = appDataRoot.appendingPathComponent("Temp", isDirectory: true)
        ensureDirectory(url)
        return url
    }()

    /// 数据库文件路径
    var databaseURL: URL {
        databaseDirectory.appendingPathComponent("qzonearchive.sqlite3")
    }

    /// 某个账号的图片目录
    func imageDirectory(uin: String) -> URL {
        ensureDirectory(imagesRoot.appendingPathComponent(uin, isDirectory: true))
    }

    /// 视频目录
    func videoDirectory() -> URL {
        ensureDirectory(videosRoot)
    }

    /// 目录字节数
    func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// 设备可用空间
    var availableDiskSpace: Int64 {
        (try? fileManager.attributesOfFileSystem(forPath: appDataRoot.path)[.systemFreeSize] as? Int64) ?? 0
    }

    /// 清空所有本地数据
    func clearAllData() throws {
        try? fileManager.removeItem(at: imagesRoot)
        try? fileManager.removeItem(at: videosRoot)
        try? fileManager.removeItem(at: exportsDirectory)
        try? fileManager.removeItem(at: tempDirectory)
        try? fileManager.removeItem(at: databaseURL)
        for suffix in ["-wal", "-shm"] {
            try? fileManager.removeItem(at: databaseURL.appendingPathExtension(suffix))
        }
        ensureDirectory(imagesRoot)
        ensureDirectory(videosRoot)
        ensureDirectory(exportsDirectory)
        ensureDirectory(tempDirectory)
    }

    /// 确保目录存在
    @discardableResult
    func ensureDirectory(_ url: URL) -> URL {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// 原子写入: 先写临时文件再改名
    func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = tempDirectory.appendingPathComponent(UUID().uuidString + ".part")
        try data.write(to: temporary)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: temporary, to: url)
    }
}
