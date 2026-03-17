# v2s Implementation Plan: UX Strategy Gap Analysis

**Reference strategy:** `docs/mac_realtime_subtitle_translation_strategy.md`
**Based on codebase snapshot:** March 2026

---

## 1. Gap Summary

| Area | Strategy Requirement | Current Status | Gap |
|---|---|---|---|
| Draft subtitle layer | Low-latency partial ASR display | Not shown in UI | ✅ Done |
| Stable prefix freeze | Split partial into `stable_prefix` + `mutable_tail` | Not implemented | ✅ Done |
| Commit trigger (ChunkScore) | Weighted 5-factor scoring formula | Ad-hoc thresholds | ✅ Done |
| Language profile model | Per-language CPS / chunk / speed thresholds | zh/en binary only | pending |
| Translation on committed only | Translate only stable sentences | Already correct | ✅ |
| Display duration formula | `max(min_hold, reading_time, audio_span)` | Simplified linear formula | ✅ Done |
| Previous caption fade hold | Retain last caption 0.8–1.5 s with fade | No retention | ✅ Done |
| 3-layer visual system | Draft / Committed / Fading-previous | Single committed layer | ✅ Done |
| Segment-level state machine | 7-state per-segment FSM | App-level 3-state only | ✅ Done |
| Rich data structures | `WordToken`, `DraftSegment`, `CommittedSegment` | `RecognizedSentence { text }` only | ✅ Done |
| Word-level timestamps & confidence | Per-word `startMs/endMs/confidence` | Not extracted from ASR | ✅ Done |
| Adaptive modes | Balanced / Follow / Reading | Single mode | ✅ Done |
| Extreme speed protection | Queue backlog detection + visual reduction | Not implemented | ✅ Done (SpeedMonitor) |
| Glossary / entity cache | User glossary + session entity lock | Not implemented | ✅ Done |
| Translation revision limit | Max 1 light edit, Levenshtein ≤ 0.18 | No revision logic | ✅ Done |

---

## 1b. Language Coverage Model

The original strategy document only gives examples for Chinese (zh) and English (en). All thresholds that vary by language must instead be driven by a **language profile** looked up from the **input/output locale identifier**. This ensures the system works equally well for Japanese, Korean, French, German, and any language added in the future.

### Script categories

| Category | Languages (current) | Characteristics |
|---|---|---|
| **Character-based** | zh-Hans, ja, ko | No word spaces · dense glyphs · lower CPS |
| **Alphabetic** | en, fr, de | Space-delimited words · higher CPS |
| **Future — RTL alphabetic** | ar, he (planned) | Same alphabetic rules, RTL rendering |

### Per-language profile table

| Language | CPS (display) | Ideal chunk | Hard max | Mutable tail | Fast-speech trigger |
|---|---|---|---|---|---|
| zh-Hans | 7.0 | 10–22 chars | 30 chars | 12 chars | 8.5 cps |
| ja | 7.5 | 10–22 chars | 30 chars | 12 chars | 9.0 cps |
| ko | 6.5 | 10–22 chars | 30 chars | 12 chars | 8.0 cps |
| en | 13.5 | 28–56 chars | 84 chars | 35 chars | 17.0 cps |
| fr | 13.0 | 32–62 chars | 90 chars | 38 chars | 16.5 cps |
| de | 11.5 | 28–56 chars | 84 chars | 35 chars | 15.0 cps |
| *(unknown)* | 13.5 | 28–56 chars | 84 chars | 35 chars | 17.0 cps |

### Code change required — `LanguageProfile` (P0)

**File:** `Sources/V2SApp/Models/LanguageProfile.swift` (new)

```swift
struct LanguageProfile: Sendable {
    let cps: Double                    // chars/sec for display duration
    let idealChunkMin: Int             // LengthFitScore peak start
    let idealChunkMax: Int             // LengthFitScore peak end
    let hardChunkMax: Int              // force-commit char ceiling
    let mutableTailChars: Int          // stable-prefix freeze tail size
    let fastSpeechCPSTrigger: Double   // speed-protection threshold

    static func profile(for localeIdentifier: String) -> LanguageProfile {
        switch localeIdentifier {
        case "zh-Hans", "zh-Hant", "zh":
            return LanguageProfile(cps: 7.0,  idealChunkMin: 10, idealChunkMax: 22,
                                   hardChunkMax: 30, mutableTailChars: 12, fastSpeechCPSTrigger: 8.5)
        case "ja":
            return LanguageProfile(cps: 7.5,  idealChunkMin: 10, idealChunkMax: 22,
                                   hardChunkMax: 30, mutableTailChars: 12, fastSpeechCPSTrigger: 9.0)
        case "ko":
            return LanguageProfile(cps: 6.5,  idealChunkMin: 10, idealChunkMax: 22,
                                   hardChunkMax: 30, mutableTailChars: 12, fastSpeechCPSTrigger: 8.0)
        case "fr":
            return LanguageProfile(cps: 13.0, idealChunkMin: 32, idealChunkMax: 62,
                                   hardChunkMax: 90, mutableTailChars: 38, fastSpeechCPSTrigger: 16.5)
        case "de":
            return LanguageProfile(cps: 11.5, idealChunkMin: 28, idealChunkMax: 56,
                                   hardChunkMax: 84, mutableTailChars: 35, fastSpeechCPSTrigger: 15.0)
        default: // en and unknown
            return LanguageProfile(cps: 13.5, idealChunkMin: 28, idealChunkMax: 56,
                                   hardChunkMax: 84, mutableTailChars: 35, fastSpeechCPSTrigger: 17.0)
        }
    }
}
```

**Where `LanguageProfile` is consumed:**

| Call site | Field used | Replaces |
|---|---|---|
| `LiveTranscriptionSession.emitDraftUpdate` | `idealChunkMin/Max`, `hardChunkMax` | hardcoded 72-char ceiling |
| `LiveTranscriptionSession.mutableTailCharCount` | `mutableTailChars` | hardcoded 12 / 35 |
| `AppModel.computeDisplayDuration` | `cps` | hardcoded 7.0 / 13.5 |
| `AppModel` speed check (§3.2) | `fastSpeechCPSTrigger` | hardcoded 8.5 / 17.0 |

`LiveTranscriptionSession` receives the **input** locale; `AppModel.computeDisplayDuration` uses the **output** (subtitle) locale.

---

## 2. P0 — Must Implement (blocks core UX)

### 2.1 Enrich ASR data structures

**File:** `Sources/V2SApp/Models/` (new file `SubtitleSegment.swift`)

Add the data types from the strategy §13:

```swift
struct WordToken {
    let text: String
    let startMs: Int
    let endMs: Int
    let confidence: Float   // 0.0–1.0
    var stable: Bool
}

struct DraftSegment {
    let segmentId: UUID
    var sourceText: String
    var stablePrefixLength: Int      // character count of frozen prefix
    var mutableTailText: String
    var avgConfidence: Float
    let startMs: Int
    var lastUpdateMs: Int
    var silenceMs: Int
    var stabilityScore: Float
    var boundaryScore: Float
    var chunkScore: Float
    var words: [WordToken]
}

struct CommittedSegment {
    let segmentId: UUID
    let sourceText: String
    var translationText: String
    let startMs: Int
    var endMs: Int
    let committedAtMs: Int
    var translatedAtMs: Int?
    var sourceRevisionCount: Int
    var translationRevisionCount: Int
    var glossaryHits: [String]
    var displayDurationMs: Int
}
```

**Changes required in `LiveTranscriptionSession.swift`:**
- Extract `SFTranscriptionSegment.timestamp`, `duration`, `confidence` from partial results
- Map segments to `[WordToken]`
- Pass `DraftSegment` (not just `RecognizedSentence`) up to `AppModel`

---

### 2.2 Replace sentence segmentation with ChunkScore

**File:** `Sources/V2SApp/Services/LiveTranscriptionSession.swift`

Current segmentation uses ad-hoc pause/length thresholds (~lines 400–600). Replace with the strategy §8.3 weighted formula:

```swift
struct ChunkScorer {
    // §8.3 weights
    static let wSilence:     Float = 0.30
    static let wStability:   Float = 0.20
    static let wBoundary:    Float = 0.20
    static let wLengthFit:   Float = 0.15
    static let wConfidence:  Float = 0.15

    static func score(_ draft: DraftSegment) -> Float {
        return wSilence    * silenceScore(draft.silenceMs)
             + wStability  * draft.stabilityScore
             + wBoundary   * draft.boundaryScore
             + wLengthFit  * lengthFitScore(draft.sourceText)
             + wConfidence * draft.avgConfidence
    }

    // silenceMs thresholds from §8.3
    private static func silenceScore(_ ms: Int) -> Float {
        switch ms {
        case ..<120:  return 0.0
        case 120..<250: return 0.4 + Float(ms - 120) / 130.0 * 0.3  // 0.4–0.7
        default:      return 1.0
        }
    }

    // Uses LanguageProfile.idealChunkMin/Max for the peak band.
    // Character-based scripts (zh, ja, ko): 10–22 chars = 1.0
    // Alphabetic scripts (en, fr, de): 28–56 chars = 1.0  (fr peak 32–62, de same as en)
    private static func lengthFitScore(_ text: String, profile: LanguageProfile) -> Float { /* ... */ }
}
```

**Commit thresholds (§8.3):**
- `score >= 0.72` → commit immediately
- `0.60–0.72` → wait 120–180 ms, re-evaluate
- `< 0.60` → do not commit

**Hard force-commit (§7.3 Condition D):**
- Audio duration >= `modeConfig.maxChunkAudioSec` (3.2 s default)
- Chars >= `LanguageProfile.hardChunkMax` (30 for character-based, 84–90 for alphabetic)

---

### 2.3 Implement stable prefix freeze

**File:** `Sources/V2SApp/Services/LiveTranscriptionSession.swift`

On every partial ASR update, split the text:

```swift
// Words that have not changed for >= stablePrefixWindowMs (400 ms default)
// are frozen into stable_prefix; only the last mutableTailWords (6) words remain mutable.
func updateStablePrefix(draft: inout DraftSegment, now: Int) {
    let stableWindowMs = 400
    let maxMutableWords = 6

    // Walk backwards from last update; words unchanged for > stableWindowMs → stable
    let stableWordCount = max(0, draft.words.count - maxMutableWords)
    draft.stablePrefixLength = draft.words.prefix(stableWordCount)
        .reduce(0) { $0 + $1.text.count + 1 }
    draft.mutableTailText = draft.words.dropFirst(stableWordCount)
        .map(\.text).joined(separator: " ")
}
```

---

### 2.4 Add draft subtitle layer to overlay

**File:** `Sources/V2SApp/UI/Overlay/OverlayView.swift`
**File:** `Sources/V2SApp/Models/OverlayPreviewState.swift`

Extend `OverlayPreviewState` to carry both layers:

```swift
struct OverlayPreviewState: Equatable {
    // Committed (shown at full opacity)
    let translatedText: String
    let sourceText: String
    let sourceName: String

    // Draft layer (shown at reduced opacity, source only)
    let draftSourceText: String?       // nil when no in-progress speech
    let draftStablePrefix: String?     // frozen part
    let draftMutableTail: String?      // changing part

    // Previous caption (fading out)
    let previousTranslatedText: String?
    let previousSourceText: String?
    let previousFadeProgress: Double   // 0.0 (opaque) → 1.0 (invisible)
}
```

**`OverlayView.swift` layout (3 layers, top to bottom):**

```
[Previous caption — 25–40% opacity, fading]
[Committed: source (80%) + translation (100%)]
[Draft: stable_prefix (60%) + mutable_tail (50%)]
```

Visual weights from strategy §4.1:
- Translation: 1.0 opacity
- Source (committed): 0.82 opacity
- Draft layer: 0.58 opacity
- Previous caption: 0.25–0.40, animated fade

---

### 2.5 Update display duration formula

**File:** `Sources/V2SApp/App/AppModel.swift`

Replace the current formula (`characterCount * 0.14 + 1.8`, capped 3–9 s) with the strategy §10 formula:

```swift
func computeDisplayDuration(segment: CommittedSegment, bilingual: Bool) -> Double {
    let text = segment.translationText.isEmpty ? segment.sourceText : segment.translationText
    let charCount = Double(text.unicodeScalars.count)

    // §10.2: CPS from LanguageProfile keyed on subtitle output locale
    // e.g. zh=7.0, ja=7.5, ko=6.5, en=13.5, fr=13.0, de=11.5
    let cps: Double = LanguageProfile.profile(for: outputLocaleIdentifier).cps
    var readingTime = charCount / cps

    // §10.2: bilingual penalty
    if bilingual { readingTime *= 1.15 }

    let audioSpan = max(1.0, Double(segment.endMs - segment.startMs) / 1000.0)

    // §10.3 min_hold tiers
    let minHold: Double
    switch charCount {
    case ..<10:   minHold = 1.2   // short
    case 10..<21: minHold = 1.6   // normal
    default:      minHold = 2.0   // long
    }

    return min(max(minHold, readingTime, audioSpan * 1.0), 4.5)
}
```

---

### 2.6 Previous caption fade hold

**File:** `Sources/V2SApp/App/AppModel.swift`

When a new `CommittedSegment` is committed:
1. Move the current displayed caption to `previousCaption`
2. Start a 1.0 s animation timer (`previous_caption_fade_sec` from §16)
3. Animate `previousFadeProgress` from 0 → 1 over 1.0 s
4. After fade completes, clear `previousCaption`

```swift
// In AppModel
private var previousCaption: CommittedSegment?
private var fadeTimer: Task<Void, Never>?

func commitNewCaption(_ segment: CommittedSegment) {
    previousCaption = currentCaption
    currentCaption = segment
    fadeTimer?.cancel()
    fadeTimer = Task {
        for step in 0...20 {
            let progress = Double(step) / 20.0
            await MainActor.run { overlayState.previousFadeProgress = progress }
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms steps over 1 s
        }
        await MainActor.run { previousCaption = nil }
    }
}
```

---

### 2.7 Segment-level state machine

**File:** `Sources/V2SApp/Models/` (new file `SegmentStateMachine.swift`)

Implement the 7-state FSM from strategy §12:

```swift
enum SegmentState {
    case listening
    case draftingSource
    case commitCandidate
    case committedSource
    case committedTranslation
    case softPostEdit
    case fadeHold
    case archived
}
```

Transitions:
- `listening` → `draftingSource`: first partial ASR token received
- `draftingSource` → `commitCandidate`: `chunkScore >= 0.60`
- `commitCandidate` → `committedSource`: `chunkScore >= 0.72` (or 180 ms elapsed and score still >= 0.60)
- `committedSource` → `committedTranslation`: translation received
- `committedTranslation` → `softPostEdit`: light post-edit available within 500–1000 ms window
- `softPostEdit` → `fadeHold`: revision applied or window expired
- `fadeHold` → `archived`: fade-out animation complete

---

### 2.8 Glossary enforcement

**File:** `Sources/V2SApp/Models/AppSettings.swift`
**File:** `Sources/V2SApp/Services/` (new file `GlossaryService.swift`)

Add to `AppSettings`:
```swift
var glossary: [String: String]   // source term → target term
```

`GlossaryService` applies glossary after translation:
```swift
actor GlossaryService {
    func apply(translation: String, glossary: [String: String]) -> String {
        var result = translation
        for (source, target) in glossary {
            result = result.replacingOccurrences(of: source, with: target,
                                                  options: .caseInsensitive)
        }
        return result
    }
}
```

Add glossary UI to `SettingsView.swift` (key-value list editor).

---

## 3. P1 — Strongly Recommended

### 3.1 Adaptive modes

**File:** `Sources/V2SApp/Models/AppSettings.swift`

```swift
enum SubtitleMode: String, Codable, CaseIterable {
    case balanced    // default
    case follow      // live/meetings
    case reading     // courses/lectures
}
```

**File:** `Sources/V2SApp/Services/` (new file `ModeConfig.swift`)

```swift
struct ModeConfig {
    let firstTokenTargetMs: Int
    let commitSourceTargetMs: Int
    let commitTranslationTargetMs: Int
    let maxChunkAudioSec: Double
    let minSilenceCommitMs: Int

    static let balanced = ModeConfig(
        firstTokenTargetMs: 350,
        commitSourceTargetMs: 900,
        commitTranslationTargetMs: 1400,
        maxChunkAudioSec: 3.2,
        minSilenceCommitMs: 280
    )
    static let follow = ModeConfig(
        firstTokenTargetMs: 250,
        commitSourceTargetMs: 700,
        commitTranslationTargetMs: 1100,
        maxChunkAudioSec: 2.4,
        minSilenceCommitMs: 180
    )
    static let reading = ModeConfig(
        firstTokenTargetMs: 450,
        commitSourceTargetMs: 1100,
        commitTranslationTargetMs: 1700,
        maxChunkAudioSec: 3.8,
        minSilenceCommitMs: 350
    )
}
```

Plumb `ModeConfig` through `LiveTranscriptionSession` (replace hard-coded thresholds).
Add mode picker to `StatusBarPopoverView.swift`.

---

### 3.2 Extreme speed protection

**File:** `Sources/V2SApp/App/AppModel.swift`

Trigger when any of (§11.4):
- Last 5 s speech rate > `LanguageProfile.fastSpeechCPSTrigger` for the input locale
  (e.g. zh 8.5 · ja 9.0 · ko 8.0 · en 17.0 · fr 16.5 · de 15.0)
- Translation queue size >= 2
- Predicted read completion < 0.75

Protection actions in order:
1. Hide draft translation, show draft source only
2. Weaken source text opacity, boost translation opacity
3. Strip filler words (optional NLP step)
4. Force shorter chunk size (reduce `maxChunkAudioSec` by 0.4 s)
5. Extend previous caption fade by 0.3–0.5 s (max 1 queued)

```swift
actor SpeedMonitor {
    private var recentChars: [(chars: Int, timestampMs: Int)] = []

    func record(chars: Int, at ms: Int) {
        recentChars.append((chars, ms))
        recentChars.removeAll { ms - $0.timestampMs > 5000 }
    }

    var currentCPS: Double {
        let window = recentChars.filter { /* last 5s */ }
        let total = window.reduce(0) { $0 + $1.chars }
        return Double(total) / 5.0
    }
}
```

---

### 3.3 Session entity cache

**File:** `Sources/V2SApp/Services/` (new file `EntityCache.swift`)

Lock confirmed entity translations after 2 occurrences with confidence >= 0.90 (§15.2):

```swift
actor EntityCache {
    private struct Entry {
        var translation: String
        var occurrences: Int
        var locked: Bool
    }
    private var cache: [String: Entry] = [:]

    func record(source: String, translation: String, confidence: Float) {
        var entry = cache[source] ?? Entry(translation: translation,
                                           occurrences: 0, locked: false)
        if confidence >= 0.90 { entry.occurrences += 1 }
        if entry.occurrences >= 2 { entry.locked = true }
        cache[source] = entry
    }

    func lookup(_ source: String) -> String? {
        cache[source]?.locked == true ? cache[source]?.translation : nil
    }
}
```

---

### 3.4 Translation revision limit

**File:** `Sources/V2SApp/App/AppModel.swift`

After displaying a `CommittedTranslation`, allow at most 1 revision within a 500–1000 ms window:

```swift
func maybeReviseTranslation(segmentId: UUID, revised: String) {
    guard let seg = committedSegments[segmentId],
          seg.translationRevisionCount < 1,
          Date().timeIntervalSince(seg.translatedAt) < 1.0
    else { return }

    let ratio = levenshteinDistanceRatio(seg.translationText, revised)
    if ratio <= 0.18 {
        committedSegments[segmentId]?.translationText = revised
        committedSegments[segmentId]?.translationRevisionCount += 1
        // re-render overlay
    }
    // if ratio > 0.18: only update history panel (not implemented yet)
}

// Levenshtein distance ratio helper
func levenshteinDistanceRatio(_ a: String, _ b: String) -> Double {
    let dist = levenshteinDistance(a, b)
    let maxLen = max(a.count, b.count)
    return maxLen == 0 ? 0.0 : Double(dist) / Double(maxLen)
}
```

---

### 3.5 Low-confidence word marking

In `OverlayView.swift`, render words with `confidence < 0.70` in a slightly different color (e.g., 65% white vs 100% white) using `AttributedString`.

---

## 4. P2 — Enhancements

### 4.1 User-configurable reading speed

Add a `cpsOverrides: [String: Double]` dictionary to `AppSettings` (locale-ID → cps).
When computing display duration, check `cpsOverrides[outputLocale]` first; fall back to
`LanguageProfile.profile(for: outputLocale).cps` if no override is set.
This lets power users tune reading speed per language independently.

### 4.2 Auto mode switching by scene

Detect meeting-style short turns (frequent commit triggers < 1.5 s apart) vs lecture style (long segments > 3 s) and auto-suggest or switch mode.

### 4.3 History/review panel

Secondary window or sheet showing all `CommittedSegment` records with source, translation, timestamps, and glossary hits. Allows post-session review and export to SRT/TXT.

### 4.4 Per-segment analytics (埋点)

Emit `SegmentMetrics` after each segment reaches `archived`:

```swift
struct SegmentMetrics: Codable {
    let segmentId: String
    let firstTokenLatencyMs: Int
    let sourceCommitLatencyMs: Int
    let translationCommitLatencyMs: Int
    let sourceRevisionCount: Int
    let translationRevisionCount: Int
    let displayDurationMs: Int
    let predictedReadCompletion: Double
    let queueDepth: Int
    let mode: String
}
```

Write to a rolling log file for offline evaluation (strategy §17.2).

### 4.5 Speaker-aware strategy

When multiple audio sources are mixed, track turn boundaries per speaker and apply independent segmentation windows.

---

## 5. Implementation Order

```
Phase 1 — Data & Core Logic (P0) ✅ DONE
  ├── 2.1  New data structures (SubtitleSegment.swift)          ✅
  ├── 2.2  ChunkScore-based segmentation                        ✅
  ├── 2.3  Stable prefix freeze                                 ✅
  └── 2.7  Segment-level state machine                         ✅

Phase 2 — Display Layer (P0) ✅ DONE
  ├── 2.4  3-layer overlay view                                 ✅
  ├── 2.5  Updated display duration formula                     ✅
  └── 2.6  Previous caption fade hold                          ✅

Phase 3 — Quality (P0 + P1) ✅ DONE
  ├── 2.8  Glossary service + settings UI                       ✅
  ├── 3.4  Translation revision limit                           ✅
  └── 3.5  Low-confidence word marking (draft layer dimming)    ✅

Phase 4 — Adaptive (P1) ✅ DONE
  ├── 3.1  Adaptive mode configs + UI picker                    ✅
  ├── 3.2  Extreme speed protection (SpeedMonitor)              ✅
  └── 3.3  Entity cache                                        ✅

Phase 5 — Analytics & Polish (P2, pending)
  ├── 4.1  User-configurable reading speed (per-language CPS override table)
  ├── 4.3  History/review panel (export to SRT/TXT)
  └── 4.4  Per-segment metrics log (SegmentMetrics → JSON)
```

---

## 6. Files Created / Modified

| File | Action | Status |
|---|---|---|
| `Models/LanguageProfile.swift` | Create — per-language CPS, chunk, tail, speed thresholds | pending |
| `Models/SubtitleSegment.swift` | Created | ✅ |
| `Models/SegmentStateMachine.swift` | Created | ✅ |
| `Models/ModeConfig.swift` | Created (+ ChunkScorer) | ✅ |
| `Services/GlossaryService.swift` | Created | ✅ |
| `Services/EntityCache.swift` | Created | ✅ |
| `Services/SpeedMonitor.swift` | Created | ✅ |
| `Services/LiveTranscriptionSession.swift` | partialHandler, ChunkScore, stable prefix, modeConfig | ✅ |
| `App/AppModel.swift` | fade hold, duration formula, glossary, revision limit, speed monitor | ✅ |
| `Models/OverlayPreviewState.swift` | draft + previous layers | ✅ |
| `Models/AppSettings.swift` | subtitleMode, glossary (backwards-compatible decoder) | ✅ |
| `UI/Overlay/OverlayView.swift` | 3-layer rendering | ✅ |
| `UI/Overlay/OverlayWindowController.swift` | dynamic height for 3 layers | ✅ |
| `UI/Settings/SettingsView.swift` | mode picker + glossary editor | ✅ |
| `UI/StatusBar/StatusBarPopoverView.swift` | mode quick-picker | ✅ |

---

## 7. Default Parameter Reference

All default values from strategy §16, for easy lookup during implementation:

```yaml
audio:
  sample_rate_hz: 16000
  frame_ms: 20
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
  # chunk thresholds are per-language — see §1b LanguageProfile table
  # character-based (zh/ja/ko): ideal 10–22, hard max 30
  # alphabetic (en/fr/de):      ideal 28–62, hard max 84–90
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
  # fast_speech_trigger_cps: per-language — see §1b LanguageProfile table
  # zh 8.5  · ja 9.0  · ko 8.0
  # en 17.0 · fr 16.5 · de 15.0
  translation_queue_max: 2
```

---

## 8. Acceptance Criteria (strategy §20)

The implementation is complete when **all** of the following hold on the standard test corpus:

- First visible token latency p50 **< 400 ms**
- Committed translation latency p50 **< 1.6 s**
- Translation revision rate **≤ 0.3 per segment**
- Read completion rate **> 90%**
- Number / unit accuracy **> 99%**
- Glossary consistency **> 95%**
- User-reported "subtitle jumping" complaints significantly lower than baseline
