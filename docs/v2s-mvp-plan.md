# v2s MVP 计划

版本：v1.0  
日期：2026-03-16  
依赖文档：[v2s-system-design.md](/Users/franklioxygen/Projects/v2s/docs/v2s-system-design.md)

## 1. 计划目标

本文档把 `v2s` 的系统设计收敛为一个可以执行的 MVP 研发计划，目标是：

- 先做出一个可用、可验证、可演示的 macOS 菜单栏产品
- 优先打通“单输入源 -> 识别 -> 翻译 -> 顶部字幕条”主链路
- 把高风险技术点前置验证，不在后期集中爆雷
- 明确 MVP 范围、非范围、阶段交付物、验收标准和实现顺序

## 2. MVP 定义

## 2.1 MVP 要解决的问题

MVP 只解决一个核心问题：

用户可以在 macOS 上选择一个声音输入源，然后让 `v2s` 用系统能力实时显示双语字幕。

这条链路必须稳定覆盖：

1. 选择输入源
2. 选择输入语言
3. 选择输出字幕语言
4. 启动识别
5. 显示原文
6. 显示翻译
7. 在桌面顶部稳定显示字幕条

### 2.2 MVP 成功标准

MVP 成功不等于“功能很多”，而等于下面这些条件同时满足：

1. 首次启动后，用户能在 2 分钟内完成权限配置并开始使用。
2. 用户能从菜单栏选定一个麦克风，或者一个受支持的 App。
3. 菜单栏里可以切换输入语言和输出语言。
4. 启动后，桌面顶部默认双层字幕条可以稳定显示。
5. 下层原文实时刷新，上层翻译在稳定片段后更新。
6. 选定输入源退出、静音、权限缺失、翻译资源缺失时都有明确提示。
7. 默认不保存音频，不保存字幕内容。
8. 在 Apple Silicon 机器上连续运行 30 分钟无崩溃、无明显内存持续上涨。

### 2.3 MVP 范围

MVP 必做范围：

- 菜单栏常驻
- 快捷设定面板
- 详细设置窗口的最小可用版
- 顶部双层字幕条
- 单输入源会话
- 麦克风输入
- App 音频输入
- 输入语言选择
- 输出语言选择
- Apple Speech 识别
- Apple Translation 翻译
- 本地设置持久化
- 基础日志与错误提示

### 2.4 MVP 非范围

以下明确不进 MVP：

- 同时监听多个输入源
- 标签页级浏览器音频选择
- 说话人分离
- 录音回放
- 字幕导出为文件
- 云端识别和云端翻译
- 可编辑字幕历史记录
- 自定义主题系统
- iCloud 同步
- Mac App Store 首发

## 3. MVP 版本边界

## 3.1 支持平台

- `macOS 15+`
- 优先 Apple Silicon

### 3.2 MVP 支持的输入源

MVP 输入源按优先级分两层。

第一层必须稳定支持：

- Mac 内建麦克风
- USB 麦克风
- Chrome
- Safari
- Zoom
- VLC

第二层作为扩展验证目标：

- Firefox
- Slack
- Teams
- Webex
- GoToMeeting
- Infuse
- 蓝牙耳机麦克风

这里的意思不是第二层不能做，而是：

- 第一层决定 MVP 能不能发布给小范围用户试用
- 第二层决定 MVP 兼容性质量，不决定主链路成立

### 3.3 MVP 支持的语言

MVP 不追求“所有语言”，只追求一组高频语言对稳定可用。

建议首批重点验证：

- English -> Chinese (Simplified)
- Chinese (Simplified) -> English
- English -> Japanese
- Japanese -> English

其他语言只要系统支持，可以显示为“实验性支持”。

## 4. 研发原则

### 4.1 先打通主链路，再扩兼容面

开发顺序必须是：

1. 麦克风主链路
2. 顶部字幕条主链路
3. 菜单栏操作主链路
4. App 音频采集
5. 兼容性扩展

不要一开始就同时做所有 App 兼容规则。

### 4.2 先做可观察性

MVP 阶段必须从一开始就有：

- 会话状态日志
- 输入源解析日志
- 权限状态日志
- 识别事件计数
- 翻译队列计数

否则 App 音频问题后面很难定位。

### 4.3 先做单线程安全的业务状态，再做 UI 漂亮

优先把以下数据流做稳定：

- 源切换
- 会话启动/停止
- partial -> final -> translation 的状态流
- overlay 状态更新

不要在状态机还不稳的时候做过多视觉细节。

## 5. MVP 里程碑

## 5.1 里程碑总览

| Milestone | 名称 | 目标 |
| --- | --- | --- |
| M0 | 技术验证 | 确认 API、权限、核心可行性 |
| M1 | 工程骨架 | 菜单栏 App 框架、设置、overlay 空壳 |
| M2 | 麦克风主链路 | mic -> speech -> translation -> overlay |
| M3 | App 音频主链路 | app tap -> speech -> translation -> overlay |
| M4 | 稳定化 | 兼容、性能、错误处理、试用包 |

### 5.2 建议周期

如果是单人或 1-2 人小团队，建议按下面节奏：

- M0：3 到 5 天
- M1：4 到 6 天
- M2：5 到 8 天
- M3：7 到 12 天
- M4：5 到 8 天

总计：大约 4 到 6 周

如果 M0 阶段确认 App 音频捕获存在系统限制或实现复杂度超预期，则必须把范围调整为：

- 先发布 `mic-only MVP`
- App 音频作为 `MVP+1`

这个降级路径要提前接受，而不是在最后一周被动接受。

## 6. Milestone 详细拆解

## 6.1 M0 技术验证

### 目标

把所有高风险项前置验证，不在正式开发中“边写边猜”。

### 任务

1. 建立 3 个最小 demo：
   - `mic -> speech`
   - `text -> translation`
   - `app audio tap -> pcm monitor`
2. 确认所需系统权限和 Info.plist key。
3. 确认 `Speech` 在目标语言上的设备端可用性。
4. 确认 `Translation` 模型下载/可用状态检查方式。
5. 确认顶部 overlay 在以下场景的行为：
   - 多显示器
   - 全屏 app
   - Space 切换
   - 点击穿透
6. 确认 Chrome / Safari / Zoom / VLC 的 App 音频是否能稳定采集。

### 交付物

- 技术验证结论文档
- demo 工程或 demo target
- 一份权限清单
- 一份语言能力矩阵

### 验收标准

- 可以从麦克风拿到连续音频并进入系统识别
- 可以对固定文本调用系统翻译并返回结果
- 至少 2 个目标 App 可被单独捕获到音频
- overlay 能跨 Space 显示且不抢焦点

### 出口条件

只有当下面两个条件同时满足，才能进入 M1：

1. 麦克风链路可行
2. App 音频链路至少对 2 个目标 App 可行

如果第二项不成立，立即改计划为 `mic-only MVP`。

## 6.2 M1 工程骨架

### 目标

建立正式工程结构和最小运行壳。

### 任务

1. 创建 Xcode App 工程。
2. 建立模块目录：
   - `App`
   - `UI`
   - `Domain`
   - `Infrastructure`
   - `Tests`
3. 实现 `NSStatusItem` 常驻。
4. 实现快捷设定面板空壳。
5. 实现设置窗口空壳。
6. 实现 overlay 窗口空壳。
7. 建立 `SessionCoordinator`。
8. 建立 `SettingsStore`。
9. 接入 `OSLog` 日志。

### 交付物

- 能启动的菜单栏 App
- 可打开的快捷面板
- 可打开的设置窗口
- 可显示/隐藏的顶部字幕条空壳

### 验收标准

- App 运行后默认显示在状态栏
- 用户可通过菜单栏显示/隐藏 overlay
- 用户可打开设置窗口并修改基础设置
- 重启 App 后基础设置能恢复

## 6.3 M2 麦克风主链路

### 目标

先把麦克风路径做到完整闭环。

### 任务

1. 实现麦克风设备枚举。
2. 实现麦克风权限检查与请求。
3. 实现 `MicrophoneCaptureEngine`。
4. 实现 `AudioPreprocessor`：
   - 重采样
   - 单声道
   - 电平统计
   - 静音门限
5. 实现 `SpeechProvider` 第一版。
6. 实现 `TranscriptStabilizer`。
7. 实现 `TranslationService` 第一版。
8. 实现 `SubtitleComposer`。
9. 接通 overlay 实时显示。
10. 在菜单栏面板中加入：
    - 麦克风选择
    - 输入语言选择
    - 输出语言选择
    - 开始/停止

### 交付物

- 麦克风输入下的完整双语字幕能力
- 基础错误提示
- 语言资源状态提示

### 验收标准

- 用户选择任一系统可见麦克风后可以开始会话
- 原文字幕出现延迟满足目标
- 翻译结果能稳定更新到上层
- 停止后 overlay 隐藏
- 切换麦克风不会串字幕

### M2 结束判定

如果 M2 不稳定，就不要进入 M3。  
App 音频只是输入源变体，前后级稳定性必须先在麦克风链路上成立。

## 6.4 M3 App 音频主链路

### 目标

在麦克风闭环稳定后，再加入定向 App 音频采集。

### 任务

1. 实现 `SourceCatalogService`：
   - 枚举运行中 App
   - 分类展示常见 App
2. 实现 `ProcessGroupResolver`。
3. 实现 `ProcessTapCaptureEngine`。
4. 实现目标 App 退出后的自动重连。
5. 在快捷面板中加入 App 输入源列表。
6. 加入 App 输入源状态提示：
   - 无音频
   - App 已退出
   - 权限缺失
   - 捕获失败
7. 对主流 App 做兼容性适配和规则修正。

### 交付物

- 可以选择单个 App 作为输入源
- 至少一组浏览器、一组会议软件、一组视频播放器验证通过

### 验收标准

- 能选择 Chrome / Safari / Zoom / VLC 中至少 3 个并成功显示字幕
- 切换 App 源时不会崩溃
- App 退出或重启后能自动恢复或给出清晰错误
- 不会把旧源文本残留到新源

### 退出条件

M3 完成后，`v2s` 才能被定义为“符合原始愿景的 MVP”。

## 6.5 M4 稳定化

### 目标

让 MVP 从“能跑”提升到“能给外部用户试”。

### 任务

1. 补全错误码与错误提示映射。
2. 优化 overlay 的排版、过长文本裁切和淡入淡出。
3. 优化 source switching 状态机。
4. 补单元测试和集成测试。
5. 补诊断导出。
6. 加入 launch at login。
7. 完成签名、notarization、打包脚本。
8. 做小范围试用反馈收集。

### 交付物

- 可分发安装包
- 测试报告
- 已知问题列表

### 验收标准

- 连续运行 30 分钟以上不崩溃
- 关键路径有日志，且能导出
- 权限缺失和模型缺失路径可恢复
- 安装包可在未开发环境机器上正常启动

## 7. 功能拆分清单

## 7.1 P0 功能

P0 是 MVP 必须有，没有就不能发布试用版。

- 状态栏图标与快捷面板
- 单输入源会话管理
- 麦克风输入
- App 输入源选择
- 输入语言 / 输出语言选择
- 原文实时字幕
- 翻译字幕
- 顶部双层字幕条
- 权限检查与引导
- 资源缺失提示
- 错误提示与基础日志
- 设置持久化

### 7.2 P1 功能

P1 是 MVP 有更好，但不阻塞试用。

- launch at login
- 全局快捷键
- overlay 透明度和字号快速调节
- “仅翻译 / 仅原文”模式
- 多显示器选择
- 自动 dim / auto clear
- 兼容更多 App

### 7.3 P2 功能

P2 不应进入当前 MVP 排期。

- 历史字幕面板
- 录音和导出
- 说话人区分
- 自动语种识别
- 标签页级音频
- 自定义主题
- 云端同步

## 8. 技术任务分解

## 8.1 App 层

- `V2SApp`
- `AppDelegate`
- 激活策略管理
- 设置窗口路由
- menu bar 生命周期

### 8.2 Session 层

- `SessionCoordinator`
- `SessionState`
- session 启动/停止
- 源切换
- 错误恢复

### 8.3 Source 层

- `SourceCatalogService`
- `InputSourceKind`
- `ProcessGroupResolver`
- source availability 检查

### 8.4 Capture 层

- `MicrophoneCaptureEngine`
- `ProcessTapCaptureEngine`
- PCM 标准化
- 电平检测
- 静音判定

### 8.5 Speech 层

- `SpeechProvider`
- `LegacySpeechProvider`
- 新 Speech API 兼容分支
- `TranscriptEvent`
- `TranscriptStabilizer`

### 8.6 Translation 层

- `TranslationService`
- 模型状态检查
- job queue
- 批处理和去抖

### 8.7 Overlay 层

- `OverlayWindowController`
- `OverlayViewState`
- 顶部条布局
- 点击穿透
- 多显示器策略

### 8.8 Persistence 层

- `SettingsStore`
- schema migration
- 最近输入源恢复

### 8.9 Diagnostics 层

- `OSLog` 分类
- 会话事件日志
- 诊断导出

## 9. 推荐开发顺序

按任务依赖排序，推荐顺序如下：

1. `SettingsStore`
2. `SessionState` + `SessionCoordinator` 空壳
3. `NSStatusItem` + 快捷面板空壳
4. `OverlayWindowController` 空壳
5. `MicrophoneCaptureEngine`
6. `AudioPreprocessor`
7. `SpeechProvider`
8. `TranscriptStabilizer`
9. `TranslationService`
10. `SubtitleComposer`
11. 把 mic 链路接到 UI
12. `SourceCatalogService`
13. `ProcessGroupResolver`
14. `ProcessTapCaptureEngine`
15. 把 app 音频链路接到 UI
16. 稳定化和测试

原因很简单：

- 先把不依赖系统复杂权限的部分做成
- 再解决最难的不确定项：App 音频采集

## 10. 工程交付物

每个 milestone 结束都要留下可检查产物。

### M0 结束

- spike 代码
- API 可行性说明
- 风险更新

### M1 结束

- 可启动 App
- 空壳 UI
- 基础状态机

### M2 结束

- 可工作的 mic 版 v2s
- 麦克风测试报告

### M3 结束

- 可工作的 app source 版 v2s
- App 兼容性清单

### M4 结束

- 试用安装包
- 发布说明
- 已知问题

## 11. 质量门槛

## 11.1 Definition of Done

任何功能在标记完成前，必须满足：

1. 有代码
2. 有最基本的测试或手工验证步骤
3. 有日志
4. 有错误路径处理
5. 不破坏现有主链路

### 11.2 关键测试清单

每次发试用包前至少重复以下测试：

- 启动 App
- 首次授权
- 切换输入语言
- 切换输出语言
- 麦克风开始/停止
- App 输入开始/停止
- 源切换
- 目标 App 退出
- 目标 App 重开
- 资源缺失
- 长时间静音
- 全屏窗口下 overlay 表现

### 11.3 性能门槛

- 原文首字延迟：`p50 < 700 ms`
- 翻译延迟：`p50 < 1200 ms`
- 空闲内存：`< 120 MB`
- 连续运行 CPU：`< 18%`

如果为了追求更多兼容而明显破坏这些指标，应优先收窄范围，不要硬塞。

## 12. 风险与应对

## 12.1 App 音频链路风险

风险：

- 某些 App 的音频不是从主进程发出
- 某些媒体受保护，不可捕获

应对：

- 提前做 `ProcessGroupResolver`
- 在 UI 中显式说明限制
- 必要时允许降级到 mic-only

### 12.2 语言资源风险

风险：

- Speech 与 Translation 支持的语言集不完全重合

应对：

- 只展示当前系统真正可用的语言对
- 缺失时显示为不可选或需下载

### 12.3 识别抖动风险

风险：

- partial result 频繁改写导致字幕闪烁

应对：

- `TranscriptStabilizer`
- 翻译只处理稳定片段

### 12.4 窗口行为风险

风险：

- overlay 在全屏、多 Space、多显示器下行为异常

应对：

- M0 阶段做真实环境验证
- 把 window behavior 作为独立模块实现

## 13. MVP 发布策略

MVP 建议分两轮。

### Round 1：内部试用

范围：

- 只给开发者和少量熟悉 macOS 的试用者

目标：

- 验证权限说明是否清晰
- 验证主流输入源兼容性
- 验证 overlay 视觉是否足够实用

### Round 2：外部小范围试用

范围：

- 给真实会议、视频观看用户试用

目标：

- 验证易用性
- 验证长时间运行稳定性
- 收集支持 App 优先级

## 14. 建议立即开始的第一批任务

如果现在立刻进入开发，建议第一批只做下面这些：

1. 创建 Xcode 工程和基础目录。
2. 做 `NSStatusItem`。
3. 做顶部 overlay 空壳。
4. 做 `SettingsStore`。
5. 做 `SessionCoordinator` 空壳。
6. 做麦克风权限 + mic capture demo。
7. 做 `SpeechProvider` 第一版。
8. 做 `TranslationService` 第一版。
9. 把 mic 链路打通。

不要一开始就做：

- 多显示器复杂策略
- 所有 App 兼容规则
- 丰富设置项
- 花哨动画

## 15. 最终结论

`v2s` 的 MVP 最合理路线不是“把所有设想一次做完”，而是分两层推进：

第一层，先用麦克风把完整体验闭环做稳。  
第二层，再把 App 音频输入作为高风险扩展加进去。

如果 App 音频在 M0 阶段验证顺利，MVP 可以按原始愿景推进；如果验证不顺，必须果断切换为 `mic-first MVP`，先把产品做出来，再扩输入源兼容。

这个计划的核心不是保守，而是控制变量。对于 `v2s` 这种系统级 macOS 工具，真正的风险不在 UI，而在权限、音频捕获和识别链路的稳定性。MVP 计划必须围绕这三件事排布。
