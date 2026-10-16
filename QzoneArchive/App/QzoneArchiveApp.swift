//
//  QzoneArchiveApp.swift
//  QzoneArchive
//
//  应用入口: 组装依赖环境, 决定首屏展示免责声明还是主界面
//

import SwiftUI

@main
struct QzoneArchiveApp: App {
    @StateObject private var environment: AppEnvironment
    @StateObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let environment = AppEnvironment.live()
        let appState = AppState(environment: environment)
        _environment = StateObject(wrappedValue: environment)
        _appState = StateObject(wrappedValue: appState)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.hasAcceptedDisclaimer {
                    MainView()
                        .environmentObject(environment)
                        .environmentObject(appState)
                } else {
                    OnboardingView()
                        .environmentObject(environment)
                        .environmentObject(appState)
                }
            }
            .preferredColorScheme(appState.preferredColorScheme)
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    appState.handleAppBecameActive()
                case .background:
                    appState.handleAppEnteredBackground()
                default:
                    break
                }
            }
        }
    }
}
