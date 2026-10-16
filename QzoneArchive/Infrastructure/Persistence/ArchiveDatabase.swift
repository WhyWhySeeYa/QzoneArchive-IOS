//
//  ArchiveDatabase.swift
//  QzoneArchive
//
//  本地数据库: SQLite (FMDB) 封装
//

import Foundation
import SQLite3
/// 数据库错误
enum DatabaseError: Error {
    case openFailed(String)
    case execFailed(String)
}

/// 归档数据库, 使用系统 SQLite3
final class ArchiveDatabase {
    private var handle: OpaquePointer?
    private let storage: FileStorageService
    private let logger = AppLogger()
    private let queue = DispatchQueue(label: "com.minis.QzoneArchive.db")

    init(storage: FileStorageService = FileStorageService()) {
        self.storage = storage
    }

    deinit {
        close()
    }

    // MARK: - 连接管理

    /// 打开数据库并建表
    func open() throws {
        queue.sync {
            guard handle == nil else { return }
            let url = storage.databaseURL
            storage.ensureDirectory(storage.databaseDirectory)
            var db: OpaquePointer?
            if sqlite3_open(url.path, &db) != SQLITE_OK {
                let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                sqlite3_close(db)
                logger.error("打开数据库失败: \(message)")
                throw DatabaseError.openFailed(message)
            }
            handle = db
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
            do {
                try createSchema()
            } catch {
                logger.error("建表失败: \(error.localizedDescription)")
                throw error
            }
        }
    }

    /// 关闭数据库
    func close() {
        queue.sync {
            guard let db = handle else { return }
            sqlite3_close(db)
            handle = nil
        }
    }

    private var currentHandle: OpaquePointer? {
        if handle == nil { try? open() }
        return handle
    }

    // MARK: - Schema

    private func createSchema() throws {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS accounts (
                id TEXT PRIMARY KEY,
                qq_uin TEXT UNIQUE NOT NULL,
                nickname TEXT,
                avatar_url TEXT,
                last_login_at REAL,
                created_at REAL,
                updated_at REAL,
                is_active INTEGER DEFAULT 1
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS archive_posts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL,
                source_id TEXT NOT NULL,
                author_uin TEXT,
                author_name TEXT,
                content_text TEXT,
                published_at REAL,
                archived_at REAL,
                post_type TEXT,
                source_url TEXT,
                raw_payload_path TEXT,
                is_deleted INTEGER DEFAULT 0,
                picture_urls_json TEXT,
                video_urls_json TEXT,
                video_cover_url TEXT,
                like_count INTEGER DEFAULT 0,
                comment_count INTEGER DEFAULT 0,
                category TEXT DEFAULT 'self',
                created_at REAL,
                updated_at REAL,
                UNIQUE(account_id, source_id)
            );
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_posts_account_category
              ON archive_posts(account_id, category, published_at);
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_posts_account_source
              ON archive_posts(account_id, source_id);
            """,
            """
            CREATE TABLE IF NOT EXISTS media_assets (
                id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL,
                post_id TEXT,
                remote_url TEXT,
                local_relative_path TEXT,
                media_type TEXT,
                mime_type TEXT,
                file_size INTEGER,
                sha256 TEXT,
                width INTEGER,
                height INTEGER,
                download_state TEXT DEFAULT 'pending',
                retry_count INTEGER DEFAULT 0,
                error_message TEXT,
                created_at REAL,
                updated_at REAL
            );
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_media_account_post
              ON media_assets(account_id, post_id);
            """,
            """
            CREATE TABLE IF NOT EXISTS comments (
                id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL,
                post_id TEXT,
                parent_id TEXT,
                author_uin TEXT,
                author_name TEXT,
                content_text TEXT,
                published_at REAL,
                created_at REAL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS likes (
                id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL,
                post_id TEXT,
                author_uin TEXT,
                author_name TEXT,
                created_at REAL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS archive_tasks (
                id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL,
                task_type TEXT,
                status TEXT DEFAULT 'pending',
                cursor TEXT,
                current_page INTEGER DEFAULT 0,
                discovered_count INTEGER DEFAULT 0,
                saved_count INTEGER DEFAULT 0,
                skipped_count INTEGER DEFAULT 0,
                failed_count INTEGER DEFAULT 0,
                downloaded_count INTEGER DEFAULT 0,
                started_at REAL,
                finished_at REAL,
                last_error TEXT,
                created_at REAL,
                updated_at REAL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS task_failures (
                id TEXT PRIMARY KEY,
                task_id TEXT NOT NULL,
                account_id TEXT NOT NULL,
                resource_type TEXT,
                resource_id TEXT,
                error_code TEXT,
                error_message TEXT,
                retry_count INTEGER DEFAULT 0,
                resolved INTEGER DEFAULT 0,
                created_at REAL,
                updated_at REAL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS archive_skips (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL,
                page_number INTEGER,
                cursor_offset INTEGER,
                offset_advance INTEGER,
                base_time INTEGER,
                error TEXT,
                skipped_at REAL,
                retry_count INTEGER DEFAULT 0,
                last_retry_at REAL,
                resolved_at REAL,
                recovered_records INTEGER DEFAULT 0,
                cursor TEXT
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS archive_checkpoints (
                account_id TEXT PRIMARY KEY,
                attach_info TEXT,
                pages INTEGER DEFAULT 0,
                fetched INTEGER DEFAULT 0,
                saved INTEGER DEFAULT 0,
                updated_at REAL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS archive_rate_limits (
                account_id TEXT PRIMARY KEY,
                window_started_at REAL,
                pages INTEGER DEFAULT 0,
                retry_at REAL
            );
            """,
        ]
        for statement in statements {
            if sqlite3_exec(handle, statement, nil, nil, nil) != SQLITE_OK {
                let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                throw DatabaseError.execFailed(message)
            }
        }
    }

    // MARK: - 执行

    /// 执行写入语句, 返回受影响行数
    @discardableResult
    func executeUpdate(_ sql: String, arguments: [Any?]) throws -> Int {
        try queue.sync {
            guard let db = currentHandle else { throw DatabaseError.openFailed("数据库未打开") }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, arguments)
            let status = sqlite3_step(statement)
            if status != SQLITE_DONE && status != SQLITE_ROW {
                throw DatabaseError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
            return Int(sqlite3_changes(db))
        }
    }

    /// 查询, 返回字典数组
    func executeQuery(_ sql: String, arguments: [Any?]) throws -> [[String: Any]] {
        try queue.sync {
            guard let db = currentHandle else { throw DatabaseError.openFailed("数据库未打开") }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw DatabaseError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, arguments)
            var rows: [[String: Any]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                var row: [String: Any] = [:]
                let columnCount = sqlite3_column_count(statement)
                for index in 0..<columnCount {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    let type = sqlite3_column_type(statement, index)
                    switch type {
                    case SQLITE_INTEGER:
                        row[name] = sqlite3_column_int64(statement, index)
                    case SQLITE_FLOAT:
                        row[name] = sqlite3_column_double(statement, index)
                    case SQLITE_TEXT:
                        row[name] = String(cString: sqlite3_column_text(statement, index))
                    case SQLITE_BLOB:
                        if let bytes = sqlite3_column_blob(statement, index) {
                            let count = sqlite3_column_bytes(statement, index)
                            row[name] = Data(bytes: bytes, count: Int(count))
                        } else {
                            row[name] = NSNull()
                        }
                    default:
                        row[name] = NSNull()
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    /// 在事务中执行多个写入
    func inTransaction(_ block: () throws -> Void) throws {
        try queue.sync {
            guard let db = currentHandle else { throw DatabaseError.openFailed("数据库未打开") }
            if sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) != SQLITE_OK {
                throw DatabaseError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
            do {
                try block()
                if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                    throw DatabaseError.execFailed(String(cString: sqlite3_errmsg(db)))
                }
            } catch {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    // MARK: - 参数绑定

    private func bind(_ statement: OpaquePointer?, _ arguments: [Any?]) {
        for (index, argument) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch argument {
            case nil:
                sqlite3_bind_null(statement, position)
            case let value as String:
                sqlite3_bind_text(statement, position, value, -1, nil)
            case let value as Int:
                sqlite3_bind_int64(statement, position, Int64(value))
            case let value as Int64:
                sqlite3_bind_int64(statement, position, value)
            case let value as Double:
                sqlite3_bind_double(statement, position, value)
            case let value as Bool:
                sqlite3_bind_int64(statement, position, value ? 1 : 0)
            case let value as Date:
                sqlite3_bind_double(statement, position, value.timeIntervalSince1970)
            case let value as Data:
                value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(value.count), nil)
                }
            case let value as UUID:
                sqlite3_bind_text(statement, position, value.uuidString, -1, nil)
            default:
                sqlite3_bind_text(statement, position, String(describing: argument ?? ""), -1, nil)
            }
        }
    }
}

extension ArchiveDatabase {
    /// 删除全部业务表并重建空表结构
    func resetDatabase() throws {
        close()
        let tables = [
            "archive_posts", "media_assets", "comments", "likes",
            "archive_tasks", "task_failures", "archive_skips",
            "archive_checkpoints", "archive_rate_limits",
        ]
        for table in tables {
            try executeUpdate("DROP TABLE IF EXISTS \(table)", arguments: [])
        }
        try open()
    }
}
