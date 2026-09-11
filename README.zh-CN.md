# v2s

<p align="center">
  <img src="Assets.xcassets/AppIcon.appiconset/AppIcon-256.png" alt="v2s 应用图标" width="256" height="256">
</p>

<p align="center">
  <strong>macOS 私密面试助手与实时双语字幕。</strong>
</p>

<p align="center">
  v2s 可以将麦克风或指定应用的音频转换成简洁的双行字幕条，并提供可选助手，适用于面试、会议、通话、直播和视频。只有你明确请求帮助时，助手才会使用字幕历史和可见屏幕上下文。
</p>

<p align="center">
  <a href="https://github.com/NX-lite/v2s">源码</a>
  ·
  <a href="https://github.com/NX-lite/v2s/releases">发布版本</a>
  ·
  <a href="README.md">English Doc</a>
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/b65167ee-ae7e-4e37-8316-ebd200ae89a7" alt="Mar-20-2026 11-08-59">
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/449039ee-c329-426e-a55b-ab6660c56ca7" alt="Screenshot 2026-03-25 at 1 10 39 PM" width="500">
</p>

## 功能特性

- **菜单栏常驻应用**：启动后常驻于 macOS 菜单栏，随时可打开和控制字幕。
- **双语字幕悬浮条**：第一行显示翻译结果，第二行显示原始语音文本，便于快速对照。
- **多输入源音频输入**：可同时选择多个麦克风和正在运行的 macOS 应用，不必混录整个系统。
- **分输入源语言**：不同输入源可设置不同的输入和输出语言，适合双语或混合语言对话。
- **语音转写**：基于 Apple Speech 框架，优先使用本地语音识别，并动态发现当前 Mac 可用的语言。
- **本地翻译**：基于 Apple Translation 框架进行翻译处理。
- **AI 摘要**：基于 Apple Intelligence 对字幕记录进行智能摘要；当 Apple Intelligence 不可用时，自动回退到本地提取式摘要，同样可以快速掌握对话要点。
- **Core ML VAD**：使用 Core ML 运行 Silero VAD，不依赖 ONNX Runtime。
- **单实例与悬浮层样式**：重复启动会由已有实例处理；字幕悬浮条可调节以适应真实工作场景。
- **可选助手**：通过明确的 **Follow Up** 和 **Ask** 操作请求帮助，兼容 OpenAI Responses API 和 Gemini API；可编辑模型、拉取模型列表，并使用你配置的 API 做连接测试。
- **三个全局快捷键**：分别用于 Follow Up、Ask、切换字幕/回复模式；无效或冲突的快捷键会在设置中显示。
- **屏幕上下文与独立回复层**：请求时可使用 macOS 截图和 Vision OCR；GPT 回复层可独立滚动，且不会覆盖字幕历史。
- **统一隐私开关**：**Invisible in Recording** 是同一个隐私设置，一致应用于悬浮面板、设置窗口和字幕模式信息窗口。

## 输入与字幕语言

v2s 会向 Apple 的 Speech 与 Translation 框架查询当前 Mac 支持的语言，因此语言选项会自动跟随系统与模型更新。界面会合并地区变体，但保留简体中文和繁体中文等有实际意义的文字变体。开始会话前，v2s 还会检查 Apple Translation 是否支持所选的源语言与目标语言组合。

## 隐私保护

- 无需账号，也没有云端后台、分析或遥测。
- v2s 没有云端后台，也不会把音频或字幕文本发送到自己的服务器。
- 翻译依赖 Apple 的本地 Translation 框架，部分语言包可能需要先在系统设置中下载。
- 语音识别优先使用 Apple 的本地模型；当某个语言存在本地模型时，v2s 会优先选用带本地模型的地区变体。
- 部分语言在特定 Mac 上没有本地模型（Intel Mac 以及新版 Speech 技术栈未覆盖的语言尤其常见），这些语言会走 Apple 的服务器识别：需要网络连接，受 Apple 服务配额限制，并会依据 Apple 的隐私条款将捕获的语音发送给 Apple。
- Silero VAD 通过系统 Core ML 框架运行；v2s 不包含第三方推理运行时，转换过程可在仓库脚本中复现。
- 助手是可选功能。在你明确执行 **Follow Up** 或 **Ask** 前，v2s 不会发送助手请求、字幕、屏幕图像或 OCR 数据。
- 仅在你明确执行 Follow Up 或 Ask 后，v2s 才可能把已配置的字幕上下文（包括时间戳、输入源/语言）、Skills 提示词、当前屏幕截图和 OCR 文本发送给你配置的服务商。服务商如何处理或保存数据受其自身条款约束。
- 如果服务商拒绝图像输入，v2s 会仅重试一次纯文本回退请求：不发送截图，同时保留可用 OCR 文本。没有屏幕录制权限时也会降级为文字上下文，不会阻止助手请求。
- 拉取模型和连接测试都会联系你配置的服务商。它们是配置工具，并不表示本项目已经验证过任何真实服务商、账号或模型。
- API Key 只保存在本地设置中。模型列表拉取和 API 连接测试会使用它联系你配置的服务商；字幕、当前屏幕图像和 OCR 文本仅在明确执行 Follow Up 或 Ask 后才会发送。

## 可选助手

在设置中填写 API Key、基础 URL、模型、Skills 提示词和三个快捷键。`Follow Up` 基于当前上下文请求简短追问，`Ask` 基于相同上下文请求答案。即使没有字幕，助手也会使用兼容旧版的占位上下文，因此仍可进行仅屏幕的 Ask。服务商的回复会原样显示在独立滚动的回复层中；切回字幕不会中断音频捕获。

助手兼容 OpenAI Responses API 和 Gemini API，可以拉取可用模型并运行基于当前配置的连接测试；自动化测试没有进行真实服务商请求，本文档也不将任何真实服务商声明为已验证。

## 设计参考

这是独立的 Swift 实现，未复制代码。仅从 [Meetily](https://github.com/Zackriya-Solutions/meetily/tree/a2cb62e827da7ef59f65064c97233efb2313878e) 和 [1meeting-summary-ai 候选](https://github.com/Disalazario/meeting-summary-ai/tree/640efa955e62f6dfebfe4ac7e8c9651119469229) 借鉴高层设计参考：本地优先隐私、可取消的服务商操作和合成测试/结构断言。v2s 并非完全本地：Apple 能力和已配置服务商的操作可能会按上述披露发送数据。

## 快速开始

### 手动安装

1. 从 [NX-lite/v2s Releases](https://github.com/NX-lite/v2s/releases) 页面下载最新的 `.app.zip`。
2. 解压后将 `v2s.app` 移动到 `Applications` 文件夹。

v2s 可能尚未通过 Apple 公证。若 macOS 隔离手动安装的副本，启动前执行一次：

```bash
xattr -dr com.apple.quarantine /Applications/v2s.app
```

### 首次运行

1. 启动 v2s，它会以图标形式出现在菜单栏中。
2. 选择输入源：麦克风或某个正在运行的应用。
3. 选择输入语言和字幕语言。
4. 点击 **Start**。

首次使用时，v2s 会请求以下权限：

- **Speech Recognition**：用于将音频转写为文本。
- **Microphone**：当输入源为麦克风时需要。
- **Audio Capture**：当输入源为其他应用时需要。
- **Screen Capture**：仅在明确的 Follow Up 或 Ask 助手请求需要当前屏幕上下文时需要。

## 环境要求

- 语音转写和翻译功能需要 macOS 26 或更高版本
- 支持 Apple 芯片和 Intel Mac；可用的语音语言以及能否在本地识别，取决于具体 Mac 和所选语言。

## 从源码构建

```bash
git clone https://github.com/NX-lite/v2s.git
cd v2s
open v2s.xcodeproj
```

也可以直接使用终端构建：

```bash
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug build
```

如需专门为 Intel Mac 构建：

```bash
swift build -c release --arch x86_64
```

## 许可证

MIT
