# Pulse iOS

Pulse 是原生 SwiftUI 客户端，已连通 Go API 的发现、点赞、评论、底部“一句话创作”、基于现有作品的 Remix、官方公共/用户私有资源库、图片与 BGM 选择、阿里云 OSS 短时签名直传、生成进度、Plan 查看、验收结果、Artifact 预览与 Feed 内游玩、发布、个人作品和公开分享。

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

## XCTest 自动化闭环

本机安装 Xcode 26.5 与 iOS 26.5 Simulator Runtime 后，执行：

```bash
scripts/run-xctest.sh
```

脚本会创建一次性 iPhone Simulator、生成 Xcode 工程、启动并等待模拟器、真实执行 XCTest、保存 `.xcresult`，最后关闭并删除测试设备。测试结果默认写入 `.artifacts/xctest/`；任一准备、编译、资源或 XCTest 断言失败都会返回非零状态。

GitHub Actions 使用 `.github/workflows/ios-xctest.yml` 运行同一个入口，固定选择 `macos-26`、Xcode 26.5 和 iOS 26.5 Runtime，并在成功或失败时上传 `.xcresult` 供诊断。

一句话生成的产品级黑盒验收使用独立 scheme，并且只允许真实 Coding Agent 模式。先通过安全运行环境注入兼容 Chat Completions 的模型配置和已构建的沙箱镜像，再执行：

```bash
export PULSE_MODEL_ENDPOINT=https://your-model-provider.example/v1/chat/completions
export PULSE_MODEL_NAME=your-model
export PULSE_MODEL_API_KEY=your-secret-from-a-secure-runtime
export PULSE_SANDBOX_IMAGE=pulse-agent-sandbox:v1
scripts/run-snake-generation-xcuitest.sh
```

脚本会启动隔离数据的 Go API，强制设置 `PULSE_AGENT_MODE=live`，输入“生成疯狂版本的贪吃蛇”，等待模型生成与沙箱验收，进入真实 Artifact Player 试玩，点击发布，再在 Feed 内验证 START、PAUSE/RESUME、方向控制和可观察画面变化。专项结果写入 `.artifacts/generation-xcuitest/`。缺少模型配置或沙箱镜像会立即失败；不会回退到 deterministic/fake 生成。

## 核心边界

- `App`：导航与跨页面状态。
- `Domain`：服务端 DTO、原创/Remix 血缘、生成阶段和 `PulseAPIClient`。
- `Features/Feed`：全屏互动 Feed、点赞和评论。
- `Features/Player`：基于 `WKWebView` 的 Artifact Player；使用非持久化数据存储、同 Artifact 目录导航白名单和服务端 CSP，在 Feed 与发布前预览中运行已验收 Bundle。
- `Features/Composer`：原创与 Remix 共用的公共/私有资源选择、私有图片/BGM 上传、Plan、生成、验收与发布流程。
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
