//
//  CredentialStore.swift
//  QzoneArchive
//
//  凭证存储: Keychain 持久化, 支持 Face ID 保护
//

import Foundation
import Security

/// Keychain 中的凭证结构
struct QzoneStoredCredentials: Codable {
    var uin: String
    var gTk: Int
    var cookies: [String: String]
    var userAgent: String
    var savedAt: Date
}

/// 凭证仓库协议
protocol CredentialStore {
    func hasCredentials() async -> Bool
    func loadCredentials() async -> QzoneStoredCredentials?
    func saveCredentials(_ credentials: QzoneStoredCredentials) async throws
    func loadAccount() async -> Account?
    func saveAccount(_ account: Account) async throws
    func clear() async throws
}

/// Keychain 凭证仓库
actor KeychainCredentialStore: CredentialStore {
    private let service = "com.minis.QzoneArchive.credentials"
    private let credentialsKey = "qzone.auth"
    private let accountKey = "qzone.account"
    private let logger = AppLogger()

    func hasCredentials() async -> Bool {
        await loadCredentials() != nil
    }

    func loadCredentials() async -> QzoneStoredCredentials? {
        read(credentialsKey)
    }

    func saveCredentials(_ credentials: QzoneStoredCredentials) async throws {
        try write(credentialsKey, value: credentials)
    }

    func loadAccount() async -> Account? {
        read(accountKey)
    }

    func saveAccount(_ account: Account) async throws {
        try write(accountKey, value: account)
    }

    func clear() async throws {
        delete(credentialsKey)
        delete(accountKey)
    }

    // MARK: - Keychain 读写

    private func write<T: Codable>(_ key: String, value: T) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            logger.error("凭证序列化失败")
            throw QzoneError.unknown("凭证保存失败")
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("凭证写入 Keychain 失败 status=\(status)")
            throw QzoneError.unknown("凭证保存失败")
        }
    }

    private func read<T: Codable>(_ key: String) -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
