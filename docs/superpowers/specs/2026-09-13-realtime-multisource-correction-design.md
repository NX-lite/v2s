# Real-Time Multi-Source Model Correction Design

**Date:** 2026-09-13

**Status:** Approved in conversation

**Implementation branch:** `codex/upstream-rebuild-impl`

## Objective

Extend the existing multi-source subtitle pipeline with optional real-time model
correction. Each selected microphone or application source keeps its independent
input and output languages. Local speech recognition and local translation remain
the immediate, always-available result; a configured remote model may later correct
that result without blocking capture, recognition, translation, or display.

An audio-capable model receives the committed sentence's audio plus the local
original and translation and returns both a corrected original and corrected
translation. If the provider explicitly rejects audio input, that model falls back
for the rest of the current session to text-only correction: the local original is
preserved and only the translation is corrected.

The existing assistant remains a separate on-demand workflow. It captures the
current screen only when the user invokes Follow Up or Ask. Real-time correction
never captures or sends a screenshot.

## Existing Foundation to Preserve

The current application already provides:

- simultaneous microphone and application-audio input selection;
- per-source speech-recognition and translation language overrides;
- Apple Speech recognition with on-device preference;
- Apple Translation, glossary application, draft promotion, committed-caption
  display, transcript history, and late-translation backfill;
- an OpenAI-compatible and Gemini-compatible assistant with on-demand screen capture;
- Debug and universal `arm64` plus `x86_64` Release builds.

The correction feature extends these boundaries. It does not replace local Speech or
Translation, combine source capture sessions, or move screenshot capture into the
continuous subtitle path.

## User-Visible Behavior

### Local-first subtitles

For every committed sentence, v2s displays the local recognition and local
translation as soon as they are available. Model correction runs after this local
commit. A slow, unavailable, rate-limited, or misconfigured provider cannot delay or
stop the local subtitle pipeline.

When a valid correction arrives, v2s updates the matching current caption, overlay
history entry, and transcript entry. A result for an older caption may update that
caption in history, but it cannot replace a newer current caption. A result from an
earlier session cannot update any state in a later session.

### Audio and text correction modes

The first correction request for a model in a session uses audio mode. It contains:

- the committed sentence's in-memory WAV audio;
- the source name and stable source identifier;
- the configured source and target languages;
- the local recognized original and local translation; and
- a bounded context of earlier successfully corrected entries.

Audio mode returns both `correctedOriginal` and `correctedTranslation`. Both values
replace the local display values for that caption after validation.

When the provider gives a recognized audio-capability rejection, the coordinator
immediately retries that caption once in text-only mode and remembers the downgrade
for that model for the remainder of the session. Later requests in that session omit
audio. Text-only mode preserves the local original and accepts only a corrected
translation. Authentication errors, rate limits, timeouts, transport failures, and
malformed responses do not imply lack of audio support and therefore do not trigger
the capability downgrade.

The capability decision is session-scoped rather than persisted. A new session tries
audio again, allowing a provider or model upgrade to take effect without resetting
settings.

### Settings and privacy

Real-time correction uses a nested settings value independent from the on-demand
assistant. It contains its own API key, base URL, and model. Changing assistant
settings cannot change correction requests, and changing correction settings cannot
change Follow Up or Ask.

The global real-time-correction toggle defaults to off, including after migration
from every existing settings format. When off, no correction audio or text is sent.
After the user explicitly enables it, each source can still be disabled individually.
Each source also has an independent "isolated context" option.

The settings UI explains that correction continuously sends sentence audio, local
subtitle text, language metadata, source labels, and corrected context to the chosen
provider. It also makes the current session mode visible as either audio correction
or text-only translation correction. Provider failures appear as non-blocking,
localized status rather than replacing the subtitle or stopping capture.

Disabling correction, stopping the session, or changing the correction endpoint,
API key, or model cancels active and queued correction work. References to unsent and
completed sentence audio are then released. Sentence audio is held only in memory
and is never written to settings, logs, fixtures, transcripts, or disk caches.

## Architecture

### Caption correction record

The subtitle pipeline needs an internal caption record that keeps correction identity
separate from display text. Each committed record contains:

- caption identifier and session generation;
- capture timestamp;
- source identifier and display name;
- source and target language identifiers;
- local original and local translation; and
- optional corrected original and corrected translation.

Display text is derived from the corrected value when present and otherwise from the
local value. Local values remain available for deterministic fallback and are never
replaced in place. Model requests are always constructed from local values plus prior
successful correction context, so a duplicate callback cannot recursively correct
its own output.

Source and language metadata also become part of transcript snapshots. The on-demand
assistant therefore receives corrected display values where available and retains
source labels for a multi-source conversation.

### Sentence audio ownership

Each `LiveTranscriptionSession` owns a source-specific sentence audio accumulator on
its existing capture queue. It appends the same normalized 16 kHz mono samples used
by speech recognition and closes the accumulator at the recognition commit boundary.
The completed samples are encoded as an in-memory linear-PCM WAV payload and attached
to the recognized-sentence callback. Starting the next sentence creates a new
accumulator.

If one recognizer commit yields more than one textual sentence, speech segment timing
is used to partition the utterance when valid timing is available. When the platform
does not provide a reliable internal boundary, the containing committed utterance is
used for each emitted sentence and the request identifies the target local sentence.
This fallback retains the relevant speech instead of inventing an audio split.

Audio that belongs to a disabled source is discarded at commit and never enters the
correction coordinator. Dropping an unsent queue item releases its audio payload.
Finishing a request releases its payload after response handling.

### `RealtimeCorrectionCoordinator`

`RealtimeCorrectionCoordinator` is independent from `AssistantCoordinator` and from
`AppModel`'s local translation implementation. It accepts immutable correction jobs
and emits caption-ID-addressed results and non-blocking status updates.

Scheduling follows four rules:

1. Jobs from one source execute strictly in capture order.
2. At most two provider requests execute across all sources at once.
3. Each source may have at most three waiting, not-yet-sent jobs. When a fourth job
   arrives, the oldest waiting job is skipped, its audio is released, and its local
   subtitle remains unchanged. The currently active job is not counted as waiting.
4. Stopping or reconfiguring invalidates a monotonically increasing generation before
   tasks are cancelled, so even a transport that ignores cancellation cannot publish
   stale results.

Context is assembled when a job is dispatched, not when it is enqueued, so it sees
the newest completed corrections. The default context consists of the six most
recent successfully processed entries across all sources, ordered by capture time.
Every entry includes its source label, language pair, effective original, and
effective translation. Entries skipped because of overload or failed correction are
not included.

For a source marked as isolated, context contains only the six most recent successful
entries from that same source. The isolated source's successful entries remain in the
default global timeline for other non-isolated sources; isolation controls what that
source sends, not whether other sources can use its conversation contribution.

### Provider boundary

The correction provider reuses the existing injectable HTTP transport and endpoint
normalization patterns but has correction-specific request and response models.
OpenAI-compatible and Gemini-compatible encoders serialize the same semantic input:
instructions, structured text context, and optional WAV audio. No correction request
contains a screenshot.

The provider is instructed to preserve meaning, names, numbers, terminology, and the
configured language pair; repair recognition errors using the audio and context; and
return only a structured result. The decoder requires non-empty strings for the
fields appropriate to the current mode:

- audio mode: `correctedOriginal` and `correctedTranslation`;
- text-only mode: `correctedTranslation`.

Unknown fields are ignored. Missing fields, empty results, prose outside the expected
structured value, and invalid JSON fail that job without changing its local caption.
Provider error text is sanitized with the same secret-redaction boundary as existing
assistant errors.

### App integration and safe backfill

`AppModel` creates and resets the correction coordinator with the logical subtitle
session. After local translation commits, it submits the corresponding caption record
and audio if global and per-source settings permit. Model completion is applied only
when caption ID and session generation both match.

Backfill updates three independently addressable locations:

- the currently displayed caption, only when it still has the same caption ID;
- overlay history, by caption ID; and
- transcript history, by caption ID.

A correction never mutates pending recognition state, translation-session state,
speech hints, or another source's draft. Updating a visible caption recalculates its
remaining display duration without replaying its entrance animation. A failed or
skipped correction leaves the local values intact.

## Request Flow

1. A source captures and normalizes audio while local recognition runs.
2. Recognition commits a sentence and its matching in-memory audio payload.
3. Apple Translation produces the local translation and v2s immediately commits the
   local caption to display, history, and transcript state.
4. If correction is enabled globally and for the source, `AppModel` enqueues an
   immutable job.
5. The coordinator applies the per-source queue limit, waits for that source's turn
   and one of the two global request permits, then builds the latest bounded context.
6. The correction client sends audio mode unless the current session has already
   downgraded that model.
7. A recognized audio rejection causes one text-only retry and session-scoped
   downgrade. Other failures end the job without retry or subtitle mutation.
8. A valid current-generation result is backfilled by caption ID and recorded as
   successful context. The job's audio payload is released.
9. Follow Up or Ask remains independent: only that explicit action captures the
   current screen and sends the then-current corrected transcript snapshot.

## Lifecycle and Failure Rules

- Missing or invalid correction configuration prevents correction submission and
  surfaces a non-blocking configuration status; local subtitles continue.
- A source startup failure cannot leave a queue or audio accumulator behind for that
  source.
- Partial multi-source startup creates correction scheduling only for sources whose
  capture actually started.
- Provider authentication, rate-limit, timeout, network, decoding, and content
  failures affect only their job and never stop a transcription session.
- Audio capability fallback occurs at most once per model per logical session.
- Queue overflow is observable through status or diagnostics without logging audio,
  subtitle content, API keys, or raw provider bodies.
- Source disablement cancels and clears that source's active and queued work without
  affecting siblings; the global toggle and provider reconfiguration cancel and
  clear every source.
- Existing local late-translation behavior remains valid. A correction job is
  submitted only after a concrete local translation outcome is committed; it is not
  resubmitted when local late-backfill updates the same caption.
- Application termination cancels correction tasks and releases in-memory payloads.

## Automated Test Strategy

All implementation work follows red-green-refactor. Tests use injected capture,
transport, clock, and scheduling dependencies; no test contacts a real provider,
captures a real microphone, or includes private user content.

### Settings and migration

- correction defaults off for fresh and legacy settings;
- independent endpoint, key, model, per-source disable, and context-isolation values
  round-trip without changing assistant settings;
- malformed new fields fall back independently;
- changing provider identity invalidates current correction work.

### Sentence audio

- synthetic normalized PCM produces a valid mono 16 kHz linear-PCM WAV;
- a commit closes exactly one accumulator and starts the next;
- platform segment timing partitions a multi-sentence utterance when available;
- unreliable timing uses the documented containing-utterance fallback;
- disabled, dropped, stopped, and completed jobs release their audio references;
- audio bytes and transcript text never enter logs or persisted settings.

### Coordinator scheduling and context

- jobs from one source never overlap and publish in order;
- two different sources may run concurrently, while a third waits;
- a fourth waiting job for one source skips the oldest waiting job but not its active
  request;
- default context contains the six most recent successful entries in global capture
  order with source and language labels;
- isolated context contains only successful entries from its source;
- skipped and failed jobs do not become model-corrected context;
- cancellation and generation checks reject late completions.

### Provider protocol

- OpenAI-compatible and Gemini-compatible bodies encode text and WAV audio without a
  screenshot field;
- valid audio-mode and text-only structured results decode correctly;
- explicit audio rejection retries once without audio and downgrades the session;
- authentication, rate limit, timeout, and malformed output do not downgrade;
- invalid, empty, or partial results preserve local caption values;
- errors and diagnostic strings redact the configured API key.

### Application integration

- local recognition and translation display before a suspended correction completes;
- audio-mode completion updates original and translation by caption ID;
- text-only completion preserves the local original and updates only translation;
- a late result updates matching history without replacing a newer visible caption;
- a previous-session result cannot mutate a new session;
- a disabled source makes no correction request while enabled siblings continue;
- stopping, disabling, or reconfiguring clears the correct scope queues without
  interrupting local capture;
- on-demand Ask and Follow Up still capture one current screenshot only when invoked
  and use corrected transcript values where available.

### Build verification

The final branch must pass:

1. the complete Swift test suite;
2. documentation and Xcode-project structure tests;
3. unsigned Xcode Debug compilation;
4. unsigned Xcode Release compilation; and
5. verification that the Release executable contains `arm64` and `x86_64` slices.

## Manual Verification Boundary

Automated tests cannot prove the behavior of a real provider or macOS permission
dialog. Before publishing a release, a human smoke test must cover two simultaneous
real sources with different source languages, visible local-first replacement,
audio-capable correction, a text-only fallback provider, queue overload, per-source
disablement, isolated context, session cancellation, and a separate Ask request with
an on-demand screenshot. A real-provider test requires explicit approval and must not
record its key, audio, screen, transcript, or raw response in the repository or CI.

## Acceptance Criteria

- Existing simultaneous source capture and per-source language behavior remains
  unchanged when correction is disabled.
- Correction is disabled by default and sends nothing until explicitly enabled.
- Every local subtitle remains usable without a provider and appears without waiting
  for model correction.
- An audio-capable request may update both original and translation; recognized lack
  of audio support switches the session to translation-only text correction.
- One source is processed sequentially, no more than two sources call the provider at
  once, and no source holds more than three waiting jobs.
- The default six-entry global corrected context and per-source isolated context match
  their configured semantics.
- Late, cancelled, stale, invalid, failed, and dropped work cannot overwrite unrelated
  subtitles or stop local recognition and translation.
- Continuous correction never captures or sends screen content. Ask and Follow Up
  retain on-demand screenshot behavior.
- No captured audio, screen image, API key, private transcript, provider response, or
  machine-specific build artifact is committed or emitted by tests.
- The complete automated suite and universal Release build pass.

## Out of Scope

- replacing Apple Speech or Apple Translation with a cloud-only primary pipeline;
- continuous screen capture or visual context for automatic correction;
- provider-specific real-time streaming sockets;
- speaker diarization within one source;
- persisting raw sentence audio or provider request/response archives;
- automatically retrying every provider failure; and
- publishing a tag, GitHub Release, or Homebrew update as part of implementation.
