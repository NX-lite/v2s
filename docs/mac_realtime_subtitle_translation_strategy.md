# mac 实时音频识别字幕与实时翻译系统
## 用户体验优先的识别 + 翻译策略技术文档（Markdown）

## 1. 文档目标

本文档给出一套**可落地、可量化、可实现**的 macOS 实时字幕翻译产品方案，目标是在以下三者之间取得最优平衡：

1. **识别与翻译尽量精准**
2. **字幕停留足够久，用户读得完**
3. **整体仍然跟得上音频节奏，不明显落后**

本文档重点不是单纯追求最低延迟，而是定义一套**面向真实用户体验**的策略、状态机、阈值、公式、数据结构和默认参数。

---

## 2. 产品定义

### 2.1 产品一句话定义

> 让用户先尽快看到“正在说什么”，再以尽量少抖动的方式看到“稳定可读的正式字幕和翻译”。

### 2.2 核心体验原则

系统必须同时做到：

- **早出现**：避免用户等待太久
- **少回改**：避免读到一半整句被改掉
- **能读完**：避免字幕闪一下就消失
- **不掉队**：避免翻译长期落后音频
- **低认知负担**：用户不需要一直追逐变化

---

## 3. UX 总策略

### 3.1 推荐总策略：双层字幕 + 分阶段提交

不要把“识别”和“翻译”按同一种刷新节奏处理。

### 第一层：草稿原文层（Draft Source）
用途：尽快告诉用户“当前正在说什么”。

特点：

- 低延迟
- 可不稳定
- 视觉弱化
- 只显示原文，不急着显示翻译

建议样式：

- 颜色：灰白 / 半透明
- 字重：Regular 或 Light
- 不加重背景强调
- 允许尾部动态变化

### 第二层：正式提交层（Committed Source + Translation）
用途：提供正式阅读内容。

特点：

- 一旦提交，尽量少改
- 正式翻译只在句块稳定后显示
- 优先保证可读性和完整度

建议样式：

- 原文：辅助阅读
- 翻译：主视觉内容
- 背景更稳、对比更高
- 上下双层展示

---

## 4. 用户界面策略

### 4.1 推荐布局

```text
[上一条字幕（淡出中）]

原文：Today we need to discuss two product directions.
译文：今天我们需要讨论两个产品方向。
```

或者在更紧凑的模式下：

```text
Today we need to discuss two product directions.
今天我们需要讨论两个产品方向。
```

### 默认视觉权重

- 翻译：100%
- 原文：75%–85%
- 草稿层：50%–65%
- 上一条残影：25%–40%

---

### 4.2 推荐显示规则

### 当前条
- 最多显示 2 行翻译
- 原文最多 1–2 行
- 当前条为强视觉焦点

### 上一条
- 保留 0.8–1.5 秒淡出
- 只保留 1 条，不保留长历史
- 目的是给用户“补读最后几个词”的机会

### 不推荐
- token 级持续闪烁
- 翻译与原文左右并排双栏
- 连续滚动上推很多历史行
- 每次 partial 更新都整块重绘

---

## 5. 核心体验指标（KPI）

系统优化必须围绕以下指标。

### 5.1 实时性指标

#### T1. 首字出现时间（First Visible Token Latency）
定义：音频开始说话到第一段草稿字幕出现的时间。

目标：

- 优秀：`200–350 ms`
- 可接受：`350–600 ms`
- 不建议超过：`700 ms`

#### T2. 正式原文提交延迟（Committed Source Latency）
定义：一句话或一个句块从说出到正式原文稳定显示的时间。

目标：

- 优秀：`600–1000 ms`
- 可接受：`1000–1500 ms`

#### T3. 正式翻译提交延迟（Committed Translation Latency）
定义：一个句块从说出到正式翻译出现的时间。

目标：

- 优秀：`900–1500 ms`
- 可接受：`1500–2200 ms`

---

### 5.2 可读性指标

#### R1. 字幕读完率（Read Completion Rate）
定义：字幕消失前用户能够读完的比例。

目标：

- `> 90%`

#### R2. 有效阅读停留时间（Effective Hold Time）
定义：字幕可稳定阅读的时长，不包含明显抖动阶段。

目标：

- 短句：`>= 1.2 s`
- 中句：`>= 1.8 s`
- 长句：`>= 2.5 s`

#### R3. 抖动率（Caption Rewrite Annoyance Proxy）
定义：用户正在读的正式字幕被改写的次数。

目标：

- 正式原文：每句 `<= 1` 次轻微修正
- 正式翻译：每句 `<= 1` 次轻微修正
- 不允许反复整句洗牌

---

### 5.3 精准性指标

#### A1. 术语一致率
定义：同一会话中专有名词、产品名、术语翻译保持一致的比例。

目标：

- `>= 95%`

#### A2. 数字与单位准确率
定义：数字、百分比、金额、版本号、容量等识别与翻译准确率。

目标：

- `>= 99%`

#### A3. 实体稳定率
定义：已确认的人名、地名、产品名后续不漂移的比例。

目标：

- `>= 97%`

---

## 6. 系统架构建议（macOS）

macOS 侧建议将能力拆成如下模块：

```text
Audio Capture
  ├─ Mic Capture
  ├─ System/App Audio Capture
  ↓
Audio Preprocess
  ├─ VAD
  ├─ Denoise/AGC
  ├─ Channel mix / resample
  ↓
Streaming ASR
  ├─ partial hypothesis
  ├─ word timestamps
  ├─ confidence
  ↓
Segmentation & Stability Engine
  ├─ pause detector
  ├─ punctuation boundary
  ├─ stable prefix freeze
  ↓
Streaming Translation
  ├─ phrase-level translation
  ├─ glossary enforcement
  ├─ lightweight post-edit
  ↓
Subtitle Renderer
  ├─ draft layer
  ├─ committed layer
  ├─ fade queue
  ↓
History / Export / Analytics
```

在 macOS 上，音频输入与处理可基于 `AVAudioEngine` 搭建实时处理链；需要抓取屏幕/应用音频时，可使用 `ScreenCaptureKit`。

如果你要做“系统音频 / 指定应用音频 / 麦克风”多源采集，建议把 `ScreenCaptureKit` 作为系统/应用音频来源，把麦克风输入走独立音频链，再在内部统一重采样和时间对齐。

如果你考虑使用 Apple 的 Speech 框架作为备用识别能力，需要注意 `SFSpeechRecognizer` 受权限控制，更适合作为 fallback，而不是高可控实时字幕产品的唯一主链路。

悬浮字幕窗建议使用 AppKit 原生窗口能力，而不是纯 SwiftUI 弹层。`NSWindow.CollectionBehavior` 可控制窗口在全屏、Spaces、Stage Manager 等场景下的显示特征。

---

## 7. 识别策略

### 7.1 识别输出分层

ASR 输出必须区分为两种：

### 1）Partial Hypothesis
- 低延迟
- 允许变化
- 用于草稿原文层

### 2）Committed Hypothesis
- 稳定度达到阈值后提交
- 用于正式原文层
- 触发正式翻译

---

### 7.2 Partial 更新策略

不要每次 partial 变化都整行重绘。

### 正确做法：稳定前缀冻结（Stable Prefix Freeze）
将当前文本拆成两部分：

- `stable_prefix`
- `mutable_tail`

显示时：

```text
stable_prefix + mutable_tail
```

其中：

- `stable_prefix`：过去一段时间没再变化的部分
- `mutable_tail`：允许继续变化的尾部

### 默认规则

- 最多只允许最后 `4–8` 个词或最后 `8–20` 个汉字作为 `mutable_tail`
- 当前尾部刷新频率：`80–150 ms`
- 前缀一旦连续 `300–500 ms` 不变化，则转入稳定前缀

---

### 7.3 提交时机（Commit Trigger）

一个句块满足以下任一条件即可进入提交候选态：

### 条件 A：静音停顿
- 检测到 trailing silence `>= 250 ms`

### 条件 B：高稳定度
- 最近 `400 ms` 内文本变化次数 `<= 1`
- 且尾部平均置信度 `>= 0.86`

### 条件 C：明显边界
满足任意一项：
- 标点恢复置信度高
- 连词后停顿明显
- 从句结束
- 语义完整度高

### 条件 D：强制切块
- 当前句块音频时长 `>= 3.2 s`
- 或字符过长：
  - 中文 `>= 28` 字
  - 英文 `>= 80` 字符

---

## 8. 分句与切块策略

### 8.1 句块设计原则

单个字幕块必须同时满足：

- 是一个自然语义单位
- 用户能在一次注视中读完
- 翻译上下文足够稳定
- 不至于拖太久才出现

---

### 8.2 推荐切块大小

### 中文目标
- 每块：`10–22` 字较优
- 上限：`26–30` 字

### 英文目标
- 每块：`28–56` 字符较优
- 上限：`70–84` 字符

### 音频时长目标
- 理想：`1.2–2.8 s`
- 上限：`3.2–3.5 s`

---

### 8.3 切块评分函数

定义切块分数：

```text
ChunkScore =
  0.30 * SilenceScore +
  0.20 * StabilityScore +
  0.20 * BoundaryScore +
  0.15 * LengthFitScore +
  0.15 * ConfidenceScore
```

各项建议：

#### SilenceScore
- silence < 120ms -> 0
- 120–250ms -> 0.4–0.7
- >= 250ms -> 1.0

#### StabilityScore
- 最近 400ms 文本变化越少越高
- 无变化 -> 1.0
- 变化 1 次 -> 0.7
- 变化 2 次以上 -> 0.3 以下

#### BoundaryScore
- 标点恢复高概率 / 明显语义结束 -> 0.8–1.0
- 普通分句 -> 0.5–0.7
- 生硬截断 -> 0.2

#### LengthFitScore
- 中文 12–20 字最优 -> 1.0
- 太短或太长下降

#### ConfidenceScore
- 平均词置信度线性映射

#### 提交阈值
- `ChunkScore >= 0.72`：提交
- `0.60–0.72`：继续观察 `120–180 ms`
- `< 0.60`：不提交

---

## 9. 翻译策略

### 9.1 翻译不要跟 token 级联动

这是最关键原则之一：

> 原文可以草稿级实时，翻译只应在“稳定句块”层面更新。

否则会出现：

- 翻译不断重排
- 用户反复回读
- 主观体验显著下降

---

### 9.2 推荐翻译流水线

```text
Committed Source
  ↓
Fast Translator
  ↓
Glossary Enforcer
  ↓
Light Post-Editor
  ↓
Committed Translation
```

### Fast Translator
负责：

- 快速给出首版翻译
- 保持句义正确
- 不做大幅文风润色

### Glossary Enforcer
负责：

- 强制术语表
- 实体一致性
- 数字和单位保护

### Light Post-Editor
负责：

- 标点补全
- 小幅语序调整
- 去掉直译感
- 不允许整句重写

---

### 9.3 翻译上下文输入

每次翻译建议只带以下上下文：

```text
context = {
  previous_committed_translation: 最近 1 条,
  previous_committed_source: 最近 1 条,
  current_chunk_source: 当前句块,
  glossary: 当前会话术语表,
  topic_hint: 可选主题标签
}
```

不建议把过去一大段都喂进去，否则会导致：

- 延迟上升
- 稳定性下降
- 过度改写

---

### 9.4 翻译修正规则

正式翻译提交后：

- 最多允许 `1` 次轻微修正
- 修正窗口：`500–1000 ms`
- 只允许局部变更
- 若编辑距离过大，则不在主字幕区刷新，只更新历史区

### 建议阈值
- Levenshtein Distance Ratio `<= 0.18`：允许主区修正
- `> 0.18`：拒绝主区重刷，改写仅写入历史面板

---

## 10. 字幕显示时长模型

### 10.1 核心原则

字幕的停留时长不能只跟音频同步，也要跟**阅读时间**同步。

### 显示时长公式

```text
display_duration =
max(
  min_hold_time,
  reading_time,
  source_audio_span * sync_factor
)
```

---

### 10.2 阅读时间估算

### 中文翻译
```text
reading_time_zh = char_count / cps_zh
```

建议：

- `cps_zh = 6.5–8.0 字/秒`
- 默认值：`7.0`

### 英文翻译
```text
reading_time_en = char_count / cps_en
```

建议：

- `cps_en = 12–15 字符/秒`
- 默认值：`13.5`

### 双语同显惩罚因子
如果双语同时显示：

```text
reading_time = base_reading_time * bilingual_factor
```

建议：

- `bilingual_factor = 1.10–1.25`
- 默认值：`1.15`

---

### 10.3 默认显示参数

```yaml
subtitle_display:
  min_hold_time_short: 1.2
  min_hold_time_normal: 1.6
  min_hold_time_long: 2.0
  max_hold_time: 4.5
  sync_factor: 1.0
  bilingual_factor: 1.15
  previous_caption_fade_hold: 1.0
```

### 推荐分档
- 短句：`<= 10` 汉字 或 `<= 28` 英文字符 -> `1.2 s`
- 中句：`11–20` 汉字 或 `29–56` 英文字符 -> `1.6–2.2 s`
- 长句：`21+` 汉字 或 `57+` 英文字符 -> `2.2–3.5 s`

---

## 11. 自适应模式

### 11.1 平衡模式（默认）
适合大多数使用场景。

```yaml
mode: balanced
first_token_target_ms: 350
commit_source_target_ms: 900
commit_translation_target_ms: 1400
max_chunk_audio_sec: 3.2
min_silence_commit_ms: 280
```

---

### 11.2 跟随优先模式
适合直播、会议速记。

```yaml
mode: follow
first_token_target_ms: 250
commit_source_target_ms: 700
commit_translation_target_ms: 1100
max_chunk_audio_sec: 2.4
min_silence_commit_ms: 180
translation_quality_bias: low_latency
```

策略：
- 更快切块
- 翻译更早提交
- 可读性略降
- 允许更短停留

---

### 11.3 阅读优先模式
适合课程、技术分享、外语学习。

```yaml
mode: reading
first_token_target_ms: 450
commit_source_target_ms: 1100
commit_translation_target_ms: 1700
max_chunk_audio_sec: 3.8
min_silence_commit_ms: 350
translation_quality_bias: readability
```

策略：
- 切块更完整
- 翻译稍慢但更顺
- 显示停留更久
- 上一条淡出更明显

---

### 11.4 极高速保护模式

当检测到以下任一条件时触发：

- 最近 `5 s` 平均语速超阈值
- 翻译队列积压 `>= 2`
- 当前字幕读完率预测过低
- 提交延迟连续超预算

### 触发阈值示例
- 中文：`> 8.5 字/秒`
- 英文：`> 17 字符/秒`
- translation_queue_size `>= 2`
- predicted_read_completion `< 0.75`

### 保护动作
按顺序启用：

1. 隐藏草稿翻译，仅保留草稿原文
2. 原文弱化，只突出翻译
3. 去除口头禅与重复词
4. 强制缩短句块长度
5. 旧字幕延长 0.3–0.5 秒，但最多积压 1 条

---

## 12. 状态机设计

```text
Listening
  ↓
DraftingSource
  ↓ (chunk_score >= threshold)
CommitCandidate
  ↓
CommittedSource
  ↓
CommittedTranslation
  ↓
SoftPostEdit(optional once)
  ↓
FadeHold
  ↓
Archived
```

---

## 13. 数据结构建议

```ts
type WordToken = {
  text: string
  startMs: number
  endMs: number
  confidence: number
  stable: boolean
}

type DraftSegment = {
  segmentId: string
  sourceText: string
  stablePrefixLength: number
  mutableTailText: string
  avgConfidence: number
  startMs: number
  lastUpdateMs: number
  silenceMs: number
  stabilityScore: number
  boundaryScore: number
  chunkScore: number
}

type CommittedSegment = {
  segmentId: string
  sourceText: string
  translationText: string
  startMs: number
  endMs: number
  committedAtMs: number
  translatedAtMs: number
  sourceRevisionCount: number
  translationRevisionCount: number
  glossaryHits: string[]
  displayDurationMs: number
}
```

---

## 14. 渲染层伪代码

```python
def on_partial_asr(partial_text, tokens, now_ms):
    draft = update_draft_segment(partial_text, tokens, now_ms)
    freeze_stable_prefix(draft, stable_window_ms=400, tail_word_limit=6)
    render_draft_source(draft)

    if should_commit(draft):
        committed = commit_source(draft)
        render_committed_source(committed)
        enqueue_translation(committed)

def on_translation_ready(segment_id, translation_text, now_ms):
    seg = get_committed_segment(segment_id)
    seg.translationText = apply_glossary_and_light_post_edit(translation_text, seg)
    seg.translatedAtMs = now_ms
    seg.displayDurationMs = compute_display_duration(seg)
    render_committed_translation(seg)
    schedule_fade(seg)

def compute_display_duration(seg):
    text = seg.translationText or seg.sourceText
    char_count = count_readable_units(text)
    cps = 7.0 if is_chinese(text) else 13.5
    reading_time = char_count / cps
    if bilingual_enabled():
        reading_time *= 1.15

    audio_span = max(1.0, (seg.endMs - seg.startMs) / 1000.0)
    return clamp(max(1.6, reading_time, audio_span), 1.2, 4.5)
```

---

## 15. 术语与实体策略

### 15.1 必做能力

### Glossary
用户可预置：

- 公司名
- 产品名
- 人名
- 地名
- 缩写
- 专业术语

### Entity Cache
会话级缓存：

- 已确认实体写法
- 已确认翻译
- 优先复用

### Number/Unit Guard
对以下模式加保护：

- 百分比
- 金额
- 日期
- 版本号
- 文件名
- 数量单位
- 容量单位

---

### 15.2 规则示例

```yaml
glossary:
  "LLM": "大语言模型"
  "token": "token"
  "Apple Silicon": "Apple Silicon"
  "vLLM": "vLLM"

entity_cache_policy:
  lock_after_occurrences: 2
  min_confidence_to_lock: 0.90

number_guard:
  protect_patterns:
    - percentage
    - version
    - date
    - memory_size
    - currency
```

---

## 16. 默认参数集（建议首版直接使用）

```yaml
audio:
  sample_rate_hz: 16000
  frame_ms: 20
  vad_window_ms: 200
  vad_speech_onset_ms: 120
  vad_speech_offset_ms: 220

asr:
  partial_refresh_ms: 100
  stable_prefix_window_ms: 400
  mutable_tail_words: 6
  min_avg_confidence_commit: 0.86

segmentation:
  min_silence_commit_ms: 280
  force_commit_audio_sec: 3.2
  ideal_chunk_chars_zh_min: 10
  ideal_chunk_chars_zh_max: 22
  hard_chunk_chars_zh_max: 30
  ideal_chunk_chars_en_min: 28
  ideal_chunk_chars_en_max: 56
  hard_chunk_chars_en_max: 84
  commit_threshold: 0.72

translation:
  max_context_segments: 1
  revision_limit: 1
  max_main_area_edit_distance_ratio: 0.18
  target_translation_latency_ms: 1400

display:
  min_hold_sec: 1.6
  max_hold_sec: 4.5
  bilingual_factor: 1.15
  previous_caption_fade_sec: 1.0
  max_visible_segments: 2

protection:
  fast_speech_trigger_zh_cps: 8.5
  fast_speech_trigger_en_cps: 17.0
  translation_queue_max: 2
```

---

## 17. 评估方法

### 17.1 离线评估

准备 3 类测试集：

1. **普通语速会议**
2. **高速直播/播客**
3. **专业术语密集内容**

每类至少统计：

- First Visible Token Latency
- Committed Translation Latency
- Read Completion Rate
- Rewrite Count
- Glossary Consistency
- Number Accuracy

---

### 17.2 在线埋点

建议埋点字段：

```json
{
  "segment_id": "seg_001",
  "first_token_latency_ms": 310,
  "source_commit_latency_ms": 860,
  "translation_commit_latency_ms": 1320,
  "source_revision_count": 1,
  "translation_revision_count": 0,
  "display_duration_ms": 2200,
  "predicted_read_completion": 0.93,
  "queue_depth": 0,
  "mode": "balanced"
}
```

---

### 17.3 A/B 测试建议

重点测这 4 组：

### 组 A：翻译是否草稿级显示
- A1：翻译随 partial 更新
- A2：翻译只在 committed 后显示

预期：A2 明显更优

### 组 B：上一条是否淡出保留
- B1：立即替换
- B2：保留 1 秒淡出

预期：B2 读完率更高

### 组 C：切块长度
- C1：更短更快
- C2：中等长度平衡

预期：C2 体验更稳

### 组 D：最大允许修正次数
- D1：无限修正
- D2：最多 1 次

预期：D2 主观满意度更高

---

## 18. 首版实现优先级

### P0：必须实现
- partial ASR
- stable prefix freeze
- committed source
- committed translation
- display_duration 公式
- 上一条淡出保留
- glossary
- revision limit = 1

### P1：强烈建议
- 自适应模式切换
- entity cache
- 极高速保护模式
- 低置信词标记
- 历史回看面板

### P2：增强
- 用户自定义阅读速度
- 按场景自动切模式
- 个性化术语学习
- speaker-aware 策略

---

## 19. 结论：推荐的最佳默认方案

首版产品建议直接采用下面这套默认策略：

> **原文草稿即时出现；草稿只更新尾部；当句块稳定后提交正式原文；翻译只对正式句块生成；正式翻译最多只修一次；字幕停留时长按阅读时间和音频时长联合计算；上一条保留短暂淡出。**

这套方案的优势是：

- **足够快**：用户不会觉得“没反应”
- **足够稳**：不会满屏抖动
- **足够可读**：字幕停留更合理
- **足够准**：术语和数字更容易控制
- **足够可实现**：状态机、参数、阈值都清晰

---

## 20. 产品验收标准

当以下条件同时满足时，可认为 UX 策略达标：

- 首字出现时间中位数 `< 400 ms`
- 正式翻译提交中位数 `< 1.6 s`
- 正式翻译平均修正次数 `<= 0.3 / 段`
- 读完率 `> 90%`
- 数字/单位准确率 `> 99%`
- 术语一致率 `> 95%`
- 用户主观反馈中“字幕乱跳”投诉显著低于基线版本
