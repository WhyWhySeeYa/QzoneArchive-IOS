# QzoneArchive iOS

QQ 空间历史内容本地归档工具 iOS 原生版，按 PRD 从桌面端
[JularDepick/QzoneArchive.fork](https://github.com/JularDepick/QzoneArchive.fork) 复刻。

SwiftUI + MVVM + Repository，无第三方运行时依赖，直接调用 `mobile.qzone.qq.com/get_feeds`。

## 功能

- **二维码登录**：`ptqrshow` 生成二维码 + `ptqrtoken` 轮询 + `check_sig` 换取 `p_skey`/`uin`
- **全量归档**：以 `res_attach` 游标翻页，断点续传；频率保护 + 自动暂停恢复
- **媒体下载**：图片/视频按页串行下载，断点续传，离线可看
- **本地查询**：全文检索、分类筛选、互动排行
- **HTML 导出**：单文件导出，含媒体与互动统计
- **数据管理**：按条删除、按分类清空、清空全部数据

## 工程结构

```
QzoneArchive/
├── App/                    # 入口、依赖容器、全局状态
├── Domain/
│   ├── Models/             # 动态、媒体、评论、点赞、任务
│   └── Parsing/            # 互动数据解析、翻页游标
├── Infrastructure/
│   ├── Authentication/     # 登录原语、登录会话、凭据保管
│   ├── Network/            # get_feeds 客户端（重试与退避）
│   ├── Persistence/        # SQLite 数据库
│   └── Storage/            # 文件路径、设置、日志
├── Data/Repositories/      # 归档引擎、仓库、媒体下载、导出
├── Presentation/ViewModels/
└── Features/               # 六个主界面 + 免责声明
Tests/                      # 登录原语 / 解析 / 游标 / 仓库单元测试
```

与桌面端的对应关系：

| iOS | 桌面端 |
| --- | --- |
| `QzoneLoginPrimitives` | `core/loginPrimitives.ts` |
| `LoginSession` | `core/login.ts` |
| `QzoneAPIClient` | `core/qzoneClient.ts` |
| `FeedParser` | `core/archiveParser.ts` |
| `FeedCursor` | `core/feedCursor.ts` |
| `ArchiveEngine` | `core/archiveEngine.ts` |
| `ArchiveDatabase` / `ArchiveRepository` | `core/archiveDb.ts` |
| `MediaDownloadManager` | `core/archiveMedia.ts` |
| `ExportService` | `core/archiveExport.ts` |

## 用 GitHub Actions 编译

仓库已内置 `.github/workflows/build-ios.yml`，推送到 GitHub 后：

1. 打开仓库 **Actions** 页 → 选择 **Build iOS**
2. 点 **Run workflow**（push 到 main 也会自动触发）
3. 等 macOS runner 跑完，下载 `QzoneArchive-unsigned` 制品

产物是未签名的 `.ipa`（模拟器 SDK 构建），可自行重签名或改用设备证书签名。

本地开发：

```sh
brew install xcodegen
xcodegen generate
open QzoneArchive.xcodeproj
```

## 测试

```sh
xcodebuild test -project QzoneArchive.xcodeproj -scheme QzoneArchive \
  -destination 'generic/platform=iOS Simulator'
```

## 免责声明

本项目仅用于个人数据的本地备份与查看。请在登录前阅读应用内免责声明，
并遵守 QQ 空间服务条款与当地法律法规。
