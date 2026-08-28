# Pulse iOS

Pulse 是原生 SwiftUI 客户端，已连通 Go API 的发现、点赞、评论、底部“一句话创作”、基于现有作品的 Remix、官方公共/用户私有资源库、图片与 BGM 选择、阿里云 OSS 短时签名直传、生成进度、Plan 查看、验收结果、Artifact 预览与 Feed 内游玩、发布、个人作品和公开分享。

## 运行

先启动 `/Users/bytedance/Documents/Pulse/pulse-api`，再生成 Xcode 工程：

```bash
brew install xcodegen
xcodegen generate
open Pulse.xcodeproj
```

选择 iPhone Simulator 运行。部署目标是 iOS 17；本地 API 默认为 `http://localhost:8787`。工程包含完整 iOS/iPad App Icon 集和 Sign in with Apple entitlement；必须在 Apple Developer 中为 `com.shikanon.pulse` 创建匹配的 App ID、能力与 provisioning profile。Associated Domains entitlement 已参数化，Release 默认使用 `.invalid` 安全占位；只有正式 HTTPS 域名、`apple-app-site-association` 和 Apple Developer capability 均验证后，才可向签名构建注入真实 Host。命令行编译校验：

```bash
xcodebuild -project Pulse.xcodeproj -scheme Pulse -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

首次启动会先请求 `GET /v1/client-configuration`，再恢复会话与加载 Feed。服务端维护、最低版本/build 或无法获取启动配置时，客户端只显示可理解的维护、升级或重试页，不会先进入内容。该启动配置由 API 部署环境中的 `PULSE_MAINTENANCE_*`、`PULSE_IOS_MINIMUM_*` 和外链 URL 变量提供；上线前必须接入受审计的远程配置发布、真实 App Store URL 与真机弱网验证。

Feed 成功读取后会保存最多 50 个公开作品的本地快照，最长保留 15 分钟。请求失败时，仍在有效期内的快照会显示明确的“saved copy”状态与重试操作；缓存不会保存 `viewerHasLiked` 等账号相关状态，且绑定 API Origin。超过有效期、损坏、跨环境或空 Feed 的快照会被拒绝或清除，不能用来绕过内容下架或线上访问控制。

## XCTest 自动化闭环

本机安装 Xcode 26.5 与 iOS 26.5 Simulator Runtime 后，执行：

```bash
scripts/run-xctest.sh
```

脚本会创建一次性 iPhone Simulator、生成 Xcode 工程、启动并等待模拟器、真实执行 XCTest、保存 `.xcresult`，最后关闭并删除测试设备。测试结果默认写入 `.artifacts/xctest/`；任一准备、编译、资源或 XCTest 断言失败都会返回非零状态。

GitHub Actions 使用 `.github/workflows/ios-xctest.yml` 运行同一个入口，固定选择 `macos-26`、Xcode 26.5 和 iOS 26.5 Runtime，并在成功或失败时上传 `.xcresult` 供诊断。该工作流还会以非占位 HTTPS API Origin 和 Associated Domains Host 生成并无签名编译 Release Simulator 配置，防止只在 Debug 构建中通过；它不替代真机 Archive、签名或 App Store Connect 上传。

不需要模型密钥的社区与深链 XCUITest 使用独立的临时开发 API 和 iPhone Simulator：

```bash
scripts/run-community-xcuitest.sh
```

该脚本固定占用本机 `18787` 端口（不会触碰常用的 `8787` 开发服务），创建临时数据和模拟器，并验证评论发布、作品举报确认及合法 `pulse://remix/{workId}` 恢复到 Remix 编辑器；结束后会递归清理临时 API 进程、数据和模拟器。结果写入 `.artifacts/community-xcuitest/`。端口已被占用时脚本会安全退出。

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
- `Features/Composer`：原创与 Remix 共用的公共/私有资源选择、带进度/取消/重试的私有上传、Plan、生成、验收与发布流程；生成可在服务端继续，前台恢复后刷新状态，取消和同输入重试均须经过服务端 Job 状态机。
- `Features/Profile`：当前用户作品状态、公开链接撤销与只读版本候选时间线；时间线只显示面向作者的生成结果状态，不显示 Prompt、素材或服务端诊断。
- `web-player`：公开作品宿主页；按 `/a/:slug` 从 Go API 读取已发布作品。

原创只能从底部 Create 入口发起且不携带父作品；Remix 只能从现有作品发起。二者都调用同一 Go 生成状态机，客户端不推导血缘也不决定验证终态。

Release 不再默认为 `localhost`，也不会读取进程环境覆盖 API Origin。`project.yml` 的 Release 默认值为 `configure-*.invalid`，因此未注入真实值的构建会在启动门禁中安全停止。归档/签名流水线必须在构建时设置同一受审计的 HTTPS 域名：

```bash
xcodebuild ... \
  PULSE_API_BASE_URL=https://api.your-approved-domain.tld/v1 \
  PULSE_UNIVERSAL_LINK_HOST=play.your-approved-domain.tld
```

`PULSE_UNIVERSAL_LINK_HOST` 同时写入 `PulseUniversalLinkHost` 和 Associated Domains entitlement。对应站点必须在 `https://<host>/.well-known/apple-app-site-association` 提供与 Apple Team ID、`com.shikanon.pulse` 及 `/a/*`、`/remix/*` 一致的文件，再以已安装/未安装、冷启动/已运行、撤销/失效链接的真机矩阵验证。链接解析只接受该构建期域名的 `/a/{publicSlug}` 和 `/remix/{workId}`，App 会再次请求 API 确认公开状态，不把失效链接导向 Feed 或创作。公开 Web Player 的 `pulse://report/{publicSlug}` 仅用于已安装 App 的举报回流，客户端会再次读取该 slug 对应的公开作品，确认仍公开后才显示现有举报表单；该自定义 scheme 不替代 Universal Link 的未安装商店兜底。

## Web Player

```bash
cd web-player
npm install
npm run dev
```

打开 `http://localhost:8080/a/{publicSlug}`。本地默认连接 `http://localhost:8787`；如需覆盖，启动 Vite 时设置 `VITE_PULSE_API_ORIGIN=http://localhost:8787`。生产构建必须注入 HTTPS 的 `VITE_PULSE_API_ORIGIN`，公开链接不会接受查询参数指定 API，以免被分享 URL 劫持数据源。

当准备与 iOS Release 一起发布 Universal Links 时，公开站点使用同一 `PULSE_UNIVERSAL_LINK_HOST`、Apple Team ID 和 Bundle ID 生成不带扩展名的 AASA 文件；这一步拒绝占位域名、端口、路径和不完整应用标识，避免手写 JSON 与 iOS entitlement 漂移：

```bash
PULSE_APPLE_TEAM_ID=ABCDE12345 \
PULSE_IOS_BUNDLE_ID=com.shikanon.pulse \
PULSE_UNIVERSAL_LINK_HOST=play.your-approved-domain.tld \
VITE_PULSE_API_ORIGIN=https://api.your-approved-domain.tld \
npm run build:release
```

构建产物会包含 `dist/.well-known/apple-app-site-association`，且只匹配 `/a/*` 和 `/remix/*`。部署必须让同一精确 HTTPS Host 在无重定向、有效证书下以 JSON 响应此路径；还需在正式安装的 Release 上通过 Apple Associated Domains CDN 与真机验证，生成文件本身不构成 Universal Links 已上线证据。

`.github/workflows/web-player-quality.yml` 在公开 Player 变更时以锁定依赖运行 Node 安全/契约测试、默认构建、带无占位测试域名的 Release+AASA 构建和高危依赖审计。该 CI 只能证明构建产物与门禁契约一致，不能替代真实域名、CDN、Apple CDN、移动浏览器或真机验证。

部署后使用同一组正式变量检查站点，不会跟随跳转，也会拒绝 MIME、App ID 或允许路径漂移：

```bash
PULSE_APPLE_TEAM_ID=YOURTEAMID \
PULSE_IOS_BUNDLE_ID=com.shikanon.pulse \
PULSE_UNIVERSAL_LINK_HOST=play.your-approved-domain.tld \
scripts/verify-associated-domains.sh
```

公开 Player 只加载服务端确认 `approved / 4+ / verified` 的同源 Artifact，宿主 iframe 保持 `sandbox="allow-scripts"`。页面对公开读取 `404/410/401/403`、`400/422` 和暂时性网络或服务错误分别展示不泄露审核原因的失效、不兼容和可重试状态，不显示上游错误文本；生成 Bundle 的交互逻辑必须使用同源外置脚本，以符合 Artifact `script-src 'self'` CSP。若公开 `/v1/client-configuration` 提供无凭据 HTTPS `privacyPolicyURL`，播放成功和失败状态都会显示 Privacy policy，缺失或不安全值不会阻塞作品也不会生成链接；配置的 `appStoreURL` 也只有在 `apps.apple.com` 或 `itunes.apple.com` 才显示为 Get Pulse。已加载的公开作品还提供 `pulse://report/{publicSlug}` 的 Report in Pulse 入口，App 会重新验证公开状态并要求登录后提交。页面还提供键盘 Skip link、动态内容可滚动详情卡、Reduce Motion 支持、浅色 Artifact 下保持可读的宿主品牌栏，以及明确的复制链接反馈。

### 动态分享预览

静态 Vite 页面不能让社交爬虫执行脚本后再读取作品资料。`web-player/edge-worker.mjs` 因此提供 Cloudflare Pages/Workers 适配器：已知社交或搜索爬虫访问 `/a/{slug}` 时，边缘层从同一 API 的公开作品接口读取数据，并仅为 `published + verified + approved + 4+` 的当前作品返回动态 Open Graph、Twitter、作者归因和 Remix 血缘元信息。普通浏览器请求仍透传到现有静态播放器，不会改为元数据页面。

`web-player/wrangler.example.jsonc` 说明所需的 `ASSETS` 绑定，以及精确 HTTPS 的 `PULSE_API_ORIGIN` 和 `PULSE_PUBLIC_PLAYER_ORIGIN`。边缘 HTML 仅使用 API 派生的公开字段，图片也只接受当前不可变 Artifact 的固定 `preview.png` 路径；撤销、隐藏、超龄或失效链接对爬虫返回 `404`、`noindex`、`private, no-store`，暂时故障返回无内容的 `503`。真实域名绑定、Cloudflare 部署、Slack/Discord/微信等实际预览与各平台自身缓存失效仍是发布门禁，不能由本地模拟替代。

页面验收依据见 [客户端页面设计 PRD](docs/Pulse客户端页面设计PRD.md)。
