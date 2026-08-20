# Pulse iOS

Pulse 是原生 SwiftUI 客户端，已连通 Go API 的发现、点赞、评论、底部“一句话创作”、基于现有作品的 Remix、素材登记、生成进度、Plan 查看、验收结果、预览发布、个人作品和公开分享。

## 运行

先启动 `/Users/bytedance/Documents/Pulse/pulse-api`，再生成 Xcode 工程：

```bash
brew install xcodegen
xcodegen generate
open Pulse.xcodeproj
```

选择 iPhone Simulator 运行。部署目标是 iOS 17；本地 API 默认为 `http://localhost:8787`。命令行编译校验：

```bash
xcodebuild -project Pulse.xcodeproj -scheme Pulse -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## 核心边界

- `App`：导航与跨页面状态。
- `Domain`：服务端 DTO、原创/Remix 血缘、生成阶段和 `PulseAPIClient`。
- `Features/Feed`：全屏互动 Feed、点赞和评论。
- `Features/Composer`：原创与 Remix 共用的创作、Plan、生成、验收与发布流程。
- `Features/Profile`：当前用户作品状态。
- `web-player`：公开作品宿主页；按 `/a/:slug` 从 Go API 读取已发布作品。

原创只能从底部 Create 入口发起且不携带父作品；Remix 只能从现有作品发起。二者都调用同一 Go 生成状态机，客户端不推导血缘也不决定验证终态。

## Web Player

```bash
cd web-player
npm install
npm run dev
```

打开 `http://localhost:8080/a/{publicSlug}`。可用 `?api=http://localhost:8787` 覆盖本地 API Origin。

页面验收依据见 [客户端页面设计 PRD](docs/Pulse客户端页面设计PRD.md)。
