# Mainline Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the assistant, screen-context, hotkey, overlay-reply, privacy, and fork-identity behavior from `origin/main` on the `upstream/main` v0.3.38 codebase without importing the fork's old commits.

**Architecture:** Keep upstream speech, translation, VAD, transcript, overlay, multi-source, and single-instance code authoritative. Add a separate assistant domain whose coordinator consumes immutable transcript snapshots, uses injected screen-context and HTTP providers, and publishes reply-only UI state. Persist it through a nested settings value with legacy flat-key migration.

**Tech Stack:** Swift 5.10 package manifest, Swift 6/Xcode 26 compiler, AppKit, SwiftUI, Combine, Vision, ScreenCaptureKit, Carbon hotkeys, Swift Testing, Node test runner, GitHub Actions macOS 26.

---

## Implementation Preconditions

The repository is on `codex/upstream-rebuild`, based on upstream commit
`3aaaaa199bccddddb354bd9d2ee1a17e6b1f714c`. The design is in
`docs/superpowers/specs/2026-09-04-mainline-rebuild-design.md`.

The current local machine has Command Line Tools only. `xcodebuild` reports that no
full Xcode is selected, so do not claim an Xcode build was run locally. Use Swift
Testing for Swift package tests; any XCTest assertions in the examples below are
behavior pseudocode and must be translated to `#expect`/`#require` before adding the
test. The verified local Command Line Tools compatibility path is:

1. use `scripts/test-swift.sh`, which keeps SwiftPM caches below `.build`, runs
   normal `swift test` when full Xcode is selected, and otherwise uses the verified
   manifest SDK `MacOSX15.4.sdk`, target SDK `MacOSX26.4.sdk`, Swift Testing import
   and framework paths, link rpaths, and `--disable-sandbox`; or
2. install/select a compatible Xcode 26 toolchain locally; or
3. push the integration branch with user approval and use the `macos-26` CI runner
   for every required red/green verification.

Use the repository test entry point for local SwiftPM work:

```bash
scripts/test-swift.sh
```

## File Responsibility Map

**Create**

- `Sources/V2SApp/Models/AssistantSettings.swift`: persisted assistant and hotkey values.
- `Sources/V2SApp/Models/AssistantModels.swift`: action, state, transcript snapshot, screen status, and reply value types.
- `Sources/V2SApp/Services/HTTPTransport.swift`: injectable URL request transport.
- `Sources/V2SApp/Services/OpenAIResponsesClient.swift`: OpenAI-compatible and Gemini-compatible protocol adapter.
- `Sources/V2SApp/Services/AssistantPromptBuilder.swift`: deterministic prompt construction.
- `Sources/V2SApp/Services/ScreenContextProvider.swift`: screenshot/OCR composition and production adapters.
- `Sources/V2SApp/Services/AssistantCoordinator.swift`: assistant task lifecycle and observable reply state.
- `Sources/V2SApp/Services/GlobalHotKeyController.swift`: Carbon registration and dispatch.
- `Sources/V2SApp/UI/Settings/AssistantSettingsSection.swift`: assistant settings controls.
- `Sources/V2SApp/UI/Overlay/AssistantReplyView.swift`: reply history and screen-context warning UI.
- `Tests/V2STests/AssistantSettingsTests.swift`
- `Tests/V2STests/AssistantPromptBuilderTests.swift`
- `Tests/V2STests/OpenAIResponsesClientTests.swift`
- `Tests/V2STests/ScreenContextProviderTests.swift`
- `Tests/V2STests/AssistantCoordinatorTests.swift`
- `Tests/V2STests/AppModelAssistantIntegrationTests.swift`
- `Tests/V2STests/GlobalHotKeyControllerTests.swift`
- `Tests/V2STests/SettingsWindowControllerTests.swift`
- `Tests/Docs/ci-config.test.cjs`
- `.github/workflows/ci.yml`

**Modify**

- `Sources/V2SApp/Models/AppSettings.swift`: nested assistant value and legacy migration.
- `Sources/V2SApp/App/AppModel.swift`: read-only snapshot bridge and combined persistence.
- `Sources/V2SApp/App/AppDelegate.swift`: coordinator and hotkey wiring; preserve upstream single-instance code.
- `Sources/V2SApp/Localization/AppLocalization.swift`: assistant strings in all existing dictionaries.
- `Sources/V2SApp/UI/Settings/SettingsView.swift`: embed assistant section.
- `Sources/V2SApp/UI/Settings/SettingsWindowController.swift`: apply upstream recording-visibility setting.
- `Sources/V2SApp/UI/Overlay/OverlayView.swift`: switch between subtitle and reply content.
- `Sources/V2SApp/UI/Overlay/OverlayWindowController.swift`: reply-mode input/scroll integration.
- `Sources/V2SApp/UI/Shared/QuickSettingsControls.swift`: Follow Up and Ask controls.
- `Sources/V2SApp/UI/StatusBar/StatusBarPopoverView.swift`: quick Follow Up and Ask entry points.
- `Config/Info.plist`: screen-capture usage text and fork Sparkle feed.
- `README.md` and `README.zh-CN.md`: restored feature/privacy documentation.
- `v2s.xcodeproj/project.pbxproj`: add new production sources and retain universal architectures.
- `Tests/V2STests/AppSettingsTests.swift`: migration integration cases.
- `Tests/V2STests/OverlayWindowControllerTests.swift`: privacy and reply-mode integration.

## Task 0: Toolchain and Baseline Gate

**Files:** None.

- [ ] **Step 1: Prove branch ancestry and absence of imported fork commits**

Run:

```bash
test "$(git merge-base upstream/main HEAD)" = "$(git rev-parse upstream/main)"
test -z "$(git log --format=%H --merges upstream/main..HEAD)"
git log --oneline upstream/main..HEAD
```

Expected: both `test` commands exit 0; the log contains documentation commits only.

- [ ] **Step 2: Select a compatible toolchain**

Run:

```bash
xcode-select -p
xcodebuild -version
swift --version
```

Expected with full Xcode: `xcode-select` points inside an Xcode 26 application and
`xcodebuild` exits 0. With CLT-only machines, use `scripts/test-swift.sh`; its
verified compatibility path replaces this precondition for package tests.

- [ ] **Step 3: Run the upstream baseline**

Run:

```bash
scripts/test-swift.sh
node --test Tests/Docs/i18n.test.cjs
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Expected: Swift tests pass and Node reports 17 passed and 0 failed. Run the Xcode
build only when full Xcode is available; CLT-only machines instead verify the
production target with the compatibility `swift build` invocation.

## Task 1: Assistant Settings and Legacy Migration

**Files:**

- Create: `Sources/V2SApp/Models/AssistantSettings.swift`
- Modify: `Sources/V2SApp/Models/AppSettings.swift`
- Modify: `Tests/V2STests/AppSettingsTests.swift`
- Create: `Tests/V2STests/AssistantSettingsTests.swift`

- [ ] **Step 1: Write failing settings tests**

Add tests covering the old fork JSON and independent malformed-field fallback:

```swift
func testForkFlatAssistantSettingsMigrateWithoutLosingPrivacy() throws {
    let json = """
    {
      "inputLanguageID":"en","outputLanguageID":"zh-Hans",
      "overlayStyle":{},"subtitleMode":"balanced",
      "subtitleDisplayMode":"both","glossary":{},
      "privacyModeEnabled":true,
      "gptAPIKey":"secret-placeholder","gptAPIBaseURL":"https://example.invalid/v1",
      "gptModel":"model-a","gptSkills":"Answer briefly",
      "autoDetectConversationLanguages":false,
      "hotKeyFollowUp":{"key":"f","useCommand":true,"useOption":true,"useControl":false,"useShift":false},
      "hotKeyAsk":{"key":"g","useCommand":true,"useOption":true,"useControl":false,"useShift":false},
      "hotKeySwitchMode":{"key":"t","useCommand":true,"useOption":true,"useControl":false,"useShift":false}
    }
    """
    let value = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    XCTAssertEqual(value.assistant.apiKey, "secret-placeholder")
    XCTAssertEqual(value.assistant.baseURL, "https://example.invalid/v1")
    XCTAssertEqual(value.assistant.model, "model-a")
    XCTAssertEqual(value.assistant.skills, "Answer briefly")
    XCTAssertFalse(value.assistant.autoDetectConversationLanguages)
    XCTAssertEqual(value.assistant.followUpHotKey, .defaultFollowUp)
    XCTAssertTrue(value.overlayStyle.invisibleInRecording)
}

func testMalformedLegacyFieldDoesNotDiscardOtherAssistantFields() throws {
    let json = """
    {"gptAPIKey":"kept","gptModel":42,"gptSkills":"kept-skill"}
    """
    let value = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    XCTAssertEqual(value.assistant.apiKey, "kept")
    XCTAssertEqual(value.assistant.model, AssistantSettings.default.model)
    XCTAssertEqual(value.assistant.skills, "kept-skill")
}

func testNewEncodingContainsNestedAssistantAndNoLegacySecretsKey() throws {
    let data = try JSONEncoder().encode(AppSettings.default)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNotNil(object["assistant"])
    XCTAssertNil(object["gptAPIKey"])
    XCTAssertNil(object["privacyModeEnabled"])
}
```

Use `example.invalid` and placeholder values only.

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `scripts/test-swift.sh --filter 'AssistantSettingsTests|AppSettingsTests'`

Expected: compile failures for missing `AssistantSettings` and `AppSettings.assistant`.

- [ ] **Step 3: Add the settings value types**

Create `AssistantSettings.swift` with this public-to-module contract:

```swift
import Foundation

struct HotKeyBinding: Codable, Equatable, Hashable {
    static let allowedKeys = Array("abcdefghijklmnopqrstuvwxyz0123456789").map(String.init)
    static let defaultFollowUp = Self(key: "f", useCommand: true, useOption: true, useControl: false, useShift: false)
    static let defaultAsk = Self(key: "g", useCommand: true, useOption: true, useControl: false, useShift: false)
    static let defaultSwitchMode = Self(key: "t", useCommand: true, useOption: true, useControl: false, useShift: false)

    var key: String
    var useCommand: Bool
    var useOption: Bool
    var useControl: Bool
    var useShift: Bool

    var normalizedKey: String { key.lowercased() }
    var isValid: Bool {
        Self.allowedKeys.contains(normalizedKey)
            && (useCommand || useOption || useControl || useShift)
    }
    var displayString: String {
        [(useControl ? "⌃" : nil), (useOption ? "⌥" : nil),
         (useShift ? "⇧" : nil), (useCommand ? "⌘" : nil), normalizedKey.uppercased()]
            .compactMap { $0 }.joined()
    }
}

struct AssistantSettings: Codable, Equatable {
    var apiKey: String
    var baseURL: String
    var model: String
    var skills: String
    var autoDetectConversationLanguages: Bool
    var followUpHotKey: HotKeyBinding
    var askHotKey: HotKeyBinding
    var switchModeHotKey: HotKeyBinding

    static let `default` = Self(
        apiKey: "", baseURL: "https://api.openai.com/v1", model: "gpt-4o",
        skills: "", autoDetectConversationLanguages: true,
        followUpHotKey: .defaultFollowUp, askHotKey: .defaultAsk,
        switchModeHotKey: .defaultSwitchMode
    )

    init(apiKey: String, baseURL: String, model: String, skills: String,
         autoDetectConversationLanguages: Bool, followUpHotKey: HotKeyBinding,
         askHotKey: HotKeyBinding, switchModeHotKey: HotKeyBinding) {
        self.apiKey = apiKey; self.baseURL = baseURL; self.model = model
        self.skills = skills
        self.autoDetectConversationLanguages = autoDetectConversationLanguages
        self.followUpHotKey = followUpHotKey; self.askHotKey = askHotKey
        self.switchModeHotKey = switchModeHotKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        apiKey = (try? c.decode(String.self, forKey: .apiKey)) ?? d.apiKey
        baseURL = (try? c.decode(String.self, forKey: .baseURL)) ?? d.baseURL
        model = (try? c.decode(String.self, forKey: .model)) ?? d.model
        skills = (try? c.decode(String.self, forKey: .skills)) ?? d.skills
        autoDetectConversationLanguages = (try? c.decode(Bool.self, forKey: .autoDetectConversationLanguages)) ?? d.autoDetectConversationLanguages
        followUpHotKey = (try? c.decode(HotKeyBinding.self, forKey: .followUpHotKey)) ?? d.followUpHotKey
        askHotKey = (try? c.decode(HotKeyBinding.self, forKey: .askHotKey)) ?? d.askHotKey
        switchModeHotKey = (try? c.decode(HotKeyBinding.self, forKey: .switchModeHotKey)) ?? d.switchModeHotKey
    }
}
```

Add `assistant: AssistantSettings` to `AppSettings`, default its initializer argument
to `.default`, decode nested settings first, and otherwise decode each legacy flat key
through a separate `LegacyCodingKeys` container. After decoding `overlayStyle`, map a
valid legacy `privacyModeEnabled` Boolean to `overlayStyle.invisibleInRecording`.

- [ ] **Step 4: Verify GREEN and regression coverage**

Run: `scripts/test-swift.sh --filter 'AssistantSettingsTests|AppSettingsTests'`

Expected: all focused tests pass, including the existing multi-source and recording-
visibility cases.

- [ ] **Step 5: Commit**

```bash
git add Sources/V2SApp/Models/AssistantSettings.swift Sources/V2SApp/Models/AppSettings.swift Tests/V2STests/AssistantSettingsTests.swift Tests/V2STests/AppSettingsTests.swift
git commit -m "feat: migrate assistant settings onto upstream"
```

## Task 2: Injectable Provider Transport and Client

**Files:**

- Create: `Sources/V2SApp/Services/HTTPTransport.swift`
- Create: `Sources/V2SApp/Services/OpenAIResponsesClient.swift`
- Create: `Tests/V2STests/OpenAIResponsesClientTests.swift`

- [ ] **Step 1: Write provider contract tests**

Use an actor-backed fake transport that records requests and dequeues `(status, data)`
responses. Cover these exact observable cases:

```swift
func testOpenAIRequestUsesNormalizedChatEndpointAndBearerHeader() async throws
func testOpenAIImageRequestUsesTextAndDataURLParts() async throws
func testGeminiRequestUsesGenerateContentEndpointAndInlinePNG() async throws
func testModelDiscoveryFiltersUnsupportedGeminiModels() async throws
func testMissingKeyFailsBeforeTransport() async
func testImageCapabilityErrorIsTypedAndDoesNotExposeAPIKey() async
func testMalformedSuccessPayloadIsInvalidResponse() async
```

The fake response helper must construct a real `HTTPURLResponse`:

```swift
actor StubHTTPTransport: HTTPTransport {
    struct Stub { let status: Int; let data: Data }
    private var stubs: [Stub]
    private(set) var requests: [URLRequest] = []

    init(_ stubs: [Stub]) { self.stubs = stubs }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let stub = stubs.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        return (stub.data, response)
    }
}
```

- [ ] **Step 2: Run the provider tests and verify RED**

Run: `scripts/test-swift.sh --filter OpenAIResponsesClientTests`

Expected: compile failure because `HTTPTransport` and `OpenAIResponsesClient` do not exist.

- [ ] **Step 3: Implement the transport contract**

```swift
import Foundation

protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHTTPTransport: HTTPTransport {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIResponsesClient.ClientError.invalidResponse
        }
        return (data, http)
    }
}
```

- [ ] **Step 4: Rebuild the provider client around the transport**

Use `origin/main:Sources/V2SApp/Services/OpenAIResponsesClient.swift` only as a
behavior oracle. Preserve both wire formats, but expose one-attempt requests so retry
policy stays in the coordinator:

```swift
struct OpenAIResponsesClient: Sendable {
    enum ClientError: Error, Equatable {
        case missingAPIKey
        case invalidRequest
        case invalidResponse
        case http(status: Int, message: String)
        case imageUnsupported(message: String)
    }
    struct Response: Equatable { let text: String; let imageWasSent: Bool }

    let apiKey: String
    let baseURLString: String
    let model: String
    let transport: any HTTPTransport

    init(apiKey: String, baseURLString: String, model: String,
         transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.apiKey = apiKey; self.baseURLString = baseURLString
        self.model = model; self.transport = transport
    }

    func fetchAvailableModels() async throws -> [String]
    func testConnection() async throws -> String
    func respond(instructions: String, prompt: String,
                 screenshotPNGData: Data?) async throws -> Response
}
```

Implement the old endpoint normalization and JSON parsing as private typed helpers.
Map only provider messages containing `image`, `vision`, `visual`, `multimodal`,
`multi-modal`, `inline_data`, or `no endpoints` to `.imageUnsupported`; preserve the
HTTP status and sanitized message for all other failures. `LocalizedError` text must
never interpolate `apiKey` or a full request body.

- [ ] **Step 5: Verify GREEN, full regression, and commit**

Run:

```bash
scripts/test-swift.sh --filter OpenAIResponsesClientTests
scripts/test-swift.sh
git add Sources/V2SApp/Services/HTTPTransport.swift Sources/V2SApp/Services/OpenAIResponsesClient.swift Tests/V2STests/OpenAIResponsesClientTests.swift
git commit -m "feat: add testable assistant provider client"
```

Expected: focused and full Swift suites pass.

## Task 3: Deterministic Prompt Builder

**Files:**

- Create: `Sources/V2SApp/Models/AssistantModels.swift`
- Create: `Sources/V2SApp/Services/AssistantPromptBuilder.swift`
- Create: `Tests/V2STests/AssistantPromptBuilderTests.swift`

- [ ] **Step 1: Write failing prompt tests**

Use a fixed date and two transcript entries. Assert ISO-8601 ordering, source name,
language IDs and names, OCR inclusion, skills inclusion, distinct action instruction,
and rejection of an empty transcript.

```swift
func testAskPromptIsDeterministicAndIncludesAllContext() throws
func testFollowUpUsesDistinctActionInstruction() throws
func testNoOCRDoesNotEmitOCRSection() throws
func testEmptyTranscriptThrowsBeforeAnyProviderWork() throws
```

- [ ] **Step 2: Run and verify RED**

Run: `scripts/test-swift.sh --filter AssistantPromptBuilderTests`

Expected: missing model/builder compile errors.

- [ ] **Step 3: Add immutable assistant models**

```swift
import Foundation

enum AssistantAction: String, Equatable, Sendable { case followUp, ask }
enum OverlayViewMode: Equatable, Sendable { case subtitles, assistantReplies }
struct AssistantTranscriptEntry: Equatable, Sendable {
    let timestamp: Date; let sourceText: String; let translatedText: String
}
struct AssistantTranscriptSnapshot: Equatable, Sendable {
    let sourceName: String
    let inputLanguageID: String; let inputLanguageName: String
    let outputLanguageID: String; let outputLanguageName: String
    let entries: [AssistantTranscriptEntry]
}
struct AssistantPrompt: Equatable, Sendable {
    let instructions: String; let userContent: String
}
struct AssistantReply: Identifiable, Equatable, Sendable {
    let id: UUID; let action: AssistantAction; let title: String; let text: String
}
```

- [ ] **Step 4: Implement the pure builder**

```swift
struct AssistantPromptBuilder {
    enum BuildError: Error, Equatable { case emptyTranscript }

    func build(action: AssistantAction, snapshot: AssistantTranscriptSnapshot,
               settings: AssistantSettings, currentTime: Date,
               hasScreenshot: Bool, ocrText: String?) throws -> AssistantPrompt
}
```

Build the instruction prefix and action suffix from the fork behavior. Format every
entry with one ISO-8601 timestamp, `original`, and `translation`; use `-` for one empty
side. Trim skills and OCR before inclusion. Throw `.emptyTranscript` when every entry
has empty source and translation text.

- [ ] **Step 5: Verify GREEN and commit**

```bash
scripts/test-swift.sh --filter AssistantPromptBuilderTests
git add Sources/V2SApp/Models/AssistantModels.swift Sources/V2SApp/Services/AssistantPromptBuilder.swift Tests/V2STests/AssistantPromptBuilderTests.swift
git commit -m "feat: build deterministic assistant prompts"
```

## Task 4: Screen Capture and OCR Boundary

**Files:**

- Create: `Sources/V2SApp/Services/ScreenContextProvider.swift`
- Create: `Tests/V2STests/ScreenContextProviderTests.swift`
- Modify: `Config/Info.plist`

- [ ] **Step 1: Write failing composition tests**

Test capture success plus OCR, capture success plus OCR failure, permission denial,
and capture failure with injected actors. Assert that OCR is never called without an
image.

- [ ] **Step 2: Run and verify RED**

Run: `scripts/test-swift.sh --filter ScreenContextProviderTests`

Expected: missing protocols and provider compile errors.

- [ ] **Step 3: Implement the injectable boundary and production adapters**

```swift
import AppKit
import CoreGraphics
import CoreImage
import ScreenCaptureKit
import Vision

enum ScreenCaptureOutcome: Equatable, Sendable {
    case captured(Data), permissionNeeded, failed
}
protocol ScreenCapturing: Sendable { func captureCurrentDisplayPNG() async -> ScreenCaptureOutcome }
protocol TextRecognizing: Sendable { func recognizeText(from pngData: Data) async -> String? }
struct ScreenContext: Equatable, Sendable {
    let pngData: Data?; let ocrText: String?; let status: ScreenContextStatus
}
enum ScreenContextStatus: Equatable, Sendable {
    case unknown, ready, permissionNeeded, captureFailed, ocrFailed,
         screenshotSent, providerRejectedImage
    var isWarning: Bool {
        switch self {
        case .permissionNeeded, .captureFailed, .ocrFailed, .providerRejectedImage: true
        default: false
        }
    }
}
struct ScreenContextProvider: Sendable {
    let capture: any ScreenCapturing; let recognizer: any TextRecognizing
    func current() async -> ScreenContext {
        switch await capture.captureCurrentDisplayPNG() {
        case .permissionNeeded: return .init(pngData: nil, ocrText: nil, status: .permissionNeeded)
        case .failed: return .init(pngData: nil, ocrText: nil, status: .captureFailed)
        case .captured(let data):
            let text = await recognizer.recognizeText(from: data)
            return .init(pngData: data, ocrText: text, status: text == nil ? .ocrFailed : .ready)
        }
    }
}
```

Implement `SystemScreenCapturer` with the fork's mouse-display selection and
`SCScreenshotManager`, and `VisionTextRecognizer` with `VNRecognizeTextRequest`.
Add `NSScreenCaptureUsageDescription` stating capture occurs only for an explicit
assistant request.

- [ ] **Step 4: Verify GREEN and commit**

```bash
scripts/test-swift.sh --filter ScreenContextProviderTests
git add Sources/V2SApp/Services/ScreenContextProvider.swift Tests/V2STests/ScreenContextProviderTests.swift Config/Info.plist
git commit -m "feat: add assistant screen context provider"
```

## Task 5: Assistant Coordinator Lifecycle

**Files:**

- Create: `Sources/V2SApp/Services/AssistantCoordinator.swift`
- Modify: `Sources/V2SApp/Models/AssistantModels.swift`
- Create: `Tests/V2STests/AssistantCoordinatorTests.swift`

- [ ] **Step 1: Write failing lifecycle tests**

Use fake prompt, screen, and response providers. Cover:

```swift
func testRequestPublishesThinkingThenReplyAndSwitchesMode() async
func testSecondRequestCancelsFirstAndIgnoresItsLateResponse() async
func testImageUnsupportedRetriesExactlyOnceWithoutImage() async
func testNonImageFailureDoesNotRetry() async
func testPermissionDenialContinuesTextOnlyAndPublishesWarning() async
func testReplyScrollOffsetClampsAfterHistoryChanges() async
func testMissingConfigurationFailsBeforeScreenCapture() async
```

- [ ] **Step 2: Run and verify RED**

Run: `scripts/test-swift.sh --filter AssistantCoordinatorTests`

Expected: missing coordinator compile error.

- [ ] **Step 3: Implement protocol seams and state machine**

Define `AssistantResponding`, `AssistantScreenContextProviding`, and
`AssistantPromptBuilding` adapters around the concrete components. Implement this
main-actor contract:

```swift
enum AssistantRequestState: Equatable {
    case idle, running(AssistantAction), failed(String)
}
enum AssistantModelFetchState: Equatable {
    case idle, fetching, fetched([String]), failed(String)
}
enum AssistantAPITestState: Equatable {
    case idle, testing, passed(String), failed(String)
}

@MainActor
final class AssistantCoordinator: ObservableObject {
    @Published var settings: AssistantSettings
    @Published private(set) var requestState: AssistantRequestState = .idle
    @Published private(set) var modelFetchState: AssistantModelFetchState = .idle
    @Published private(set) var apiTestState: AssistantAPITestState = .idle
    @Published private(set) var replies: [AssistantReply] = []
    @Published private(set) var screenStatus: ScreenContextStatus = .unknown
    @Published var overlayMode: OverlayViewMode = .subtitles
    @Published private(set) var replyScrollOffset = 0
    @Published private(set) var replyVisibleCount = 0

    func request(_ action: AssistantAction, snapshot: AssistantTranscriptSnapshot)
    func cancelRequest()
    func fetchModels()
    func testAPI()
    func toggleOverlayMode()
    func scrollReplies(by delta: Int)
    func setReplyScrollOffset(_ value: Int)
}
```

Increment a `requestGeneration` before each request and cancellation. Capture the
generation in the task; guard equality before every published completion. On
`.imageUnsupported`, call the responder once more with `nil` image and set
`.providerRejectedImage`. All other failures publish one failed state and retain prior
replies.

- [ ] **Step 4: Verify RED-GREEN behavior explicitly**

Run the focused test with the fallback branch temporarily disabled and confirm
`testImageUnsupportedRetriesExactlyOnceWithoutImage` fails; restore the branch and
rerun.

Run: `scripts/test-swift.sh --filter AssistantCoordinatorTests`

Expected: all coordinator tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/V2SApp/Models/AssistantModels.swift Sources/V2SApp/Services/AssistantCoordinator.swift Tests/V2STests/AssistantCoordinatorTests.swift
git commit -m "feat: coordinate assistant request lifecycle"
```

## Task 6: AppModel Snapshot and Settings Integration

**Files:**

- Modify: `Sources/V2SApp/App/AppModel.swift`
- Modify: `Tests/V2STests/AppSettingsTests.swift`
- Create: `Tests/V2STests/AppModelAssistantIntegrationTests.swift`

- [ ] **Step 1: Write failing integration tests**

Construct `AppModel` with a temporary `SettingsStore`, seed transcript entries through
a DEBUG test seam, and assert timestamps, ordering, and language names. Change
`assistant.settings`, persist, reload `AppSettings`, and assert the nested value is
saved with existing source/language fields unchanged.

- [ ] **Step 2: Run and verify RED**

Run: `scripts/test-swift.sh --filter AppModelAssistantIntegrationTests`

Expected: missing `assistant` and `assistantTranscriptSnapshot()` members.

- [ ] **Step 3: Integrate without moving provider logic into AppModel**

Add:

```swift
let assistant: AssistantCoordinator

func assistantTranscriptSnapshot() -> AssistantTranscriptSnapshot {
    AssistantTranscriptSnapshot(
        sourceName: selectedSourceDisplayName,
        inputLanguageID: inputLanguageID,
        inputLanguageName: languageName(for: inputLanguageID),
        outputLanguageID: outputLanguageID,
        outputLanguageName: languageName(for: outputLanguageID),
        entries: transcriptEntries.map {
            .init(timestamp: $0.timestamp, sourceText: $0.sourceText,
                  translatedText: $0.translatedText)
        }
    )
}
```

Add `var timestamp: Date = Date()` to upstream `TranscriptEntry`; preserve it when an
entry is updated rather than replaced. Existing call sites continue compiling through
the default value.

Inject the coordinator through the designated initializer with a production default,
initialize it from `settings.assistant`, observe `assistant.$settings` to call
`persistSettings()`, and add `assistant: assistant.settings` to the `AppSettings`
snapshot. Call `assistant.cancelRequest()` from `AppModel.stopSession()` and from
`AppDelegate.applicationWillTerminate`; do not otherwise change upstream speech and
translation methods.

- [ ] **Step 4: Verify GREEN and commit**

```bash
scripts/test-swift.sh --filter 'AppModelAssistantIntegrationTests|AppSettingsTests'
scripts/test-swift.sh
git add Sources/V2SApp/App/AppModel.swift Tests/V2STests/AppModelAssistantIntegrationTests.swift Tests/V2STests/AppSettingsTests.swift
git commit -m "feat: connect assistant to transcript snapshots"
```

## Task 7: Validated Global Hotkeys and App Lifecycle Wiring

**Files:**

- Create: `Sources/V2SApp/Services/GlobalHotKeyController.swift`
- Create: `Tests/V2STests/GlobalHotKeyControllerTests.swift`
- Modify: `Sources/V2SApp/App/AppDelegate.swift`

- [ ] **Step 1: Write failing registration-plan tests**

Test three unique defaults, invalid unmodified keys, duplicate bindings, and preservation
of unrelated valid actions. The pure planner returns registrations and per-action errors;
Carbon calls are outside the unit test.

- [ ] **Step 2: Run and verify RED**

Run: `scripts/test-swift.sh --filter GlobalHotKeyControllerTests`

Expected: missing planner/controller compile errors.

- [ ] **Step 3: Implement planner and Carbon adapter**

Port the fork's ANSI key-code map and event handler. Add a pure plan API:

```swift
enum GlobalHotKeyAction: UInt32, CaseIterable, Sendable { case followUp = 1, ask = 2, switchMode = 3 }
struct HotKeyRegistrationPlan: Equatable {
    let bindings: [GlobalHotKeyAction: HotKeyBinding]
    let errors: [GlobalHotKeyAction: HotKeyRegistrationError]
}
enum HotKeyRegistrationError: Equatable { case invalidBinding, duplicateBinding }

static func makePlan(followUp: HotKeyBinding, ask: HotKeyBinding,
                     switchMode: HotKeyBinding) -> HotKeyRegistrationPlan
```

`update` unregisters old refs, builds the plan, and registers only `plan.bindings`.
Expose the errors as a read-only published value for settings UI.

- [ ] **Step 4: Wire actions in AppDelegate**

Create the controller after windows are created. Route Follow Up and Ask through
`appModel.assistant.request(..., snapshot: appModel.assistantTranscriptSnapshot())`;
route switch mode to `appModel.assistant.toggleOverlayMode()`. Observe the three
assistant hotkeys and call `update`. Preserve all existing single-instance code
byte-for-byte except adjacent initialization/termination wiring.

- [ ] **Step 5: Verify GREEN and commit**

```bash
scripts/test-swift.sh --filter GlobalHotKeyControllerTests
scripts/test-swift.sh
git add Sources/V2SApp/Services/GlobalHotKeyController.swift Tests/V2STests/GlobalHotKeyControllerTests.swift Sources/V2SApp/App/AppDelegate.swift
git commit -m "feat: restore validated assistant hotkeys"
```

## Task 8: Localized Assistant Settings UI

**Files:**

- Create: `Sources/V2SApp/UI/Settings/AssistantSettingsSection.swift`
- Modify: `Sources/V2SApp/UI/Settings/SettingsView.swift`
- Modify: `Sources/V2SApp/Localization/AppLocalization.swift`
- Modify: `Tests/V2STests/AppLocalizationTests.swift`

- [ ] **Step 1: Add failing localization completeness tests**

Add every assistant key to `AppTextKey`, then extend the existing test to iterate all
supported interface dictionaries and assert non-empty values for:

```swift
[.assistant, .followUp, .askAssistant, .apiKey, .apiBaseURL, .model,
 .fetchModels, .testAPI, .skills, .autoDetectConversationLanguages,
 .hotKeys, .hotKeyFollowUp, .hotKeyAsk, .hotKeySwitchMode,
 .assistantThinking, .assistantRequestFailedFormat,
 .screenPermissionNeeded, .screenCaptureFailed, .providerRejectedImage]
```

- [ ] **Step 2: Run and verify RED**

Run: `scripts/test-swift.sh --filter AppLocalizationTests`

Expected: missing key/dictionary failures.

- [ ] **Step 3: Add localized strings and a focused view**

Add English and Simplified Chinese copy matching the README privacy disclosure; add
equivalent entries to every existing dictionary so no locale silently shows a raw key.
`AssistantSettingsSection` receives `@ObservedObject var assistant` and bindings to
its settings value. It renders secure API key input, base URL, editable model plus
fetched-model menu, skills editor, automatic-language toggle, three hotkey rows,
fetch/test progress, and registration errors.

Embed this section in the existing General tab after language resources. Keep the
upstream `invisibleInRecording` toggle as the sole privacy toggle.

- [ ] **Step 4: Verify GREEN and commit**

```bash
scripts/test-swift.sh --filter AppLocalizationTests
node --test Tests/Docs/i18n.test.cjs
git add Sources/V2SApp/UI/Settings/AssistantSettingsSection.swift Sources/V2SApp/UI/Settings/SettingsView.swift Sources/V2SApp/Localization/AppLocalization.swift Tests/V2STests/AppLocalizationTests.swift
git commit -m "feat: add localized assistant settings"
```

## Task 9: Reply Overlay and Unified Window Privacy

**Files:**

- Create: `Sources/V2SApp/UI/Overlay/AssistantReplyView.swift`
- Modify: `Sources/V2SApp/UI/Overlay/OverlayView.swift`
- Modify: `Sources/V2SApp/UI/Overlay/OverlayWindowController.swift`
- Modify: `Sources/V2SApp/UI/Settings/SettingsWindowController.swift`
- Modify: `Sources/V2SApp/UI/Shared/QuickSettingsControls.swift`
- Modify: `Sources/V2SApp/UI/StatusBar/StatusBarPopoverView.swift`
- Modify: `Tests/V2STests/OverlayWindowControllerTests.swift`
- Create: `Tests/V2STests/SettingsWindowControllerTests.swift`

- [ ] **Step 1: Write failing privacy and mode tests**

Assert that toggling `overlayStyle.invisibleInRecording` updates every overlay panel,
the main settings window, and the subtitle-mode info window. Assert reply mode accepts
mouse/scroll input and subtitle mode preserves the upstream click-through behavior.

- [ ] **Step 2: Run and verify RED**

Run: `scripts/test-swift.sh --filter 'OverlayWindowControllerTests|SettingsWindowControllerTests'`

Expected: settings-window privacy assertion fails and reply-mode APIs are absent.

- [ ] **Step 3: Add reply presentation**

`AssistantReplyView` selects the newest reply minus `replyScrollOffset`, displays its
localized action title and text in a vertical scroll view, and displays a warning dot
with localized help only when `screenStatus.isWarning`. It never reads or mutates
subtitle history.

In `OverlayView`, render `AssistantReplyView` when mode is `.assistantReplies` and
there is at least one reply; otherwise render the unchanged upstream subtitle content.
Add Follow Up and Ask buttons to the existing overlay control strip and route scrollbar
metrics to assistant history only in reply mode.

Add an assistant section to `StatusBarPopoverView` with Follow Up and Ask buttons. Both
buttons call the same coordinator methods as the global hotkeys, close the popover after
dispatch, and are disabled while the transcript snapshot has no content.

- [ ] **Step 4: Apply one privacy source to all windows**

Keep `OverlayWindowController.applyRecordingVisibility` unchanged for overlay panels.
In `SettingsWindowController`, observe:

```swift
model.$overlayStyle
    .map(\.invisibleInRecording)
    .removeDuplicates()
    .sink { [weak self] hidden in
        let type: NSWindow.SharingType = hidden ? .none : .readOnly
        self?.window?.sharingType = type
        self?.subtitleModeInfoWindowController.window?.sharingType = type
    }
    .store(in: &cancellables)
```

Use the emitted Boolean rather than rereading the model because `@Published` emits
during `willSet`.

- [ ] **Step 5: Verify GREEN and commit**

```bash
scripts/test-swift.sh --filter 'OverlayWindowControllerTests|SettingsWindowControllerTests|AssistantCoordinatorTests'
scripts/test-swift.sh
git add Sources/V2SApp/UI/Overlay/AssistantReplyView.swift Sources/V2SApp/UI/Overlay/OverlayView.swift Sources/V2SApp/UI/Overlay/OverlayWindowController.swift Sources/V2SApp/UI/Settings/SettingsWindowController.swift Sources/V2SApp/UI/Shared/QuickSettingsControls.swift Sources/V2SApp/UI/StatusBar/StatusBarPopoverView.swift Tests/V2STests/OverlayWindowControllerTests.swift Tests/V2STests/SettingsWindowControllerTests.swift
git commit -m "feat: restore assistant overlay and unified privacy"
```

## Task 10: Xcode Project, Fork Identity, and Documentation

**Files:**

- Modify: `v2s.xcodeproj/project.pbxproj`
- Modify: `Sources/V2SApp/App/AppModel.swift`
- Modify: `Config/Info.plist`
- Modify: `Sources/V2SApp/Services/UpdaterService.swift`
- Modify: `README.md`
- Modify: `README.zh-CN.md`

- [ ] **Step 1: Add all new production files to the Xcode target**

Add one `PBXFileReference` and one `PBXBuildFile` for each new production Swift file,
place references in the matching Models/Services/Settings/Overlay groups, and place
all build-file IDs once in the app's `PBXSourcesBuildPhase`. Remove the existing
duplicate `OverlayStyle.swift` child entry while editing the project. Do not add the
ONNX Runtime package or old ONNX model; retain upstream Core ML resources and
`ARCHS = "$(ARCHS_STANDARD)"`.

- [ ] **Step 2: Restore fork-facing identity without publishing**

Set `AppBuildInfo.repositoryURLString` to `https://github.com/NX-lite/v2s`, keep the
current upstream code version during integration, and set `SUFeedURL` to:

```xml
<string>https://github.com/NX-lite/v2s/releases/latest/download/appcast.xml</string>
```

Use the fork logger subsystem `com.nxlite.v2s` where the fork already did so. Do not
change the bundle identifier, tag a version, or create a release.

- [ ] **Step 3: Update both READMEs**

Document the preserved upstream features plus GPT assistant, optional external data
flow, screen/OCR behavior, image fallback, hotkeys, privacy mode, and fork build URL.
State accurately that assistant requests send configured transcript/screen context to
the user's provider only after explicit Follow Up or Ask actions.

- [ ] **Step 4: Build and inspect the product**

Run:

```bash
xcodebuild -list -project v2s.xcodeproj
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Expected: one `v2s` scheme, successful unsigned Debug build, and no whitespace errors.

- [ ] **Step 5: Commit**

```bash
git add v2s.xcodeproj/project.pbxproj Sources/V2SApp/App/AppModel.swift Config/Info.plist Sources/V2SApp/Services/UpdaterService.swift README.md README.zh-CN.md
git commit -m "chore: restore fork identity on upstream base"
```

## Task 11: Continuous Integration

**Files:**

- Create: `.github/workflows/ci.yml`
- Keep: `.github/workflows/release.yml`

- [ ] **Step 1: Add a failing workflow-structure test**

Create `Tests/Docs/ci-config.test.cjs` that parses `.github/workflows/ci.yml` as text
and asserts the push branches, PR target, `swift test`, docs test, Debug build, Release
build, and `arm64`/`x86_64` checks are present. Run it before creating the workflow.

Run: `node --test Tests/Docs/ci-config.test.cjs`

Expected: failure because `.github/workflows/ci.yml` is missing.

- [ ] **Step 2: Add the non-release workflow**

Create `.github/workflows/ci.yml` with:

```yaml
name: CI
on:
  push:
    branches: [main, "codex/**"]
  pull_request:
    branches: [main]
  workflow_dispatch:

jobs:
  test:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: Swift tests
        run: swift test
      - name: Documentation tests
        run: node --test Tests/Docs/*.test.cjs
      - name: Debug build
        run: xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug CODE_SIGNING_ALLOWED=NO build
      - name: Universal release build
        run: xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Release -derivedDataPath .build/ci-release CODE_SIGNING_ALLOWED=NO build
      - name: Verify universal binary
        run: |
          APP_BINARY=.build/ci-release/Build/Products/Release/v2s.app/Contents/MacOS/v2s
          ARCHS="$(lipo -archs "$APP_BINARY")"
          case " $ARCHS " in *" arm64 "*) ;; *) exit 1 ;; esac
          case " $ARCHS " in *" x86_64 "*) ;; *) exit 1 ;; esac
```

Do not edit release triggers or add secrets to CI.

- [ ] **Step 3: Verify GREEN and commit**

```bash
node --test Tests/Docs/*.test.cjs
git diff --check
git add .github/workflows/ci.yml Tests/Docs/ci-config.test.cjs
git commit -m "ci: test assistant rebuild and universal app"
```

Expected: Node tests pass, including the workflow structure test.

## Task 12: Full Regression, Bug Fix Loop, and Privacy Audit

**Files:** Modify only files implicated by a reproduced failure; add the matching
regression test beside the affected suite.

- [ ] **Step 1: Run the complete automated suite**

```bash
scripts/test-swift.sh
node --test Tests/Docs/*.test.cjs
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Release -derivedDataPath .build/final-release CODE_SIGNING_ALLOWED=NO build
lipo -archs .build/final-release/Build/Products/Release/v2s.app/Contents/MacOS/v2s
```

Expected: all Swift/Node tests pass; both builds exit 0; `lipo` reports `arm64 x86_64`.

- [ ] **Step 2: Fix each reproduced failure test-first**

For every failure, reduce it to one focused Swift Testing or Node test, run it to observe the
expected failure, make the smallest production fix, rerun the focused test, then rerun
Step 1. Commit each unrelated bug separately as `fix: <observable behavior>`.

- [ ] **Step 3: Verify feature parity without using real secrets**

Check each fork-main item against a passing test or upstream implementation:

```text
[ ] multi-source capture and per-source languages (upstream)
[ ] dynamic language discovery and Core ML VAD (upstream)
[ ] single-instance lifecycle (upstream)
[ ] assistant configuration migration
[ ] OpenAI-compatible and Gemini-compatible requests
[ ] model discovery and API test
[ ] Follow Up and Ask prompt paths
[ ] screen capture, OCR, and one-time text fallback
[ ] three hotkeys and conflict reporting
[ ] reply overlay and independent scrolling
[ ] recording invisibility for overlay and settings windows
[ ] NX-lite repository and update feed
```

- [ ] **Step 4: Scan the diff for sensitive or accidental content**

```bash
git diff --check upstream/main...HEAD
git diff --name-status upstream/main...HEAD
rg -n --hidden -g '!.git/**' -g '!.build/**' '(sk-[A-Za-z0-9_-]{16,}|AIza[0-9A-Za-z_-]{20,}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|/Users/[^/]+|192\.168\.|10\.[0-9]+\.)' .
git log --oneline --decorate upstream/main..HEAD
```

Expected: no key/private-data matches outside deliberate test regexes, no files from
the excluded branches, and only reviewable rebuild commits descended from upstream.

- [ ] **Step 5: Record manual verification still required**

Report, without claiming completion, that microphone/app audio, system permission
dialogs, real cross-app hotkeys, actual recording invisibility, and a real provider
request remain manual checks until performed on a configured Mac with explicit user
approval for the provider request.

- [ ] **Step 6: Stop before external publication**

Show the complete diff summary, test/build evidence, and remaining manual boundaries.
Wait for explicit approval before `git push`, opening a pull request, tagging, or
publishing a release.
