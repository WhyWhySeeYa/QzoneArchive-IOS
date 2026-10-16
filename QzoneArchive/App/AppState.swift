//
//  AppState.swift
//  QzoneArchive
//
//  全局应用状态: 免责声明, 登录态, 任务恢复, 主题
//

import Foundation
import SwiftUI

/// 应用级可观察状态
@MainActor
final class AppState: ObservableObject {
    @Published var hasAcceptedDisclaimer: Bool
    @Published var isLoggedIn: Bool = false
    @Published var account: Account?
    @Published var restoredTaskNotice: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        self.hasAcceptedDisclaimer = environment.settings.hasAcceptedDisclaimer
    }

    /// 接受免责声明
    func acceptDisclaimer() {
        environment.settings.hasAcceptedDisclaimer = true
        hasAcceptedDisclaimer = true
    }

    /// 重新查看免责声明后关闭
    func resetDisclaimer() {
        environment.settings.hasAcceptedDisclaimer = false
        hasAcceptedDisclaimer = false
    }

    var preferredColorScheme: ColorScheme? {
        environment.settings.appearance == .dark ? .dark : (environment.settings.appearance == .light ? .light : nil)
    }

    /// 应用进入前台: 刷新登录态并尝试恢复未完成任务
    func handleAppBecameActive() {
        environment.refreshLoginState { [weak self] account in
            self?.account = account
            self?.isLoggedIn = account != nil
        }
        environment.resumeInterruptedTaskIfNeeded { [weak self] notice in
            self?.restoredTaskNotice = notice
        }
    }

    /// 应用进入后台: 立即持久化任务进度
    func handleAppEnteredBackground() {
        environment.persistRunningTaskForBackground()
    }
}
