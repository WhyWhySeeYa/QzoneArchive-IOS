//
//  MainView.swift
//  QzoneArchive
//
//  主框架: 侧边栏导航 + 页面容器
//

import SwiftUI

struct MainView: View {
    @EnvironmentObject var environment: AppEnvironment
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: TabItem = .dashboard
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationTitle("QQ空间归档")
                .navigationBarTitleDisplayMode(.inline)
        } detail: {
            detailView
                .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            environment.refreshLoginState { _ in }
            selectedTab = .dashboard
        }
        .alert("登录状态已失效", isPresented: Binding(
            get: { false },
            set: { _ in }
        )) {
            Button("重新登录") { appState.resetDisclaimer() }
        } message: {
            Text("归档任务已停止，已保存的数据不会丢失。")
        }
    }

    private var sidebar: some View {
        List(TabItem.allCases, selection: $selectedTab) { item in
            NavigationLink(value: item) {
                Label {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: item.icon)
                        .foregroundColor(selectedTab == item ? .accentColor : .secondary)
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .dashboard: DashboardView()
        case .archives: ArchiveListView()
        case .media: MediaLibraryView()
        case .contacts: ContactsView()
        case .tasks: TasksView()
        case .settings: SettingsView()
        }
    }
}

/// 主导航项
enum TabItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case archives
    case media
    case contacts
    case tasks
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "概览"
        case .archives: return "归档库"
        case .media: return "媒体库"
        case .contacts: return "互动排行"
        case .tasks: return "任务"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "chart.pie.fill"
        case .archives: return "folder.fill"
        case .media: return "photo.on.rectangle.angled"
        case .contacts: return "person.2.fill"
        case .tasks: return "arrow.triangle.2.circlepath"
        case .settings: return "gearshape.fill"
        }
    }
}

#Preview {
    MainView()
        .environmentObject(AppEnvironment.live())
        .environmentObject(AppState(environment: AppEnvironment.live()))
}
