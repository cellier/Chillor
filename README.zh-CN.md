# Chillor

**[English](README.md) · 简体中文**

一款本地优先的 macOS AI 助手。你表达想完成的事情，Chillor 负责管理对话上下文、任务工作区、工具和记忆。

**目前为早期预览版，仍在持续开发。** 默认使用 Ollama + Qwen 在本机推理；也可在设置中主动选择 DeepSeek，此时相关上下文会发送到该服务。不会自动从本地推理切换到云端。

## 界面预览

### 在一个对话里整理想法

<img src="docs/public/media/conversation.png" alt="Chillor 原生对话界面，以读书分享会准备清单展示标题、列表和引用的排版" width="640">

### 搜索之前的内容

<img src="docs/public/media/search.png" alt="Chillor 会话搜索界面，输入读书后显示相关消息" width="640">

以上是当前源码构建的真实 macOS 界面截图。对话使用专门编写的示例内容，不含个人聊天记录；图片展示界面功能，不代表一次真实模型执行结果或速度测试。

## 已实现的功能

- **原生 macOS 体验**：SwiftUI / AppKit 界面、流式回复、历史搜索、文件预览，以及可配置的 Reply / Translate 快捷指令。
- **多步 Agent 执行**：复用 OpenAI Agents SDK 的 `Runner`、`SQLiteSession` 和 MCP stdio，按需发现工具，处理可恢复的工具错误。
- **文件与资料处理**：搜索、读取和写入任务文件；查询公开网页；创建或修改 Word、电子表格和演示文稿。
- **上下文与记忆**：有预算限制的上下文组装、历史检索和本地个人记忆。
- **受限 Python 执行**：仅在运行时隔离检查通过后开放，用于计算和文件处理；执行环境不能联网。
- **本地推理默认开启**：本地模式不需要 OpenAI API Key。OpenAI Agents SDK 负责执行流程，底层推理使用本地 Ollama 适配器。

**尚未实现：**自动安装任意新能力、通用第三方 MCP 配置界面、专用 X / Twitter 视频下载工具。复杂任务仍可能选错工具或提前结束，请检查重要结果。

## 环境要求

- Apple Silicon Mac。项目声明的最低系统版本为 macOS 15，开发中的界面主要在 macOS 26 上验证。
- Swift 6 或更新的兼容 Xcode / Command Line Tools 工具链。
- 可重定位的 CPython 3.12，以及 macOS ARM64 Ollama 运行环境。仓库不包含这些运行环境和模型权重。
- 足够容纳所选模型的内存与磁盘空间。首次启动提供模型设置流程，具体模型可用性取决于 Ollama 服务。

## 从源码构建

```sh
git clone https://github.com/cellier/Chillor.git
cd Chillor
# 使用从可信来源获取并解压的运行环境；具体布局见构建指南。
export CHILLOR_PYTHON_SOURCE="/absolute/path/to/relocatable-python"
export CHILLOR_MODEL_RUNTIME_SOURCE="/absolute/path/to/ollama-runtime"
./scripts/setup-agent-runtime.sh
./scripts/setup-model-runtime.sh
./scripts/build.sh
open outputs/Chillor.app
```

本次发布在 Swift 6.4 下使用 macOS 26.5 SDK 编译通过；默认 macOS 27 SDK 遇到了缺少 SwiftUI 插件的问题。如本机已安装相应 SDK，可以指定：

```sh
CHILLOR_SWIFT_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./scripts/build.sh
```

详见[构建与打包指南](docs/public/BUILDING.md)和[验证记录](docs/public/VALIDATION.md)（英文）。默认构建使用临时本地签名；可用 `CHILLOR_SIGNING_IDENTITY` 指定签名身份。默认流程不包含 Apple 公证。

## 架构与数据边界

```text
SwiftUI / AppKit 原生界面
  → 任务路由与上下文组装
  → Python OpenAI Agents SDK Runner + 本地 SQLite 会话
  → Ollama（默认本地）/ DeepSeek（主动选择）
  → MCP 工作区工具 / 受限 Python 执行
  → 本地文件产物、历史和记忆
```

本地模型服务使用 `127.0.0.1:11440`。网页工具会访问互联网，模型设置需要下载权重；选择 DeepSeek 后，相关消息、上下文和工具结果会发送给该服务。**本地优先不等于所有功能都离线。**

对话和任务数据保存在 `~/Library/Application Support/Chillor`；设置使用 `com.chillor.mac`。DeepSeek 密钥存放于 macOS 钥匙串。应用可能复用已有的旧版 ReplyLens 模型目录。屏幕捕获和桌面操作需要相应 macOS 权限。

启用代码执行或桌面操作前，请阅读[安全边界说明](SECURITY.md)（英文）。当前版本未经过完整安全审计，不应被视为处理恶意代码的可靠隔离环境。

## 测试

```sh
Resources/AgentPython/bin/python3 scripts/test-python.py
# 以下隔离检查必须在 macOS 上运行；失败时不能开放代码执行工具。
Resources/AgentPython/bin/python3 Resources/AgentTools/sandbox.py
```

`*live_eval.py` 是独立的可选集成测试，可能启动本地推理、访问网络或消耗付费模型额度，运行前请先阅读。原生 UI 测试需要已解锁的 macOS 会话。

欢迎通过 Issue 或 Pull Request 参与，详见[贡献指南](CONTRIBUTING.md)（英文）。提交问题时，请勿附带真实 API 密钥或私人对话。

## 开源协议

Chillor 自有代码采用 [MIT 协议](LICENSE)，允许使用、修改和商用，须保留版权及许可声明。第三方依赖保留各自许可证，详见[第三方声明](THIRD_PARTY_NOTICES.md)。模型权重和运行环境需另行下载，并遵守各自条款。
