//
//  ContactsView.swift
//  QzoneArchive
//
//  互动排行: 谁给你的动态点过赞, 留过言
//

import SwiftUI

struct ContactsView: View {
    @EnvironmentObject var environment: AppEnvironment
    @State private var ranking: [InteractionRank] = []
    @State private var isLoading = false
    @State private var expandedUin: String?

    var body: some View {
        List {
            Section {
                Text("统计来自已归档动态的点赞与评论记录")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if isLoading {
                ProgressView()
            } else if ranking.isEmpty {
                Text("暂无互动记录")
                    .foregroundColor(.secondary)
            } else {
                ForEach(ranking) { item in
                    row(item)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("互动排行")
        .onAppear { Task { await load() } }
        .refreshable { await load() }
    }

    private func row(_ item: InteractionRank) -> some View {
        Button {
            expandedUin = expandedUin == item.uin ? nil : item.uin
        } label: {
            HStack(spacing: 12) {
                Text(item.nickname.isEmpty ? "QQ\(item.uin)" : item.nickname)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("共 \(item.interactions) 次")
                        .font(.caption.monospacedDigit())
                    HStack(spacing: 8) {
                        Label("\(item.likes)", systemImage: "hand.thumbsup")
                        Label("\(item.comments)", systemImage: "bubble.right")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        guard let account = environment.sessionAccount else { return }
        isLoading = true
        let database = environment.database
        let result = await Task.detached(priority: .userInitiated) {
            let repo = SQLiteArchiveRepository(database: database)
            return (try? repo.interactionRanking(account: account, limit: 100)) ?? []
        }.value
        self.ranking = result
        self.isLoading = false
    }
}
