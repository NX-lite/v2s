# Native Realtime Multi-Source Input and Chat Context Design

**Date:** 2026-09-28

**Status:** Approved by user on 2026-09-28; implementation authorized

**Branch:** `codex/upstream-rebuild-impl`

## Goal and boundaries

Add native realtime audio sessions for Qwen `qwen3.8-omni-flash-realtime`, Gemini
`gemini-3.8-live`, OpenAI `gpt-realtime-2.1-mini` and `gpt-realtime-2.1`, and xAI
Grok Voice (`grok-voice-latest` or `grok-voice-think-fast-2.0`). Retain the
existing ordinary Chat Completions, Responses, and Gemini `generateContent`
assistant and sentence-correction paths. A native
realtime model must never be selected or started merely because ordinary Chat
was used.

The user may select zero or more microphone or application-audio sources. Each
selected audio source has its own native realtime session, preserving source
attribution; the app does not mix audio from different sources into one provider
stream. The user may separately select zero or more display or application/window
visual sources. Continuous frame capture and upload are off by default. No
camera source, model speech playback, image generation, or automatic video-only
description is part of this feature. Without an active audio source, neither
native realtime sessions nor continuous visual capture start. The on-demand
Ask and Follow Up actions remain available.

Native realtime sessions enhance source-specific subtitles. They do **not** each
append a Chat reply. When the user invokes Ask or Follow Up, the existing
ordinary Chat assistant receives a single, source-attributed transcript snapshot
plus selected visual frames or the legacy one-shot screenshot, then produces
one reply for that action. Ask and Follow Up keep their distinct prompts and
may produce different replies.
They are never combined into one action or triggered automatically by a subtitle.

## Existing architecture to preserve

`InputSource` and `SourceCatalogService` already enumerate microphone and
application-audio sources. `AppModel` creates a `LiveTranscriptionSession` for
each selected source. Apple Speech and Translation produce immediate local-first
captions. `RealtimeCorrectionCoordinator` currently makes sentence-scoped HTTP
correction requests, whereas `AssistantCoordinator` handles on-demand Ask and
Follow Up with its own settings and prompt branches. The current assistant takes
one display screenshot only when either action is invoked. These paths remain
functional and independently configured after migration.

The existing 2026-09-13 correction design said continuous correction never
captures a screen image. This design supersedes that restriction **only** for
explicitly enabled, selected visual sources in the new native realtime mode.
The ordinary Chat one-shot screenshot behavior is unchanged when continuous
visual capture is off. Privacy disclosures, permission text, and tests must be
updated before continuous frames can be enabled.

## Architecture and ownership

1. A new realtime-mode settings value chooses one provider/model profile and
   reuses the app's existing selected audio sources. It defaults to off and is
   independent of both existing assistant settings and sentence-HTTP correction
   settings. A source cannot run both native realtime enhancement and legacy
   sentence-HTTP correction at once; the UI presents an explicit per-source
   choice, preventing duplicate paid requests. Migrated settings preserve the
   legacy mode and leave the new mode off. The selected provider/model/region
   profile may persist, but active realtime and continuous-video states do not
   auto-start after app launch. Visual source choices are session-only and are
   cleared on stop, so a disappeared window is never rebound by title.
   Provider-specific settings include an allowlisted model, official region,
   Keychain credential reference, and Qwen workspace ID where required.
   The app derives Qwen's endpoint from the configured workspace ID and region
   and validates their format before start. It cannot prove a key's region
   offline; a provider rejection is reported without changing regions.
2. A `RealtimeSessionDriving` boundary owns start, stop, source identity,
   cancellation generation, bounded input, protocol events, and output text.
   Concrete adapters implement the four vendor protocols with a fakeable
   WebSocket transport. The existing HTTP correction client is not repurposed
   as a streaming transport.
3. A capture fan-out obtains normalized audio chunks from each existing
   `LiveTranscriptionSession` without waiting on network I/O on its capture
   queue. The session driver receives only that source's audio. A local source
   token, utterance token, and monotonic timestamps remain attached to events.
   Each adapter uses explicit client-controlled utterance boundaries and manual
   commit/response events where the provider supports them; it permits at most
   one in-flight utterance response per source. A provider response may replace
   a local caption only when its response/commit sequence maps unambiguously
   to that utterance token and current generation. Otherwise it is a suggestion
   only.
   Stale events from stopped or replaced sessions cannot update captions.
4. A separate `VisualSource` catalog and capture coordinator enumerate displays
   and application/windows through ScreenCaptureKit. Video source selection is
   independent of audio selection. The continuous-video toggle starts off for
   every app launch. Turning it off clears the in-memory visual selection and
   all captured frames; with no active audio source it cannot start. When off,
   Ask/Follow Up use the existing single current-display screenshot, even if a
   source had been selected earlier in that app session. Enabled visual sources
   form a **shared** context for all active audio sessions whose native provider
   supports video;
   there is no per-audio visual mapping. Before start, the UI shows that each
   selected frame can be sent once per eligible audio session, so selecting
   multiple audio sources can multiply provider usage.
5. An assistant context builder takes a consistent snapshot of the effective
   caption history and the newest enabled, selected frame for each visual source
   when the user invokes Ask or Follow Up. The ordinary Chat responder gains a
   bounded multi-image input rather than creating a new Chat reply per source.
   If continuous video is off or no visual source is selected, it retains the
   current one-shot display screenshot behavior. Selected-source frames replace,
   rather than silently supplement, that one-shot screenshot for an action.

## Source attribution and subtitle behavior

Every local subtitle and provider result retains source token, source type,
capture time range, language pair, caption ID, and session generation. The app
sends each realtime session a source-specific instruction identifying an
ephemeral alias (for example, `audio-1`) and that source's role. It never sends
raw microphone hardware IDs, application bundle IDs, window IDs, or window
titles as source identifiers. The UI shows the local mapping from aliases to
user-selected sources. Where a protocol supports supplementary text context,
committed local transcription is sent as a labeled record without treating it
as speech from another source; where it does not, the source-specific session
instruction and local event mapping remain authoritative. Provider-generated
text is never trusted to label its own source. The ordinary Chat snapshot always
serializes each transcript entry with its ephemeral alias, user-approved friendly
source label, category, time, original text, and translation. The app shows the
exact labels before sending and keeps raw capture identifiers local.

Visual frames use ephemeral aliases (`display-1`, `window-1`) visible in a
preview and in the Chat context. At most four visual sources can be selected
in one capture session; the picker blocks a fifth rather than silently
discarding it. If multiple sources are selected, the capture coordinator
makes one labeled composite frame per eligible session, at no more than one
frame per second total per session; it does not send one frame per second per
source. The composite is at most 1920 by 1080 pixels and 1 MiB encoded. For
Chat, at most one fresh frame per selected source is attached in selection
order, each at most 1024 by 1024 pixels and 1 MiB encoded, with a 4 MiB total.
Frames older than five seconds are not reused; a source that cannot meet the
bound is reported as unavailable rather than silently omitted. When a
provider lacks native video input, the app does not stream frames to that
realtime session. Explicitly selected latest frames may still be attached to
the ordinary Chat Ask/Follow Up request if that ordinary Chat model supports
images. If it rejects images, the assistant may retry once with locally
extracted, source-labeled OCR text and no images, while visibly marking that
images were not sent. It never reports such a fallback as an image request.

Local Speech/Translation results appear first. The native session is instructed
to return a concise corrected transcript of the current utterance, not a
conversational assistant answer. A validated corrected source-language text
may update only its matching source and caption; the existing local translation
path then translates that corrected text. A malformed or conversational model
answer is not treated as a subtitle. If provider output cannot be
matched unambiguously to a caption, it remains a source-labeled suggestion and
cannot overwrite another source's caption or the current caption of a later
utterance. Provider output is not inserted into the Chat reply list. Ask and
Follow Up each receive the effective, source-labeled transcript snapshot and
the selected frames, use their existing distinct prompt instructions, and
append exactly one corresponding ordinary Chat reply on success.

## Provider-specific behavior

| Provider | Native input and visible output | Visual frames | Important constraint |
| --- | --- | --- | --- |
| OpenAI `gpt-realtime-2.1-mini` / `gpt-realtime-2.1` | Audio input, request text output | No native video stream | Use its realtime WebSocket events; do not silently turn selected frames into video. |
| Qwen `qwen3.8-omni-flash-realtime` | Audio input, text-only output | Yes | Use the workspace/region-specific WebSocket endpoint and one bounded image sequence per session. |
| Gemini `gemini-3.8-live` | Audio input, display output-audio transcription as text; never play output audio | Yes | The model requires AUDIO response modality, so hidden generated audio may still be billed; audio/video sessions need documented resumption/expiry handling. |
| xAI Grok Voice `grok-voice-latest` | Audio input, request per-response text modality | No | Use manual audio commit and `response.create` with `modalities: ["text"]`; input audio is still billable. |

The UI states the actual modality and likely billing consequence before any
session is started. It never represents muting Gemini's generated audio as
avoiding output-audio charges. Provider quotas, region availability, and
session-expiry rules are validated against official documentation during
implementation; unsupported configurations fail visibly, without silently
changing providers or sending media to a different region. The xAI official
`response.create` schema permits a text-only response request, but live
acceptance for the selected account/model remains unverified without a paid
call. If xAI rejects text-only mode or emits audio despite that request, v2s
does not play it or silently switch to audio output; it stops that realtime
source and shows the limitation.

Official protocol references: [OpenAI realtime](https://developers.openai.com/api/docs/guides/realtime-conversations),
[Qwen realtime](https://help.aliyun.com/en/model-studio/realtime),
[Gemini Live](https://ai.google.dev/gemini-api/docs/live-api/capabilities),
and [xAI Voice realtime](https://docs.x.ai/developers/rest-api-reference/inference/voice#response.create).

## Privacy, credentials, and lifecycle

The settings UI separately identifies the audio sources sent to a native
provider, the visual sources continuously sent to Qwen/Gemini, and the latest
visual frames attached to the **ordinary Chat provider** only when Ask or
Follow Up is invoked. These may be different companies, and the UI identifies
both recipients. Continuous video is off by default, including on settings
migration. A persistent live indicator shows each active audio and visual
source and its recipient. Removing a source,
disabling video or realtime mode, stopping capture, or changing provider/model
immediately stops relevant sends and invalidates pending results. Permission
loss never broadens capture to another display or window.

Continuous capture hard-excludes v2s's own settings, overlay, and other windows.
Only currently selected visual sources are captured; there is no fallback to
whole-display capture when a selected window disappears. Individual-window
selections are never persisted or automatically rebound by title. Display and
application selections are also kept session-only to avoid stale identity and
unnecessary metadata storage. Frames and audio are short-lived in memory, with
newest-frame-only queues and bounded audio buffers. Source removal, disabling
video or realtime mode, permission loss, provider/model change, stop, or window
disappearance atomically clears affected frame pixels, OCR text, composites,
and queued sends; subsequent Ask/Follow Up must take a fresh permitted capture.
The app never writes raw media, provider event payloads, OCR, or API keys to
settings, diagnostic logs, fixtures, or app-controlled disk caches. Final
subtitle text follows the existing transcript-retention behavior; the new
realtime path creates no separate raw-content archive. It never logs raw
WebSocket payloads, event bodies, authorization headers/query values, close
reasons, OCR, or
source-labeled transcript context in any build configuration. UI and diagnostic
errors use allowlisted codes and sanitized generic messages, not raw provider
echoes. New realtime credentials are kept in Keychain, not the JSON settings
file; existing ordinary Chat credentials/settings are not changed as part of
this feature. Native realtime endpoints require authenticated TLS
(`wss`/`https`) and provider-appropriate region selection.

All existing screenshot-related privacy descriptions and translations must be
revised to distinguish on-demand ordinary Chat screenshots from explicitly
enabled continuous visual frames. The disclosure names audio, transcript text,
language/source labels, frame pixels, recipients, session duplication, and
provider retention-policy responsibility. The app does not claim a provider
will delete media immediately after processing.

## Failure, cost, and backpressure

A failing realtime session affects only its audio source; local subtitles,
other sessions, and ordinary Chat remain available. Network failure, model
capability rejection, permission denial, rate limiting, and expiry are shown as
distinct localized states. There is no automatic cross-provider fallback and
no automatic replay of previously sent audio or frames. A restart creates a
new generation; stale callbacks cannot mutate later captions. Where Gemini
session resumption is supported, implement it explicitly and test context
continuity; if it cannot resume, show the context reset rather than implying a
continuous session.

At most one composite video frame per second is queued for each eligible
realtime session; older unsent frames are discarded under backpressure. Audio
queues are bounded and stop or mark a session degraded when they cannot keep
up, rather than growing without limit or silently presenting delayed output
as current. Before start, the UI shows the number of simultaneous native
sessions, selected visual sources, recipients, and a nonnumeric cost warning.
It also explains that each Ask or Follow Up is a separate ordinary Chat request
that may incur additional charges.
It does not hard-code the user-provided price estimates, which may vary by
region, usage mode, and date.

## Verification and acceptance

Implementation is sequenced as (1) settings, capture interfaces, attribution,
and transport seams; (2) four native audio protocol adapters; (3) selected
display/window frames and multi-image ordinary Chat context; and (4) complete
verification. These are engineering stages, not claims of partial delivery.

All automated provider tests use fake WebSocket transports and synthetic audio
and frames. They cover each protocol's setup, auth URL construction, event
parsing, text-only or transcript mode, source mapping, one session per selected
audio source, one composite visual sequence per eligible session, stale-event
rejection, stop/restart, backpressure, expiry, error sanitization, and refusal
to send unselected media. They also exercise Qwen workspace/region validation,
client utterance-to-caption correlation, rejection of ambiguous provider turns,
the four-source/five-second/size limits, atomic cache clearing on every
revocation path, and absence of sensitive payloads in diagnostic/error paths.
Assistant tests establish that Ask and Follow Up keep
different prompts, that one invocation yields one corresponding Chat reply,
that frames and source-attributed transcripts are input context, and that the
pre-existing ordinary Chat modes and one-shot screenshot path still work.

Run focused tests, all local Swift and documentation tests, then full Xcode
Debug and universal Release validation in macOS CI. A passing local or CI test
does not prove a real provider accepts the protocol. No automated test uses
real credentials, paid provider calls, live microphone input, or live screen
capture. Real-provider/manual validation requires separate explicit approval,
and no push, PR, merge, or release is implied by this design.
