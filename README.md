<p align="center">
  <img src="Resources/AppIcon-1024.png" width="128" height="128" alt="Codex Usage Bar icon">
</p>

<h1 align="center">Codex Usage Bar</h1>

<p align="center">在 macOS 菜单栏和 Touch Bar 中直接查看 Codex 与 Claude 剩余用量。</p>

<p align="center"><a href="README_EN.md">English</a> · <a href="CHANGELOG.md">更新记录</a> · <a href="CONTRIBUTING.md">参与贡献</a></p>

> [!IMPORTANT]
> 这是一个非官方的社区项目，与 OpenAI 或 Anthropic 没有隶属、赞助或背书关系。Codex 的本地 app-server 接口、Claude 的用量接口及 Touch Bar 常驻接口都可能随系统或客户端更新而变化。

## 功能

- 菜单栏同时显示 5 小时与每周剩余额度，可选择显示 Codex 或 Claude。
- 同时支持 Codex 与 Claude：Claude 用量来自本机已登录的 Claude Code，并包含 Opus、Sonnet 等按模型划分的每周额度。
- 原生 macOS 菜单展示进度、重置时间、积分和重置次数。
- 菜单栏图标、图标大小和文字字号可配置。
- 默认跟随系统语言，并可在设置中切换简中、繁中、英文、日文、韩文和西班牙文。
- 支持登录时自动启动；Codex 每分钟刷新，Claude 最多每 5 分钟请求一次。
- 在带 Touch Bar 的 MacBook Pro 上显示进度、百分比和重置时间，可同时显示两个来源。
- Codex 位于前台时可自动显示 Touch Bar 用量界面。
- 不依赖第三方库，不需要单独填写 API Key。

## 系统要求

- macOS 14.0 或更高版本。
- Codex 用量需要已安装并登录 Codex 桌面客户端；应用也会尝试查找常见路径下的 `codex` 可执行文件。
- Claude 用量需要本机已登录 Claude Code（命令行或 VS Code 扩展均可）。两个来源都可在设置中单独开关，只装其中一个也能使用。
- Touch Bar 功能需要配备 Touch Bar 的 Mac。其他 Mac 可正常使用菜单栏功能。

## 安装

### 从 GitHub Release 安装

1. 下载最新的 `Codex-Usage-Bar-v*.zip`。
2. 解压并将 `Codex Usage Bar.app` 移至 `/Applications`。
3. 首次启动若被 Gatekeeper 阻止，请在“系统设置 → 隐私与安全性”中确认打开。

未经 Developer ID 签名与公证的社区构建可能显示额外的安全提示。请仅下载你信任的构建。

### 从源码构建

```bash
git clone https://github.com/hoover91125/codex-usage-bar.git
cd codex-usage-bar
./build-app.sh dist
open "dist/Codex Usage Bar.app"
```

默认构建同时包含 `arm64` 和 `x86_64`。仅构建当前架构时：

```bash
CODEX_USAGE_ARCHS="$(uname -m)" ./build-app.sh dist
```

## 使用

启动后，菜单栏显示：

```text
5小时剩余% · 每周剩余%
```

点击菜单栏项目可查看两个来源的详细进度、重置时间、积分信息并手动刷新。菜单栏标题显示哪个来源可在设置中切换。右下角齿轮按钮打开设置页。

### Touch Bar

设置页中可以控制：

- 是否显示 Touch Bar Usage 信息；
- 显示 Codex、Claude 还是两者，以及两者同时显示时的紧凑布局；
- Codex 位于前台时是否自动显示。

普通 Touch Bar 内容使用公开的 `NSTouchBar` API。“Codex 前台时自动显示”需要调用未公开的 AppKit 系统模态 selector，并通过运行时检查后才会启用。这意味着：

- 该功能不适用于 Mac App Store 分发；
- macOS 更新后可能失效；
- 不支持时应用会自动退回普通 Touch Bar 模式，不影响菜单栏功能。

详见 [Touch Bar 实现说明](docs/TOUCH_BAR.md)。

## 数据来源与隐私

### Codex

应用在本机启动 Codex 自带的：

```text
codex app-server --stdio
```

并发送只读的 `account/rateLimits/read` 请求。应用不会读取或保存登录 Cookie、访问令牌、对话内容。

### Claude

Claude 用量来自本机 Claude Code 的登录状态：

1. 先读取 Claude Code 自己的配置文件 `~/.claude.json` 中缓存的用量（`cachedUsageUtilization`），只读不写。只要这份缓存不超过 5 分钟，就不发出任何请求。
2. 缓存过期时，从 macOS 钥匙串的 `Claude Code-credentials` 项（或 `~/.claude/.credentials.json`）读取 Claude Code 的访问令牌，向 `https://api.anthropic.com/api/oauth/usage` 发送一次只读请求。令牌仅在这次请求期间保存在内存中，不会写入磁盘或日志，也不会读取刷新令牌。

该接口按账号限流，额度与 Claude Code 本身以及其他使用同一接口的工具共享。收到 HTTP 429 后应用会先等待 5 分钟，之后每次连续 429 翻倍，最长 1 小时。

应用不包含遥测或第三方分析服务。点击“官方 Usage”时才会由系统浏览器打开对应的用量页面。完整说明见 [隐私说明](docs/PRIVACY.md)。

## 开发

```bash
swift build
swift build -c release
./scripts/release.sh
```

应用内置只读自检：

```bash
"dist/Codex Usage Bar.app/Contents/MacOS/CodexUsageBar" --self-test
```

架构和数据流见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 发布签名

`build-app.sh` 默认使用 ad-hoc 签名。若要公开分发，可指定 Developer ID：

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
  ./scripts/release.sh
```

公证凭据由发布者自行配置；不要将证书、密码或公证凭据提交到仓库。

## 已知限制

- Codex app-server 当前不是面向第三方应用承诺稳定性的公开接口。
- 应用只能显示当前本机已登录的 Codex / Claude Code 账户的额度。
- Claude 的用量接口未公开且按账号限流；如果本机还有其他工具在轮询同一接口，应用可能暂时拿不到新数据，此时会保留上一次的结果并自动退避。
- Touch Bar 常驻功能使用未公开接口，兼容性无法保证。
- 本项目不能发布到 Mac App Store。

## 许可证

代码和原创项目资源采用 [MIT License](LICENSE)。商标说明见 [NOTICE.md](NOTICE.md)。
