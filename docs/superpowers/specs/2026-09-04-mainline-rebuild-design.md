# Mainline Rebuild Design

**Date:** 2026-09-04

**Status:** Approved in conversation

**Integration branch:** `codex/upstream-rebuild`

**Fork baseline:** `origin/main` at `75b4f938bc15cf9e96e03ee20e11487bf06c0cae`

**Upstream baseline:** `upstream/main` at `3aaaaa199bccddddb354bd9d2ee1a17e6b1f714c` (`v0.3.38`)

## Objective

Rebuild the features present on `NX-lite/v2s` `main` on top of the latest
`franklioxygen/v2s` `main`, while retaining the upstream architecture and fixes.
The rebuilt branch must include automated regression coverage and must not depend
on the fork's `multi-source-input` or `test` branches.

## Constraints

- Start from `upstream/main`; do not merge or rebase the old fork commits into the
  implementation branch.
- Treat the fork's `main` behavior and documentation as the compatibility contract.
- Reuse an upstream implementation when it already provides equivalent behavior.
- Keep the fork's repository and update-channel identity where the product links to
  releases or source code.
- Do not push, tag, publish a release, or modify the remote fork without separate
  user approval.
- Never put a real API key, provider response, captured screen, or private transcript
  into source control, fixtures, CI logs, or error messages.

## Functional Scope

### Upstream behavior to retain as the foundation

The upstream baseline already supplies the following behavior and remains the
authoritative implementation for it:

- microphone and application-audio capture, including multiple selected sources;
- per-source input and output languages;
- dynamically discovered Speech and Translation language support;
- local-model preference and the server-recognition disclosure path;
- `TranslationCoordinator`, transcript summarization, and glossary handling;
- Core ML Silero VAD without the ONNX Runtime dependency;
- current subtitle history, overlay controls, multi-source failure handling, and
  single-instance lifecycle behavior;
- Apple silicon and Intel release builds.

No old fork implementation will replace these subsystems unless a feature-equivalence
test proves that a user-visible fork behavior is missing upstream.

### Fork `main` behavior to rebuild

1. Optional GPT interview assistant with configurable API key, base URL, model, and
   skills prompt.
2. OpenAI Responses-compatible and Gemini-compatible model discovery, connection
   testing, and response generation.
3. `Follow Up` and `Ask` actions using transcript history, timestamps, source or
   conversation context, and the configured skills prompt.
4. Current-screen capture and Vision OCR, with a one-time text-only retry when the
   selected provider rejects image input.
5. Three configurable global hotkeys: Follow Up, Ask, and overlay-mode switch.
6. A scrollable GPT reply mode in the overlay, independent from subtitle history.
7. Privacy mode applied consistently to the overlay and settings windows.
8. Fork-facing repository, release, and updater links.

The existing upstream single-instance behavior and multi-source implementation count
as preserved functionality; they will be tested for integration rather than copied
from the older fork.

## Architecture

### Settings and migration

Add an `AssistantSettings` value containing the GPT endpoint, model, skills prompt,
automatic language-context choice, and the three hotkey bindings. The upstream
`OverlayStyle.invisibleInRecording` value remains the single privacy setting for all
app windows.

`AppSettings.init(from:)` supports both formats:

- the new nested `assistant` object; and
- the fork's legacy flat keys (`gptAPIKey`, `gptAPIBaseURL`, `gptModel`, `gptSkills`,
  `autoDetectConversationLanguages`, `hotKeyFollowUp`, `hotKeyAsk`, and
  `hotKeySwitchMode`). The legacy `privacyModeEnabled` key migrates into
  `OverlayStyle.invisibleInRecording`.

Valid fields are migrated independently. A missing or malformed field falls back
only to that field's default. The next normal settings save writes the new format.
Existing subtitle, source, language, glossary, and overlay-style decoding remains
unchanged.

### Assistant domain and orchestration

`AssistantCoordinator` owns assistant-only observable state:

- idle/running/succeeded/failed request state;
- model-list and connection-test state;
- overlay reply history, visible count, and scroll position;
- whether the latest answer used an image; and
- the current screen-context warning.

It receives immutable transcript snapshots from `AppModel`. It cannot mutate speech,
translation, caption queues, or transcript storage. A monotonically increasing request
generation prevents a cancelled or stale response from replacing newer state. Only
one user request is active at a time; starting another cancels the previous task.

`AssistantPromptBuilder` converts an action and transcript snapshot into deterministic
instructions and user content. This pure component owns transcript formatting,
timestamps, source labels, language context, skills text, OCR text, and empty-context
handling.

### Provider client

`OpenAIResponsesClient` retains the fork's provider compatibility but depends on an
injectable HTTP transport. It owns endpoint normalization, authentication headers,
request encoding, response decoding, provider error decoding, and response-text
extraction.

The coordinator first sends the request with the available screen image. If the
provider returns a recognized image-capability rejection, it retries once without
the image. Authentication failures, rate limits, malformed responses, timeouts, and
other provider failures do not retry automatically and are mapped to typed errors.
Secrets are excluded from error descriptions.

### Screen context

`ScreenContextProvider` coordinates two narrow dependencies:

- screen capture, which returns an optional image or a permission/unavailable result;
- OCR, which converts a captured image to text.

Screen context is best effort. Missing permission or capture failure does not block a
text-only assistant request. OCR failure does not discard a usable image. The result
records enough state for the overlay to show whether context was complete, partial,
text-only, or unavailable.

### App and UI integration

`AppModel` remains the owner of subtitle and transcript behavior. It exposes a
read-only transcript snapshot and persists combined app/assistant settings, but it
does not absorb provider request logic.

`AppDelegate` owns `GlobalHotKeyController` and routes its actions to the assistant
coordinator. It also observes hotkey-setting changes and re-registers bindings. The
upstream single-instance implementation remains intact.

Settings gain an assistant section for endpoint, API key, model discovery, connection
test, skills prompt, hotkeys, and privacy mode. Quick settings expose the three
assistant actions without duplicating their logic.

The overlay switches between the existing subtitle view and a reply-history view.
Each mode keeps an independent scroll offset. Switching modes does not stop audio,
clear transcript data, or cancel an in-flight assistant request. Privacy mode is
implemented through one window policy applied to every panel owned by the overlay
controller and to the settings window.

## Request Flow

1. A button or global hotkey requests `Follow Up` or `Ask`.
2. The coordinator validates the endpoint, API key, model, and transcript snapshot.
3. The screen-context provider attempts capture and OCR.
4. The prompt builder produces deterministic instructions and content.
5. The provider client sends one request with an image when available.
6. A recognized image-capability rejection causes exactly one text-only retry.
7. The coordinator accepts the response only if its request generation is current,
   appends a reply-history entry, and switches the overlay to reply mode.
8. Failure leaves prior replies intact and exposes a localized, non-secret error.

## Error and Lifecycle Rules

- Missing API configuration fails before capture or network access.
- Empty transcript context fails before network access.
- Screen-capture denial degrades to text-only operation and surfaces a warning.
- Cancelling, stopping a session, or terminating the app cancels assistant work and
  prevents stale completion handlers from updating UI state.
- HTTP status, provider payload, decoding, and transport failures use distinct typed
  errors so tests can assert the correct user-facing path.
- Hotkey registration rejects empty or invalid single-key bindings and reports
  collisions without removing unrelated working registrations.
- Settings migration never replaces a valid legacy value because another legacy
  field is absent or malformed.

## Automated Test Strategy

All behavior changes follow a red-green-refactor cycle: add a focused failing test,
confirm the expected failure, implement the smallest change, and rerun the focused
and complete suites.

Swift package tests use Swift Testing (`@Suite`, `@Test`, `#expect`, and
`#require`) rather than XCTest. Locally, run `scripts/test-swift.sh`, which uses
normal `swift test` under full Xcode and otherwise the verified Command Line Tools
compatibility path: manifest SDK `MacOSX15.4.sdk`, target SDK `MacOSX26.4.sdk`,
Swift Testing import/framework paths and rpaths, `--disable-sandbox`, and
repository-local `.build` caches. XCTest-style examples in the implementation plan
are behavioral pseudocode and must be converted when implemented.

### Existing suites

Retain all upstream tests under `Tests/V2STests` and the documentation localization
test under `Tests/Docs/i18n.test.cjs`.

### New coverage

- `AssistantSettingsTests`: defaults, encoding round trip, legacy flat-key migration,
  partial corruption, and hotkey validation.
- `AssistantPromptBuilderTests`: Follow Up and Ask instructions, transcript ordering,
  timestamps, source labels, language context, skills text, OCR inclusion, and empty
  input rejection.
- `OpenAIResponsesClientTests`: OpenAI and Gemini endpoint normalization, headers,
  model discovery, connection testing, image and text bodies, response parsing,
  typed errors, and secret-free descriptions using a stub transport.
- `AssistantCoordinatorTests`: request-state transitions, one-time image fallback,
  cancellation, stale-response isolation, history append, mode switching, and scroll
  clamping using fake providers.
- `ScreenContextProviderTests`: complete, image-only after OCR failure,
  permission-denied, and capture/OCR failure outcomes using injected fakes.
- `WindowPrivacyPolicyTests`: settings window and every overlay panel receive the same
  policy derived from `OverlayStyle.invisibleInRecording`.
- Existing `AppSettingsTests`, `LiveTranscriptionSessionTests`, and overlay tests gain
  integration cases where the rebuilt feature crosses their boundaries.

### Continuous integration

Add a non-release workflow for pushes to `main` and `codex/**`, pull requests targeting
`main`, and manual dispatch. On a `macos-26` runner it executes:

1. `swift test`;
2. `node --test Tests/Docs/i18n.test.cjs`;
3. an unsigned Xcode Debug build; and
4. an unsigned Release build followed by a check that the app binary contains both
   `arm64` and `x86_64` slices.

The release workflow remains separate and is not triggered by test runs.

## Manual Verification Boundary

Automated tests cannot grant macOS permissions or prove real provider availability.
Before release, a human smoke test must cover microphone capture, application-audio
capture, the screen-recording permission path, global hotkeys in another app, privacy
behavior during an actual screenshot or recording, and one explicitly approved real
provider request. These checks are recorded separately and are not represented as CI
coverage.

## Acceptance Criteria

- The implementation branch is descended from the recorded upstream baseline and
  contains no merge or cherry-pick of the fork's seven custom commits.
- Every in-scope fork `main` feature is either supplied by upstream or rebuilt with an
  automated compatibility test.
- Legacy fork settings load without losing valid values and save in the new format.
- Upstream Swift and documentation tests pass unchanged or with justified additive
  updates.
- New assistant, migration, provider, lifecycle, and privacy tests pass.
- Debug and universal Release builds succeed on the supported CI runner.
- Test sources, fixtures, logs, and the final diff contain no real API keys, captured
  screens, private transcripts, or other user data.
- `origin/main` remains untouched until the user reviews the completed branch and
  explicitly approves a push or pull request.

## Out of Scope

- Features that exist only on `origin/multi-source-input` or `origin/test`.
- New assistant providers beyond the OpenAI-compatible and Gemini-compatible behavior
  already present on the fork's `main`.
- Release publication, notarization, signing, tags, or Homebrew publication.
- Replacing the upstream speech, translation, VAD, summarization, or single-instance
  implementations without a demonstrated compatibility defect.
