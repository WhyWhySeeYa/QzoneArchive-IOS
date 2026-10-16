//
//  OnboardingView.swift
//  QzoneArchive
//
//  首次启动的免责声明与账号登录
//

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var appState: AppState
    @State private var step = 0
    @State private var qrImage: UIImage?
    @State private var statusMessage = "正在获取登录二维码…"
    @State private var isRefreshing = false
    @State private var showLoginError = false
    @State private var loginErrorText = ""

    var body: some View {
        ZStack {
            background
            if step == 0 {
                disclaimer
            } else {
                login
            }
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [Color(.sRGB, red: 0.06, green: 0.10, blue: 0.16), Color(.sRGB, red: 0.02, green: 0.03, blue: 0.05)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    // MARK: - 免责声明

    private var disclaimer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "archivebox.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(Color(red: 0.15, green: 0.62, blue: 1.0))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("QQ空间归档")
                            .font(.title2.weight(.bold))
                            .foregroundColor(.white)
                        Text("把动态、照片、视频与互动记录安全归档到 iPhone")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                disclaimerSection(
                    title: "用途说明",
                    body: "本工具用于备份你自己账号可见的 QQ 空间内容，包括本人动态、好友可见动态、照片、视频、评论与点赞记录。全部数据保存在你的 iPhone 本地沙盒内，不会上传到任何服务器。"
                )
                disclaimerSection(
                    title: "账号与安全",
                    body: "登录通过 QQ 官方二维码接口完成，凭证仅保存在系统 Keychain 中，App 不会记录你的 QQ 密码。请勿将本工具用于他人账号。"
                )
                disclaimerSection(
                    title: "使用风险",
                    body: "归档需要访问 QQ 空间接口，请遵守腾讯服务协议。请设置合理的请求间隔，避免对服务造成压力。频繁请求可能导致账号被临时限制。"
                )
                disclaimerSection(
                    title: "免责声明",
                    body: "本工具仅供个人数据备份与学习研究使用，不提供任何担保。因使用本工具导致的账号风险、数据丢失或服务限制，由使用者自行承担。"
                )

                Button {
                    step = 1
                    startLogin()
                } label: {
                    Text("我已阅读并同意，开始登录")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .background(Color(red: 0.15, green: 0.62, blue: 1.0))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(24)
        }
    }

    private func disclaimerSection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
            Text(body)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 登录

    private var login: some View {
        VStack(spacing: 24) {
            Text("扫码登录 QQ 空间")
                .font(.title3.weight(.bold))
                .foregroundColor(.white)

            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white)
                    .frame(width: 232, height: 232)
                if let qrImage {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 210, height: 210)
                } else {
                    ProgressView()
                }
            }

            Text(statusMessage)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if isRefreshing {
                ProgressView()
            } else {
                Button("刷新二维码") { startLogin() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Color(red: 0.15, green: 0.62, blue: 1.0))
            }
        }
        .padding(24)
        .alert("登录失败", isPresented: $showLoginError) {
            Button("重试", action: startLogin)
            Button("返回", role: .cancel) { step = 0 }
        } message: {
            Text(loginErrorText)
        }
    }

    // MARK: - 逻辑

    private func startLogin() {
        Task {
            isRefreshing = true
            statusMessage = "正在获取登录二维码…"
            do {
                let imageData = try await environment.session.startQRLogin()
                await MainActor.run {
                    qrImage = UIImage(data: imageData)
                    statusMessage = "请使用手机 QQ 扫描二维码"
                }
                await poll()
            } catch {
                await MainActor.run {
                    isRefreshing = false
                    statusMessage = error.localizedDescription
                    showLoginError = true
                    loginErrorText = error.localizedDescription
                }
            }
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            do {
                let status = try await environment.session.pollQRLogin()
                let kind = status.status
                let message = status.message
                await MainActor.run {
                    switch kind {
                    case .waiting:
                        statusMessage = "请使用手机 QQ 扫描二维码"
                    case .scanned:
                        statusMessage = "已扫码，请在手机上确认登录"
                    case .expired:
                        isRefreshing = false
                        statusMessage = "二维码已失效，请点击刷新"
                    case .success:
                        if let account = environment.sessionAccount {
                            environment.handleLoginSuccess(account)
                        }
                        appState.acceptDisclaimer()
                        appState.isLoggedIn = true
                    case .error:
                        statusMessage = message
                    case .loggedOut:
                        break
                    }
                }
                if kind == .expired || kind == .success { return }
            } catch {
                await MainActor.run {
                    isRefreshing = false
                    showLoginError = true
                    loginErrorText = error.localizedDescription
                }
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}
