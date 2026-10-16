//
//  Account.swift
//  QzoneArchive
//
//  账号模型
//

import Foundation

/// 本地账号记录, Cookie 与 Token 不在此结构内
struct Account: Identifiable, Codable, Equatable {
    var id: UUID
    var qqUin: String
    var nickname: String?
    var avatarURL: String?
    var lastLoginAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var isActive: Bool

    init(
        id: UUID = UUID(),
        qqUin: String,
        nickname: String? = nil,
        avatarURL: String? = nil,
        lastLoginAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isActive: Bool = true
    ) {
        self.id = id
        self.qqUin = qqUin
        self.nickname = nickname
        self.avatarURL = avatarURL
        self.lastLoginAt = lastLoginAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isActive = isActive
    }
}
