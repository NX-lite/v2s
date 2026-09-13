# Real-Time Multi-Source Model Correction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional, local-first, per-sentence model correction to the existing multi-source subtitle pipeline, using audio to correct both original and translation when supported and automatically falling back to translation-only text correction when audio is rejected.

**Architecture:** Keep each `LiveTranscriptionSession` responsible for producing source-scoped sentence audio, and keep `AppModel` responsible for local subtitle state. Add an independent `RealtimeCorrectionCoordinator` that owns bounded per-source queues, two-request global concurrency, session-scoped audio capability, corrected context, and stale-result rejection. Reuse the existing HTTP transport and endpoint normalization while keeping correction credentials, state, prompts, and UI separate from the on-demand assistant.

**Tech Stack:** Swift 5.10 package manifest, Swift 6.4 compiler, macOS Speech and AVFoundation, SwiftUI, Combine, OpenAI-compatible Chat/Responses JSON, Gemini `generateContent`, Swift Testing, Node test runner, Xcode 26 CI, universal `arm64` plus `x86_64` Release build.

---

## Implementation Preconditions

Work in the existing `codex/upstream-rebuild-impl` worktree. The approved design is
`docs/superpowers/specs/2026-09-13-realtime-multisource-correction-design.md`.

The active developer directory is currently Command Line Tools, so local package
verification must use:

```bash
scripts/test-swift.sh --no-parallel
```

Run Xcode Debug/Release and universal-architecture verification on the existing
`macos-26` CI runner unless a full local Xcode is selected before the final gate.
Do not push, tag, publish a GitHub Release, or contact a real model provider without
separate user approval.

Provider wire-format references used by this plan:

- OpenAI Chat content supports an `input_audio` part containing base64 data and
  `format: "wav"`: <https://developers.openai.com/api/reference/cli/resources/chat>
- OpenAI Responses exposes an audio input content type:
  <https://developers.openai.com/api/reference/cli/resources/beta/subresources/responses>
- Gemini supports inline `audio/wav` data in `generateContent`:
  <https://ai.google.dev/gemini-api/docs/audio>

Use placeholder keys and `example.invalid` in every test. Never add real audio,
screenshots, transcripts, provider bodies, credentials, or machine-specific output
to the repository.

## File Responsibility Map

**Create**

- `Sources/V2SApp/Models/CorrectionSettings.swift`: persisted global/provider and
  per-source correction policy.
- `Sources/V2SApp/Models/CorrectionModels.swift`: correction jobs, context, results,
  mode, status, and prompt value types.
- `Sources/V2SApp/Services/SentenceAudioBuffer.swift`: bounded normalized PCM
  accumulation and deterministic in-memory WAV encoding.
- `Sources/V2SApp/Services/CorrectionPromptBuilder.swift`: pure, bounded prompt and
  structured-output construction.
- `Sources/V2SApp/Services/RealtimeCorrectionCoordinator.swift`: queueing,
  concurrency, fallback, context, cancellation, and provider-operation state.
- `Sources/V2SApp/UI/Settings/CorrectionSettingsSection.swift`: independent provider
  controls, privacy disclosure, and correction-mode status.
- `Tests/V2STests/CorrectionSettingsTests.swift`
- `Tests/V2STests/SentenceAudioBufferTests.swift`
- `Tests/V2STests/CorrectionPromptBuilderTests.swift`
- `Tests/V2STests/CorrectionProviderClientTests.swift`
- `Tests/V2STests/RealtimeCorrectionCoordinatorTests.swift`
- `Tests/V2STests/AppModelCorrectionIntegrationTests.swift`
- `Tests/V2STests/CorrectionSettingsSectionTests.swift`

**Modify**

- `Sources/V2SApp/Models/AppSettings.swift`: nested correction settings and
  field-by-field migration defaults.
- `Sources/V2SApp/Models/AssistantModels.swift`: per-entry source/language metadata
  for corrected multi-source Ask/Follow Up context.
- `Sources/V2SApp/Models/OverlayPreviewState.swift`: keep ID-addressable effective
  caption values compatible with correction backfill.
- `Sources/V2SApp/Services/LiveTranscriptionSession.swift`: produce optional WAV data
  with committed sentences and clear it on lifecycle transitions.
- `Sources/V2SApp/Services/OpenAIResponsesClient.swift`: correction-specific audio
  request encoding, typed audio rejection, and strict result decoding while
  preserving assistant image behavior.
- `Sources/V2SApp/Services/AssistantPromptBuilder.swift`: label each multi-source
  transcript entry with its source and language pair.
- `Sources/V2SApp/App/AppModel.swift`: own the correction coordinator, persist its
  independent settings, submit local commits, and safely backfill by caption ID.
- `Sources/V2SApp/UI/Settings/SettingsView.swift`: embed correction settings and
  per-source enable/isolation toggles.
- `Sources/V2SApp/UI/StatusBar/StatusBarPopoverView.swift`: show compact correction
  mode/warning state without adding screenshot behavior.
- `Sources/V2SApp/Localization/AppLocalization.swift`: correction strings in every
  existing localization dictionary.
- `Tests/V2STests/AppSettingsTests.swift`: integrated encoding/migration coverage.
- `Tests/V2STests/AppModelAssistantIntegrationTests.swift`: corrected multi-source
  snapshot coverage.
- `Tests/V2STests/LiveTranscriptionSessionTests.swift`: correction-audio lifecycle
  integration seams.
- `Tests/V2STests/OpenAIResponsesClientTests.swift`: preserve assistant image and
  error-classification behavior after shared client changes.
- `README.md` and `README.zh-CN.md`: feature, provider, fallback, and privacy behavior.
- `v2s.xcodeproj/project.pbxproj`: add every new production Swift file exactly once.

## Task 0: Baseline and Privacy Gate

**Files:** None.

- [ ] **Step 1: Verify the implementation branch and clean tree**

Run:

```bash
git branch --show-current
git status --short
git log -2 --oneline
```

Expected: branch is `codex/upstream-rebuild-impl`, status is clean before plan
execution, and the approved design commit `047c4e3` is present.

- [ ] **Step 2: Run the complete current tests**

Run:

```bash
scripts/test-swift.sh --no-parallel
node --test Tests/Docs/*.test.cjs
```

Expected: both commands pass before any production change. Record the exact Swift
test/suite totals in the execution notes; do not rely on an older CI run.

- [ ] **Step 3: Confirm ignored build output and secret hygiene**

Run:

```bash
git check-ignore .build
git ls-files | rg '(^|/)(\.build|DerivedData|xcuserdata|settings\.json|\.DS_Store)(/|$)' && exit 1 || true
rg -n '/Users/|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|sk-[A-Za-z0-9]{12,}' Sources Tests README.md README.zh-CN.md && exit 1 || true
```

Expected: `.build` is ignored; the two scans print no tracked machine content,
private key, or plausible live API key.

## Task 1: Persist Independent Correction Settings

**Files:**

- Create: `Sources/V2SApp/Models/CorrectionSettings.swift`
- Create: `Tests/V2STests/CorrectionSettingsTests.swift`
- Modify: `Sources/V2SApp/Models/AppSettings.swift`
- Modify: `Tests/V2STests/AppSettingsTests.swift`

- [ ] **Step 1: Write failing settings tests**

Add Swift Testing cases that establish the exact contract:

```swift
@Suite struct CorrectionSettingsTests {
    @Test func defaultsArePrivateAndIndependentFromAssistant() {
        let value = CorrectionSettings.default
        #expect(value.isEnabled == false)
        #expect(value.apiKey == "")
        #expect(value.baseURL == "https://api.openai.com/v1")
        #expect(value.model == "gpt-4o")
        #expect(value.disabledSourceIDs == [])
        #expect(value.isolatedContextSourceIDs == [])
    }

    @Test func malformedFieldFallsBackWithoutDiscardingValidFields() throws {
        let data = Data(#"{"isEnabled":true,"apiKey":"kept","baseURL":9,"model":"audio-model","disabledSourceIDs":["mic-1"]}"#.utf8)
        let value = try JSONDecoder().decode(CorrectionSettings.self, from: data)
        #expect(value.isEnabled)
        #expect(value.apiKey == "kept")
        #expect(value.baseURL == CorrectionSettings.default.baseURL)
        #expect(value.model == "audio-model")
        #expect(value.disabledSourceIDs == ["mic-1"])
    }
}
```

Extend `AppSettingsTests` with legacy JSON that has no `correction` key and assert
`decoded.correction == .default`. Add a round-trip with correction enabled and two
sorted source-ID lists; assert assistant credentials remain unchanged.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
scripts/test-swift.sh --no-parallel --filter 'CorrectionSettingsTests|AppSettingsTests'
```

Expected: compilation fails because `CorrectionSettings` and
`AppSettings.correction` do not exist.

- [ ] **Step 3: Implement the settings contract**

Create this value shape with a field-by-field decoder matching `AssistantSettings`:

```swift
struct CorrectionSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var apiKey: String
    var baseURL: String
    var model: String
    var disabledSourceIDs: [String]
    var isolatedContextSourceIDs: [String]

    static let `default` = Self(
        isEnabled: false,
        apiKey: "",
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4o",
        disabledSourceIDs: [],
        isolatedContextSourceIDs: []
    )

    func isEnabled(for sourceID: String) -> Bool {
        isEnabled && !disabledSourceIDs.contains(sourceID)
    }

    func usesIsolatedContext(for sourceID: String) -> Bool {
        isolatedContextSourceIDs.contains(sourceID)
    }
}
```

Normalize both source-ID arrays with `Array(Set(values)).sorted()` before assigning
decoded or UI-updated values. Add `var correction: CorrectionSettings` to
`AppSettings`, decode missing/malformed nested correction as `.default`, pass it
through the memberwise initializer, and include it in `AppSettings.default`.

Place the custom decoder in an extension so the memberwise initializer used by
`.default` and tests remains available. Decode every field independently:

```swift
init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? Self.default.isEnabled
    apiKey = (try? c.decodeIfPresent(String.self, forKey: .apiKey)) ?? Self.default.apiKey
    baseURL = (try? c.decodeIfPresent(String.self, forKey: .baseURL)) ?? Self.default.baseURL
    model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? Self.default.model
    disabledSourceIDs = Array(Set(
        (try? c.decodeIfPresent([String].self, forKey: .disabledSourceIDs)) ?? []
    )).sorted()
    isolatedContextSourceIDs = Array(Set(
        (try? c.decodeIfPresent([String].self, forKey: .isolatedContextSourceIDs)) ?? []
    )).sorted()
}
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command.

Expected: all correction and existing settings tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/V2SApp/Models/CorrectionSettings.swift Sources/V2SApp/Models/AppSettings.swift Tests/V2STests/CorrectionSettingsTests.swift Tests/V2STests/AppSettingsTests.swift
git commit -m "feat: add private correction settings"
```

## Task 2: Preserve Local and Corrected Caption Identity

**Files:**

- Create: `Sources/V2SApp/Models/CorrectionModels.swift`
- Modify: `Sources/V2SApp/Models/AssistantModels.swift`
- Modify: `Sources/V2SApp/Services/AssistantPromptBuilder.swift`
- Modify: `Sources/V2SApp/App/AppModel.swift`
- Modify: `Tests/V2STests/AppModelAssistantIntegrationTests.swift`
- Modify: `Tests/V2STests/AssistantPromptBuilderTests.swift`

- [ ] **Step 1: Write failing caption-record and assistant-context tests**

Add tests for effective-value selection and per-entry metadata:

```swift
@Test func transcriptEntryPrefersCorrectionsButRetainsLocalValues() {
    var entry = TranscriptEntry(
        id: UUID(), sourceID: "mic-1", sourceName: "Desk Mic",
        sourceLanguageID: "en", targetLanguageID: "zh-Hans",
        localSourceText: "local source", localTranslatedText: "本地翻译"
    )
    #expect(entry.sourceText == "local source")
    #expect(entry.translatedText == "本地翻译")
    entry.correctedSourceText = "correct source"
    entry.correctedTranslatedText = "纠正翻译"
    #expect(entry.sourceText == "correct source")
    #expect(entry.translatedText == "纠正翻译")
    #expect(entry.localSourceText == "local source")
}

@Test func promptLabelsEveryTranscriptEntryWithItsSourceAndLanguages() {
    let prompt = AssistantPromptBuilder().build(
        action: .ask,
        snapshot: multiSourceSnapshot(),
        settings: .default,
        currentTime: Date(timeIntervalSince1970: 120),
        hasScreenshot: false,
        ocrText: nil
    )
    #expect(prompt.userContent.contains("source: Desk Mic"))
    #expect(prompt.userContent.contains("languages: English (en) -> Chinese (zh-Hans)"))
}
```

Update existing fixtures to provide source ID/name and language pair. Do not remove
the snapshot-level language fields; they remain the fallback for legacy/single-source
callers.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
scripts/test-swift.sh --no-parallel --filter 'AppModelAssistantIntegrationTests|AssistantPromptBuilderTests'
```

Expected: compile failures for the new transcript initializer and metadata fields.

- [ ] **Step 3: Add correction domain values and effective caption storage**

Define these module contracts in `CorrectionModels.swift`:

```swift
enum CorrectionInputMode: Equatable, Sendable { case audio, textOnly }

enum CorrectionStatus: Equatable, Sendable {
    case disabled
    case ready
    case audio
    case textOnly
    case warning(String)
}

enum CorrectionModelFetchState: Equatable, Sendable {
    case idle
    case fetching
    case fetched([String])
    case failed(String?)
}

enum CorrectionAPITestState: Equatable, Sendable {
    case idle
    case testing
    case passed(String)
    case failed(String?)
}

struct CorrectionContextEntry: Equatable, Sendable {
    let captionID: UUID
    let capturedAt: Date
    let sourceID: String
    let sourceName: String
    let sourceLanguageID: String
    let targetLanguageID: String
    let original: String
    let translation: String
}

struct CorrectionJob: Equatable, Sendable {
    let captionID: UUID
    let sessionGeneration: Int
    let capturedAt: Date
    let sourceID: String
    let sourceName: String
    let sourceLanguageID: String
    let targetLanguageID: String
    let localOriginal: String
    let localTranslation: String
    let audioWAVData: Data?
}

struct CorrectionResult: Equatable, Sendable {
    let captionID: UUID
    let sessionGeneration: Int
    let sourceID: String
    let correctedOriginal: String?
    let correctedTranslation: String
    let mode: CorrectionInputMode
}
```

Replace the two stored display strings in `TranscriptEntry` with local plus optional
corrected values and computed `sourceText`/`translatedText`. Keep a compatibility
initializer accepting `sourceText` and `translatedText` so unrelated tests and
preview code do not need mechanical rewrites.

Extend `AssistantTranscriptEntry` with `sourceName`, `sourceLanguageID`,
`sourceLanguageName`, `targetLanguageID`, and `targetLanguageName`. Format these
fields in every prompt transcript line.

- [ ] **Step 4: Run focused and compatibility tests**

Run:

```bash
scripts/test-swift.sh --no-parallel --filter 'AppModelAssistantIntegrationTests|AssistantPromptBuilderTests|TranscriptSummarizerTests'
```

Expected: all selected tests pass and assistant prompt ordering remains unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/V2SApp/Models/CorrectionModels.swift Sources/V2SApp/Models/AssistantModels.swift Sources/V2SApp/Services/AssistantPromptBuilder.swift Sources/V2SApp/App/AppModel.swift Tests/V2STests/AppModelAssistantIntegrationTests.swift Tests/V2STests/AssistantPromptBuilderTests.swift
git commit -m "refactor: retain local and corrected captions"
```

## Task 3: Build a Bounded Sentence Audio Buffer

**Files:**

- Create: `Sources/V2SApp/Services/SentenceAudioBuffer.swift`
- Create: `Tests/V2STests/SentenceAudioBufferTests.swift`

- [ ] **Step 1: Write failing PCM/WAV tests**

Use synthetic samples only:

```swift
@Suite struct SentenceAudioBufferTests {
    @Test func finishEncodesMono16KPCM16WAVAndClearsFrames() throws {
        var buffer = SentenceAudioBuffer(sampleRate: 16_000, maximumDuration: 15)
        buffer.append(samples: [-1, 0, 0.5, 1])
        let wav = try #require(buffer.finish())
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(wav.littleEndianUInt32(at: 24) == 16_000)
        #expect(wav.littleEndianUInt16(at: 22) == 1)
        #expect(wav.littleEndianUInt16(at: 34) == 16)
        #expect(buffer.frameCount == 0)
    }

    @Test func capacityKeepsNewestFifteenSeconds() {
        var buffer = SentenceAudioBuffer(sampleRate: 4, maximumDuration: 2)
        buffer.append(samples: Array(repeating: 0.1, count: 12))
        #expect(buffer.frameCount == 8)
    }

    @Test func consumeThroughTimeReturnsPrefixAndKeepsTail() {
        var buffer = SentenceAudioBuffer(sampleRate: 4, maximumDuration: 15)
        buffer.append(samples: [0, 0.1, 0.2, 0.3, 0.4, 0.5])
        let first = buffer.finish(through: 1.0)
        #expect(first != nil)
        #expect(buffer.frameCount == 2)
    }
}
```

Test empty finish returns `nil`, values clamp to signed PCM16, integer fields are
little-endian, `reset()` empties state, and payload bytes never appear in a textual
description. Define private `littleEndianUInt16(at:)` and
`littleEndianUInt32(at:)` test helpers in this test file by combining indexed bytes;
do not add them to production `Data` API.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `scripts/test-swift.sh --no-parallel --filter SentenceAudioBufferTests`

Expected: compilation fails because `SentenceAudioBuffer` does not exist.

- [ ] **Step 3: Implement bounded accumulation and WAV encoding**

Use this API:

```swift
struct SentenceAudioBuffer {
    let sampleRate: Int
    let maximumDuration: TimeInterval
    private(set) var samples: [Float] = []
    private var emittedFrameCount = 0

    var frameCount: Int { samples.count }
    mutating func append(samples newSamples: [Float])
    mutating func append(_ buffer: AVAudioPCMBuffer)
    mutating func finish(through absoluteTime: TimeInterval? = nil) -> Data?
    mutating func reset()
}
```

`finish(through:)` converts an absolute recognition-task time into an absolute frame
index, subtracts `emittedFrameCount`, encodes only the available prefix, removes it,
and advances the emitted count. `reset()` also resets the absolute frame cursor.
The WAV encoder writes a 44-byte RIFF/WAVE header and signed little-endian PCM16.
Clamp floats to `-1...1`; map `-1` to `Int16.min` and `1` to `Int16.max`.

Cap retained samples at `sampleRate * maximumDuration` (240,000 frames for the
production 15-second limit) by dropping oldest frames and advancing the absolute
cursor. This bounds memory even if recognition stops returning results.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command.

Expected: all WAV header, slicing, capacity, empty, and reset tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/V2SApp/Services/SentenceAudioBuffer.swift Tests/V2STests/SentenceAudioBufferTests.swift
git commit -m "feat: buffer committed sentence audio"
```

## Task 4: Attach Audio to Recognized Sentences

**Files:**

- Modify: `Sources/V2SApp/Services/LiveTranscriptionSession.swift`
- Modify: `Tests/V2STests/LiveTranscriptionSessionTests.swift`

- [ ] **Step 1: Write failing lifecycle tests**

Extend `RecognizedSentence` tests and add an internal test seam that exercises the
same production buffer:

```swift
@Test func recognizedSentenceCarriesOptionalWAVWithoutChangingTextIdentity() {
    let wav = Data([0x52, 0x49, 0x46, 0x46])
    let sentence = RecognizedSentence(text: "hello", promotionSegmentID: nil, audioWAVData: wav)
    #expect(sentence.text == "hello")
    #expect(sentence.audioWAVData == wav)
}

@Test func disablingCorrectionAudioClearsAccumulatedFrames() {
    let session = LiveTranscriptionSession()
    session.setCorrectionAudioCaptureEnabledForTesting(true)
    session.appendCorrectionSamplesForTesting([0.1, 0.2])
    #expect(session.correctionAudioFrameCountForTesting == 2)
    session.setCorrectionAudioCaptureEnabledForTesting(false)
    #expect(session.correctionAudioFrameCountForTesting == 0)
}
```

Also test `stop()` and recognition-generation reset clear the accumulator. Keep the
test seam internal and limited to forwarding to `SentenceAudioBuffer`; do not expose
captured bytes through logs or UI.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `scripts/test-swift.sh --no-parallel --filter LiveTranscriptionSessionTests`

Expected: compile failures for the audio field and capture-control methods.

- [ ] **Step 3: Integrate the accumulator on the capture queue**

Add `audioWAVData: Data? = nil` to `RecognizedSentence` and
`CommittedEmission`. Add a `SentenceAudioBuffer(sampleRate: 16_000,
maximumDuration: 15)` and a capture-enabled flag to the session.

In `append(audioBuffer:)`, append the boosted `processingBuffer` to the sentence
buffer before branching to SpeechAnalyzer or legacy recognition, but only when the
flag is enabled. Add:

```swift
func setCorrectionAudioCaptureEnabled(_ enabled: Bool) {
    captureQueue.async { [weak self] in
        guard let self else { return }
        self.correctionAudioCaptureEnabled = enabled
        if !enabled { self.sentenceAudioBuffer.reset() }
    }
}
```

For legacy recognition, attach `finish(through: segmentEndTime)` to each outer
`CommittedEmission`. For SpeechAnalyzer commits and silence commits without reliable
segment timing, attach `finish()` for the containing utterance. When
`splitCommittedEmissionUnits` turns one emission into multiple text units, reuse the
immutable `Data` payload for each unit as the documented containing-utterance
fallback. Reset audio on stop, failed startup, recognition-generation reset, and
capture disablement.

- [ ] **Step 4: Run focused and recognition regression tests**

Run:

```bash
scripts/test-swift.sh --no-parallel --filter 'LiveTranscriptionSessionTests|SentenceAudioBufferTests|SentenceBoundaryHeuristicsTests'
```

Expected: all selected tests pass; existing sentence splitting and promotion IDs are
unchanged when audio capture is off.

- [ ] **Step 5: Commit**

```bash
git add Sources/V2SApp/Services/LiveTranscriptionSession.swift Tests/V2STests/LiveTranscriptionSessionTests.swift
git commit -m "feat: emit audio with committed sentences"
```

## Task 5: Build Deterministic Correction Prompts

**Files:**

- Create: `Sources/V2SApp/Services/CorrectionPromptBuilder.swift`
- Create: `Tests/V2STests/CorrectionPromptBuilderTests.swift`

- [ ] **Step 1: Write failing prompt tests**

Cover audio and text-only modes, six-entry trimming, global ordering, source labels,
language IDs, empty local translation, and absence of screenshot language:

```swift
@Test func audioPromptRequestsBothFieldsAndIncludesCorrectedContext() {
    let prompt = CorrectionPromptBuilder().build(
        job: sampleJob(), context: sevenContextEntries(), mode: .audio
    )
    #expect(prompt.userContent.contains("Current source: Desk Mic [mic-1]"))
    #expect(prompt.userContent.contains("Local original: hello"))
    #expect(prompt.userContent.contains("Local translation: 你好"))
    #expect(prompt.userContent.contains("correctedOriginal"))
    #expect(prompt.userContent.contains("correctedTranslation"))
    #expect(prompt.userContent.contains("app-2"))
    #expect(!prompt.userContent.contains("oldest-entry"))
    #expect(!prompt.userContent.localizedCaseInsensitiveContains("screenshot"))
}

@Test func textOnlyPromptPreservesOriginalAndRequestsOnlyTranslation() {
    let prompt = CorrectionPromptBuilder().build(
        job: sampleJob(), context: [], mode: .textOnly
    )
    #expect(prompt.instructions.contains("Do not rewrite the local original"))
    #expect(!prompt.userContent.contains("\"correctedOriginal\""))
    #expect(prompt.userContent.contains("\"correctedTranslation\""))
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `scripts/test-swift.sh --no-parallel --filter CorrectionPromptBuilderTests`

Expected: compilation fails because the builder and `CorrectionPrompt` are absent.

- [ ] **Step 3: Implement the pure builder**

Add `CorrectionPrompt { instructions, userContent, mode }` to
`CorrectionModels.swift`. Implement:

```swift
struct CorrectionPromptBuilder {
    static let contextLimit = 6

    func build(
        job: CorrectionJob,
        context: [CorrectionContextEntry],
        mode: CorrectionInputMode
    ) -> CorrectionPrompt
}
```

Sort context by `capturedAt`, take the final six entries, normalize whitespace, and
format each as timestamp, source name/ID, language pair, original, and translation.
The audio instruction must require one JSON object with exactly the two named string
fields. The text-only instruction must require only `correctedTranslation` and state
that the local original is immutable. Do not include settings secrets, raw audio,
screen state, or unbounded history in prompt text.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command.

Expected: all prompt snapshots pass deterministically.

- [ ] **Step 5: Commit**

```bash
git add Sources/V2SApp/Models/CorrectionModels.swift Sources/V2SApp/Services/CorrectionPromptBuilder.swift Tests/V2STests/CorrectionPromptBuilderTests.swift
git commit -m "feat: build bounded correction prompts"
```

## Task 6: Add Audio-Aware Provider Requests and Strict Results

**Files:**

- Modify: `Sources/V2SApp/Services/OpenAIResponsesClient.swift`
- Create: `Tests/V2STests/CorrectionProviderClientTests.swift`
- Modify: `Tests/V2STests/OpenAIResponsesClientTests.swift`

- [ ] **Step 1: Write failing provider-wire tests**

Using `StubHTTPTransport`, assert these exact shapes:

```swift
@Test func chatCorrectionSendsInputAudioWAVPart() async throws {
    let transport = StubHTTPTransport(stubs: [.init(status: 200, data: chatResponse(#"{"correctedOriginal":"hello","correctedTranslation":"你好"}"#))])
    let client = makeClient(baseURL: "https://example.invalid/v1", transport: transport)
    let output = try await client.correct(prompt: audioPrompt(), audioWAVData: Data([1, 2]))
    let body = try requestBody(await transport.firstRequest())
    let messages = try #require(body["messages"] as? [[String: Any]])
    let parts = try #require(messages.last?["content"] as? [[String: Any]])
    let audio = try #require(parts.first { $0["type"] as? String == "input_audio" })
    #expect((audio["input_audio"] as? [String: Any])?["format"] as? String == "wav")
    #expect((audio["input_audio"] as? [String: Any])?["data"] as? String == "AQI=")
    #expect(output.correctedOriginal == "hello")
}
```

Define `makeClient`, `audioPrompt`, and `requestBody` locally in the new test file.
Build `chatResponse(_:)` with `JSONSerialization.data(withJSONObject:)` so the model
output string is escaped correctly; do not depend on file-private helpers from
`OpenAIResponsesClientTests.swift`.

Add equivalent tests for Responses `input_audio` and Gemini
`inline_data: { mime_type: "audio/wav", data: "AQI=" }`. Add text-only tests that
assert no audio/image/inline-data part exists. Add output tests that reject code
fences, prose, empty strings, and a missing mode-required field.

Add error classification tests: HTTP 400 with an audio/speech capability message is
`.audioUnsupported`; 401, 403, 429, and 5xx remain `.http`; timeout/transport remains
`.invalidResponse`; all descriptions redact the placeholder key. Rerun existing
image tests to ensure `.imageUnsupported` is unchanged.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
scripts/test-swift.sh --no-parallel --filter 'CorrectionProviderClientTests|OpenAIResponsesClientTests'
```

Expected: compilation fails for `correct`, typed correction output, and
`.audioUnsupported`.

- [ ] **Step 3: Implement correction-specific client entry points**

Add:

```swift
struct CorrectionProviderOutput: Equatable, Sendable {
    let correctedOriginal: String?
    let correctedTranslation: String
}

func correct(
    prompt: CorrectionPrompt,
    audioWAVData: Data?
) async throws -> CorrectionProviderOutput
```

Reuse `validatedRequestConfiguration()` and existing endpoint resolution. For Chat,
encode `{type:"input_audio", input_audio:{data,format:"wav"}}`; for Responses,
encode the corresponding `input_audio` content part; for Gemini, append
`GeminiPart(inlineData: .init(mimeType: "audio/wav", data: ...))`.

Generalize `successfulData` to classify the attachment actually sent:

```swift
private enum SentMediaKind { case none, image, audio }
```

Keep authentication/rate-limit/server exclusions for both media types. Audio
keywords are `audio`, `speech`, `voice`, `input_audio`, `inline_data`,
`multimodal`, and `multi-modal`. Do not classify a generic bad request as a
capability failure without one of those terms.

Extract output text through the existing Chat/Responses/Gemini decoders, then decode
that text directly as JSON. Do not strip code fences or prose. Trim returned strings;
audio mode requires both non-empty fields, while text-only requires a non-empty
translation and ignores an unknown original field.

- [ ] **Step 4: Run provider and assistant regressions**

Run:

```bash
scripts/test-swift.sh --no-parallel --filter 'CorrectionProviderClientTests|OpenAIResponsesClientTests|AssistantCoordinatorTests'
```

Expected: correction wire tests and all prior image/fallback tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/V2SApp/Services/OpenAIResponsesClient.swift Tests/V2STests/CorrectionProviderClientTests.swift Tests/V2STests/OpenAIResponsesClientTests.swift
git commit -m "feat: send correction audio to model providers"
```

## Task 7: Implement Bounded Multi-Source Scheduling

**Files:**

- Create: `Sources/V2SApp/Services/RealtimeCorrectionCoordinator.swift`
- Create: `Tests/V2STests/RealtimeCorrectionCoordinatorTests.swift`

- [ ] **Step 1: Write failing scheduler and fallback tests**

Create an actor-backed fake responder whose held calls expose source ID, prompt,
mode, and audio. Write tests proving:

```swift
@Test @MainActor func sameSourceIsSequentialAndDifferentSourcesReachTwoWayConcurrency() async {
    let responder = HeldCorrectionResponder()
    let coordinator = makeCoordinator(responder: responder)
    coordinator.beginSession()
    coordinator.enqueue(job(sourceID: "mic-1", sequence: 1))
    coordinator.enqueue(job(sourceID: "mic-1", sequence: 2))
    coordinator.enqueue(job(sourceID: "app-1", sequence: 1))
    coordinator.enqueue(job(sourceID: "app-2", sequence: 1))
    await waitUntil { await responder.activeSourceIDs() == Set(["mic-1", "app-1"]) }
    #expect(await responder.maximumConcurrentCallCount() == 2)
    #expect(!(await responder.startedSequences(for: "mic-1").contains(2)))
}

@Test @MainActor func fourthWaitingJobDropsOldestWaitingNotActive() async {
    let responder = HeldCorrectionResponder()
    let coordinator = makeCoordinator(responder: responder)
    coordinator.beginSession()
    for sequence in 1...5 { coordinator.enqueue(job(sourceID: "mic-1", sequence: sequence)) }
    #expect(coordinator.waitingCaptionIDs(for: "mic-1") == [id(3), id(4), id(5)])
    #expect(coordinator.skippedCaptionIDs == [id(2)])
}
```

In the test file, define `id(_:)` as a deterministic UUID factory,
`job(sourceID:sequence:)` as a complete `CorrectionJob` fixture, and a
deadline-based `waitUntil` using `ContinuousClock` plus 10 ms sleeps. Do not use a
fixed count of `Task.yield()` calls.

Also test: global context uses the latest six successful entries in capture order;
isolated jobs use only their source; failed/skipped jobs never enter context; an audio
rejection retries once without audio and changes status to text-only for later jobs;
401/429/timeout do not downgrade; `endSession()` and provider changes ignore held
late results; disabling one source cancels only that source.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `scripts/test-swift.sh --no-parallel --filter RealtimeCorrectionCoordinatorTests`

Expected: compilation fails because the coordinator and responder protocol are
absent.

- [ ] **Step 3: Implement the main-actor scheduler**

Define:

```swift
protocol CorrectionResponding: Sendable {
    func validate(settings: CorrectionSettings) throws
    func fetchAvailableModels(settings: CorrectionSettings) async throws -> [String]
    func testConnection(settings: CorrectionSettings) async throws -> String
    func correct(
        settings: CorrectionSettings,
        prompt: CorrectionPrompt,
        audioWAVData: Data?
    ) async throws -> CorrectionProviderOutput
}

struct OpenAICorrectionResponder: CorrectionResponding {
    let transport: any HTTPTransport

    func validate(settings: CorrectionSettings) throws
    func fetchAvailableModels(settings: CorrectionSettings) async throws -> [String]
    func testConnection(settings: CorrectionSettings) async throws -> String
    func correct(
        settings: CorrectionSettings,
        prompt: CorrectionPrompt,
        audioWAVData: Data?
    ) async throws -> CorrectionProviderOutput
}

@MainActor
final class RealtimeCorrectionCoordinator: ObservableObject {
    @Published var settings: CorrectionSettings
    @Published private(set) var status: CorrectionStatus
    @Published private(set) var modelFetchState: CorrectionModelFetchState
    @Published private(set) var apiTestState: CorrectionAPITestState
    private(set) var sessionGeneration: Int
    var onResult: ((CorrectionResult) -> Void)?

    init(
        settings: CorrectionSettings = .default,
        responder: any CorrectionResponding = OpenAICorrectionResponder(
            transport: URLSessionHTTPTransport()
        ),
        promptBuilder: CorrectionPromptBuilder = CorrectionPromptBuilder()
    )

    func beginSession()
    func enqueue(_ job: CorrectionJob)
    func cancel(sourceID: String)
    func endSession()
    func fetchModels()
    func testAPI()
}
```

Use main-actor dictionaries for `waitingBySource`, `activeTaskBySource`, and
successful context. `drain()` repeatedly chooses the oldest captured head job among
inactive sources until two tasks are active. Removing a job from a source queue before
starting it makes the three-item limit apply only to waiting jobs.

Expose `waitingCaptionIDs(for:)` and `skippedCaptionIDs` as internal, read-only
diagnostics for deterministic tests; neither diagnostic may contain audio or text.

At dispatch, choose global or isolated context from the coordinator's current
`settings.usesIsolatedContext(for:)` value, then capture `sessionGeneration`,
provider settings, mode, and prompt before starting each task.
On completion, re-enter the main actor, verify generation and source task identity,
append one successful context entry, invoke `onResult`, clear active state, and
drain again. On `.audioUnsupported`, set session mode to text-only and retry that job
exactly once with `audioWAVData: nil`. Other errors publish a sanitized warning and
finish without context.

Implement model fetch/test with their own generations as in `AssistantCoordinator`.
Only changes to API key, base URL, or model invalidate provider work; per-source
policy changes cancel the affected scope through explicit coordinator methods.
`OpenAICorrectionResponder` creates an `OpenAIResponsesClient` from the correction
settings for each operation and delegates validation, model discovery, connection
test, and correction. It never reads `AssistantSettings`.

For each job, choose audio mode only when the session has not downgraded and the job
has non-empty WAV data. A job without audio uses text-only mode without marking the
model unsupported. Only a typed `.audioUnsupported` response changes the
session-scoped capability.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command.

Expected: all ordering, concurrency, overflow, context, fallback, and cancellation
tests pass repeatedly. Run the suite three times to expose scheduler flakiness:

```bash
for run in 1 2 3; do scripts/test-swift.sh --no-parallel --filter RealtimeCorrectionCoordinatorTests; done
```

- [ ] **Step 5: Commit**

```bash
git add Sources/V2SApp/Services/RealtimeCorrectionCoordinator.swift Tests/V2STests/RealtimeCorrectionCoordinatorTests.swift
git commit -m "feat: coordinate bounded realtime correction"
```

## Task 8: Integrate Local-First Submission and Safe Backfill

**Files:**

- Modify: `Sources/V2SApp/App/AppModel.swift`
- Modify: `Sources/V2SApp/Models/OverlayPreviewState.swift`
- Modify: `Sources/V2SApp/Services/LiveTranscriptionSession.swift`
- Create: `Tests/V2STests/AppModelCorrectionIntegrationTests.swift`
- Modify: `Tests/V2STests/AppModelAssistantIntegrationTests.swift`

- [ ] **Step 1: Write failing application-integration tests**

Inject a held correction responder and use focused AppModel test seams that call the
same submit/backfill helpers as production. Prove local-first behavior:

```swift
@Test @MainActor func localCaptionDisplaysBeforeCorrectionAndBackfillsByID() async {
    let fixture = makeCorrectionEnabledModel()
    let captionID = fixture.model.commitLocalCaptionForTesting(
        source: fixture.microphone,
        original: "helo world",
        translation: "你好 世界",
        audioWAVData: sampleWAV
    )
    #expect(fixture.model.overlayState?.sourceText == "helo world")
    #expect(fixture.model.overlayState?.translatedText == "你好 世界")
    await fixture.responder.release(
        captionID: captionID,
        output: .init(correctedOriginal: "hello world", correctedTranslation: "你好，世界")
    )
    await waitUntil { fixture.model.transcriptEntries.first?.sourceText == "hello world" }
    #expect(fixture.model.overlayState?.sourceText == "hello world")
    #expect(fixture.model.transcriptEntries.first?.localSourceText == "helo world")
}
```

The new test file owns `makeCorrectionEnabledModel()`, `sampleWAV`, an actor-backed
held responder, and a deadline-based `waitUntil`. The fixture uses a temporary
settings URL and `TestSourceCatalogService`; its `defer` removes only that exact
temporary file.

Add tests for text-only preserving local original, late result updating history but
not a newer current caption, stale session generation, correction-disabled global
and source policies, isolated-context propagation, empty local translation, and
corrected values in Ask snapshots with source/language labels.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
scripts/test-swift.sh --no-parallel --filter 'AppModelCorrectionIntegrationTests|AppModelAssistantIntegrationTests'
```

Expected: compile failures for correction injection and caption test seams.

- [ ] **Step 3: Wire settings, session lifecycle, and source audio control**

Add `let correction: RealtimeCorrectionCoordinator` to `AppModel` and an optional
initializer injection. Load `settings.correction`, observe coordinator settings with
Combine, and persist it alongside assistant settings. Keep separate cancellables.

Preserve the existing arrays and their tested stop/start behavior, and add an
ID-addressable lookup solely for dynamic correction-audio control:

```swift
private var liveTranscriptionSessionsBySourceID: [String: LiveTranscriptionSession] = [:]
```

On successful source startup, append to the existing arrays, store the source/session
pair in this lookup, and call
`setCorrectionAudioCaptureEnabled(correction.settings.isEnabled(for: source.id))`.
`beginSession()` is called once for the logical session after state reset.
`stopSession`, fatal failure, full startup failure, and app teardown call
`correction.endSession()`, disable/clear every live audio buffer, and clear the lookup.

When global or per-source policy changes during a session, update the matching live
session capture flag. Disabling one source calls `correction.cancel(sourceID:)`;
disabling globally or changing provider identity ends and begins a fresh correction
generation without restarting local transcription.

- [ ] **Step 4: Submit only after the local committed outcome**

Add `sourceID`, `capturedAt`, and `audioWAVData` to `QueuedCaption`. Carry the audio
from `RecognizedSentence` through `enqueueRecognizedSentence`. In
`processCaptionQueue`, after final local translation resolution and transcript
upsert—but before the display hold—call one helper:

```swift
private func submitCorrectionIfEnabled(
    for caption: QueuedCaption,
    localTranslation: String
) {
    guard correction.settings.isEnabled(for: caption.sourceID) else { return }
    correction.enqueue(CorrectionJob(
        captionID: caption.id,
        sessionGeneration: correction.sessionGeneration,
        capturedAt: caption.capturedAt,
        sourceID: caption.sourceID,
        sourceName: caption.sourceName,
        sourceLanguageID: caption.sourceLanguageID,
        targetLanguageID: caption.targetLanguageID,
        localOriginal: caption.sourceText,
        localTranslation: localTranslation,
        audioWAVData: caption.audioWAVData
    ))
}
```

Submit at most once per caption. A later Apple Translation backfill updates the local
translation field but does not enqueue a second model request.

- [ ] **Step 5: Apply corrections by caption and session identity**

Set `correction.onResult` during AppModel initialization. In the handler, require the
current correction generation, then update effective values in:

1. `displayedCaption`/primary overlay only when IDs match;
2. `overlayState.history` by ID; and
3. `transcriptEntries` by ID.

Audio results set both corrected fields. Text-only results set only corrected
translation. Track corrected caption IDs so a later local translation completion
updates retained local storage without replacing corrected display text. Recompute
display duration and reuse the late-update path without bumping `captionEpoch` or
replaying entrance animation.

- [ ] **Step 6: Run integration and full subtitle regressions**

Run:

```bash
scripts/test-swift.sh --no-parallel --filter 'AppModelCorrectionIntegrationTests|AppModelAssistantIntegrationTests|LiveTranscriptionSessionTests|OverlayPreviewStateTests|OverlayWindowControllerTests'
```

Expected: all selected tests pass; disabled correction preserves existing behavior.

- [ ] **Step 7: Commit**

```bash
git add Sources/V2SApp/App/AppModel.swift Sources/V2SApp/Models/OverlayPreviewState.swift Sources/V2SApp/Services/LiveTranscriptionSession.swift Tests/V2STests/AppModelCorrectionIntegrationTests.swift Tests/V2STests/AppModelAssistantIntegrationTests.swift
git commit -m "feat: backfill corrected subtitles safely"
```

## Task 9: Add Settings, Per-Source Policy, Status, and Localization

**Files:**

- Create: `Sources/V2SApp/UI/Settings/CorrectionSettingsSection.swift`
- Create: `Tests/V2STests/CorrectionSettingsSectionTests.swift`
- Modify: `Sources/V2SApp/UI/Settings/SettingsView.swift`
- Modify: `Sources/V2SApp/UI/StatusBar/StatusBarPopoverView.swift`
- Modify: `Sources/V2SApp/Localization/AppLocalization.swift`

- [ ] **Step 1: Write failing binding and presentation tests**

Mirror `AssistantSettingsSectionTests` and keep updates copy-safe:

```swift
@Test @MainActor func correctionBindingPublishesWithoutChangingSourcePolicy() {
    var initial = CorrectionSettings.default
    initial.disabledSourceIDs = ["mic-1"]
    let coordinator = RealtimeCorrectionCoordinator(settings: initial)
    let binding = CorrectionSettingsBindings.binding(for: coordinator, keyPath: \.baseURL)
    binding.wrappedValue = "https://example.invalid/v1"
    #expect(coordinator.settings.baseURL == "https://example.invalid/v1")
    #expect(coordinator.settings.disabledSourceIDs == ["mic-1"])
}

@Test @MainActor func sourcePolicyBindingsAreIndependent() {
    let model = makeTwoSourceModel()
    model.correction.settings.isEnabled = true
    model.setCorrectionEnabled(false, for: model.selectedSources[0])
    model.setCorrectionContextIsolated(true, for: model.selectedSources[1])
    #expect(!model.isCorrectionEnabled(for: model.selectedSources[0]))
    #expect(model.isCorrectionEnabled(for: model.selectedSources[1]))
    #expect(model.isCorrectionContextIsolated(for: model.selectedSources[1]))
}
```

Add localization parity assertions through the existing `AppLocalizationTests` and
a presentation test mapping `.audio`, `.textOnly`, and `.warning` to localized text.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
scripts/test-swift.sh --no-parallel --filter 'CorrectionSettingsSectionTests|AppLocalizationTests'
```

Expected: compile failures for bindings, source policy methods, and localization keys.

- [ ] **Step 3: Build the correction settings card**

Create `CorrectionSettingsBindings` and `CorrectionSettingsSection` following the
assistant settings patterns. The card contains, in this order:

1. global toggle, default off;
2. secure API key field;
3. base URL field;
4. model field, Fetch Models, and Test API controls;
5. current mode/status text; and
6. fixed privacy disclosure describing continuous sentence audio/text transmission
   and explicitly saying screenshots are not included.

Fields remain editable while correction is off. Model fetch/test uses the correction
coordinator only. Do not reuse assistant bindings or settings.

- [ ] **Step 4: Add per-source rows and compact status**

In `SettingsView.selectedSourceLanguageRows`, after the two language pickers, add:

```swift
Toggle(model.localized(.realtimeCorrectionForSource), isOn: correctionEnabledBinding(for: source))
    .disabled(!model.correction.settings.isEnabled)
Toggle(model.localized(.isolatedCorrectionContext), isOn: correctionIsolationBinding(for: source))
    .disabled(!model.correction.settings.isEnabled || !model.isCorrectionEnabled(for: source))
```

The first binding stores/removes the source ID in `disabledSourceIDs`; the second
stores/removes it in `isolatedContextSourceIDs`. Insert the correction settings card
next to, but not inside, `AssistantSettingsSection`.

In `StatusBarPopoverView`, show one compact row only when global correction is on:
Audio correction, Text translation correction, or the latest non-blocking warning.
Do not add a correction button, screen permission request, or automatic screenshot.

- [ ] **Step 5: Add every localization key to every existing dictionary**

Add keys for: real-time correction, enable correction, API fields/model actions where
existing generic keys cannot be reused, audio correction, text translation
correction, source enable, isolated context, queue skipped, invalid configuration,
provider failure, audio fallback, and the privacy disclosure. Provide values for all
currently supported interface languages; do not rely on English fallback for a key
shown in Settings.

- [ ] **Step 6: Run focused UI/localization tests and verify GREEN**

Run:

```bash
scripts/test-swift.sh --no-parallel --filter 'CorrectionSettingsSectionTests|AppLocalizationTests|SettingsWindowControllerTests|StatusBarPopoverViewTests'
```

Expected: all selected tests pass and existing assistant settings remain independent.

- [ ] **Step 7: Commit**

```bash
git add Sources/V2SApp/UI/Settings/CorrectionSettingsSection.swift Sources/V2SApp/UI/Settings/SettingsView.swift Sources/V2SApp/UI/StatusBar/StatusBarPopoverView.swift Sources/V2SApp/Localization/AppLocalization.swift Tests/V2STests/CorrectionSettingsSectionTests.swift Tests/V2STests/AppLocalizationTests.swift Tests/V2STests/StatusBarPopoverViewTests.swift
git commit -m "feat: configure realtime correction per source"
```

## Task 10: Register Sources and Document the Privacy Boundary

**Files:**

- Modify: `v2s.xcodeproj/project.pbxproj`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `Tests/Docs/xcode-project.test.cjs` only if a new invariant is required;
  otherwise leave the generic source-parity test unchanged.

- [ ] **Step 1: Run the Xcode source parity test and verify RED**

Run:

```bash
node --test Tests/Docs/xcode-project.test.cjs
```

Expected: failure listing each new production Swift file absent from the Xcode
project.

- [ ] **Step 2: Add new sources exactly once to the Xcode project**

For each new production file, add one `PBXFileReference`, one `PBXBuildFile`, one
entry in its matching Models/Services/UI group, and one entry in the app Sources
build phase. Use new unique 24-character uppercase hexadecimal IDs. Do not add test
files to the app target and do not change architectures, deployment target, signing,
Sparkle, bundle identity, or Release settings.

- [ ] **Step 3: Update English and Chinese documentation**

Document:

- local Apple recognition/translation always displays first;
- audio-capable correction sends sentence WAV plus local text and six corrected
  context entries, then may update both lines;
- explicit audio rejection causes session-scoped translation-only fallback;
- correction defaults off and has separate credentials from Ask/Follow Up;
- per-source disable and context isolation;
- two-request global concurrency and three-waiting-job source limit; and
- continuous correction never sends screenshots, while Ask/Follow Up captures the
  screen only when explicitly invoked.

State that the configured third-party provider governs retention. Do not claim local
recognition is guaranteed for languages lacking an Apple on-device model.

- [ ] **Step 4: Run documentation structure tests and verify GREEN**

Run:

```bash
node --test Tests/Docs/*.test.cjs
```

Expected: all Node tests pass, including production Swift/Xcode project parity.

- [ ] **Step 5: Commit**

```bash
git add v2s.xcodeproj/project.pbxproj README.md README.zh-CN.md Tests/Docs/xcode-project.test.cjs
git commit -m "docs: explain realtime correction privacy"
```

If `Tests/Docs/xcode-project.test.cjs` did not require a change, omit it from
`git add`; never manufacture a test edit merely to include the path.

## Task 11: Full Regression, Build, and Repository Audit

**Files:** Only defect fixes proven necessary by this gate.

- [ ] **Step 1: Run all Swift tests twice**

Run:

```bash
scripts/test-swift.sh --no-parallel
scripts/test-swift.sh --no-parallel
```

Expected: both complete runs pass with identical test counts and no timing-dependent
correction scheduler failure.

- [ ] **Step 2: Run all documentation tests**

Run: `node --test Tests/Docs/*.test.cjs`

Expected: all tests pass.

- [ ] **Step 3: Run Debug and Release builds with full Xcode**

When `xcodebuild -version` succeeds locally, run:

```bash
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/correction-debug build
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Release CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/correction-release build
lipo -archs .build/correction-release/Build/Products/Release/v2s.app/Contents/MacOS/v2s
```

Expected: both builds print `** BUILD SUCCEEDED **`; `lipo` includes `arm64` and
`x86_64`. If full Xcode is still unavailable locally, use the existing `macos-26` CI
after obtaining approval to push and report that boundary explicitly.

- [ ] **Step 4: Verify no network test, screenshot path, or secret leak**

Run:

```bash
rg -n 'URLSession\.shared|SystemScreenCapturer\(' Tests/V2STests/Correction* Tests/V2STests/RealtimeCorrectionCoordinatorTests.swift Tests/V2STests/AppModelCorrectionIntegrationTests.swift && exit 1 || true
rg -n '/Users/|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|sk-[A-Za-z0-9]{12,}' Sources Tests README.md README.zh-CN.md && exit 1 || true
git ls-files | rg '(^|/)(\.build|DerivedData|xcuserdata|settings\.json|\.DS_Store)(/|$)' && exit 1 || true
git diff --check
```

Expected: scans print nothing and `git diff --check` exits 0.

- [ ] **Step 5: Review the complete branch diff**

Run:

```bash
git diff --stat eff65b6966c072016b15238afa987c72a9b6aa50...HEAD
git diff --name-status eff65b6966c072016b15238afa987c72a9b6aa50...HEAD
git status --short
```

Expected: only approved correction implementation, tests, docs, project registration,
the design, and this plan are present; the worktree is clean after final fixes.

- [ ] **Step 6: Commit any gate-proven fixes separately**

For each real defect, add a focused regression test, demonstrate RED, make the
minimum fix, rerun the focused and full gates, then commit with a message describing
that defect. Do not combine unrelated cleanup or publish anything from this task.

## Manual Acceptance Checklist

Perform only after automated gates pass and only with placeholder/local fixtures
unless the user separately approves a real provider call:

- [ ] Start two real sources with different source languages and confirm both local
  subtitle lines appear before correction.
- [ ] Confirm an audio-capable model corrects both original and translation.
- [ ] Confirm an explicit audio rejection switches only the current session to text
  correction and preserves local originals.
- [ ] Confirm source disablement and isolated context affect only the selected source.
- [ ] Force a slow provider and confirm two cross-source calls and the three-waiting
  limit do not block local capture.
- [ ] Stop and restart; confirm old results cannot update the new session and audio is
  attempted again.
- [ ] Invoke Ask and confirm its one on-demand screenshot is independent from
  continuous correction.
- [ ] Inspect Git status and the built product location; do not add settings, audio,
  screenshots, DerivedData, or `.build` output.
