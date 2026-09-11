# v2s

<p align="center">
  <img src="Assets.xcassets/AppIcon.appiconset/AppIcon-256.png" alt="v2s app icon" width="256" height="256">
</p>

<p align="center">
  <strong>Private interview assistant and live bilingual subtitles for macOS.</strong>
</p>

<p align="center">
  v2s turns microphone or app audio into a clean two-line subtitle bar and includes an optional assistant for interviews, meetings, calls, streams, and videos. The assistant can use transcript history and visible screen context only when you explicitly ask it to help.
</p>

<p align="center">
  <a href="https://github.com/NX-lite/v2s">Source</a>
  ·
  <a href="https://github.com/NX-lite/v2s/releases">Releases</a>
  ·
  <a href="README.zh-CN.md">中文文档</a>
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/b65167ee-ae7e-4e37-8316-ebd200ae89a7" alt="Mar-20-2026 11-08-59">
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/449039ee-c329-426e-a55b-ab6660c56ca7" alt="Screenshot 2026-03-25 at 1 10 39 PM" width="500">
</p>

## Why v2s

- Follow live conversations with translated subtitles pinned at the top of your screen.
- Capture from one or more microphones and running macOS apps instead of your entire system mix.
- Keep the original speech and the translated line visible together for fast context switching.
- Use the optional assistant to prepare a follow-up or answer from the transcript and current screen.
- Stay in a lightweight menu bar workflow instead of juggling browser tabs or full-screen caption apps.

## Features

- Menu bar app built for always-available subtitle access.
- Live subtitle overlay with translated text on the first line and source text on the second.
- Multi-source audio selection for microphones and running macOS apps, with per-source input and output languages.
- Speech transcription powered by Apple's Speech frameworks, preferring on-device recognition and discovering the languages available on the current Mac.
- On-device translation powered by Apple Translation.
- Transcript summarization powered by Apple Intelligence, falling back to an on-device extractive summary when Apple Intelligence is unavailable.
- Core ML Silero VAD, without an ONNX Runtime dependency.
- Single-instance launch handling and overlay styling controls so the subtitle bar stays readable on top of real work.
- Optional assistant with explicit **Follow Up** and **Ask** actions. It supports OpenAI Responses-compatible and Gemini-compatible providers, an editable model, model discovery, and a connection test using the API configuration you supply.
- Three configurable global hotkeys: Follow Up, Ask, and switching subtitle/reply modes. Invalid or colliding bindings are reported in Settings.
- Screenshot capture and Vision OCR for an assistant request, plus an independent, scrollable reply overlay that never replaces subtitle history.
- **Invisible in Recording** is one privacy preference applied consistently to the overlay panels, Settings window, and subtitle-mode information window.

## Input and Subtitle Languages

v2s asks Apple's Speech and Translation frameworks which languages the current Mac supports, so the choices automatically follow OS and model updates. Regional variants are collapsed in the UI, while meaningful script variants such as Simplified and Traditional Chinese remain separate. Apple Translation availability is also checked for each source/destination pair before a session starts.

## Privacy

- No account, cloud backend, analytics, or telemetry.
- v2s has no cloud backend and does not send audio or subtitle text to its own servers.
- Translation uses Apple's on-device Translation framework. Some language packs may need to be downloaded first through System Settings.
- Speech recognition prefers Apple's on-device models, and v2s picks a language variant that has a local model whenever one exists.
- Some languages have no on-device model on a given Mac — this is common on Intel Macs, and for languages outside the modern Speech stack. Those run through Apple's server-based recognition, which needs a network connection, is subject to Apple's service quotas, and sends captured speech to Apple under Apple's privacy terms.
- Voice activity detection runs the [Silero VAD](THIRD_PARTY_NOTICES.md) model through Apple's system Core ML framework; v2s bundles no third-party inference runtime, and the [conversion is reproducible](scripts/convert_silero_vad_coreml.py).
- The assistant is optional. It sends no assistant request, transcript, screen image, or OCR data until you choose an explicit **Follow Up** or **Ask** action.
- Only after an explicit Follow Up or Ask, v2s may send the configured transcript (including timestamps and source/language context), skills prompt, current-screen image, and OCR text to your configured provider. What that provider retains or processes is governed by its own terms.
- If the provider rejects image input, v2s makes one text-only fallback request without the image while retaining available OCR text. Missing screen permission also degrades to text-only context; it does not block the request.
- Model discovery and the connection test contact the configured provider. They are configuration tools, not a claim that any particular provider, account, or model has been tested by this project.
- The API key is stored only in local settings on this Mac. Model discovery and API test use it to contact your configured provider; transcript, current-screen image, and OCR text are sent only after an explicit Follow Up or Ask.

## Optional assistant

Configure your API key, base URL, model, skills prompt, and three hotkeys in Settings. `Follow Up` asks for a concise continuation from the current context; `Ask` asks for an answer using the same context. A request may use an empty transcript with the fork-compatible placeholder, so a screen-only Ask is still possible. Provider reply text is displayed unchanged in the reply overlay, which has its own scroll position and can be switched back to subtitles without interrupting audio capture.

The assistant works with OpenAI Responses-compatible and Gemini-compatible API shapes. It can fetch offered models and run a configured connection test, but no real provider request is included in automated tests or documented as verified here.

## Design references

This is an independent Swift implementation; no code was copied. It only borrows high-level design references from [Meetily](https://github.com/Zackriya-Solutions/meetily/tree/a2cb62e827da7ef59f65064c97233efb2313878e) and the [1meeting-summary-ai candidate](https://github.com/Disalazario/meeting-summary-ai/tree/640efa955e62f6dfebfe4ac7e8c9651119469229): local-first privacy, cancellable provider operations, and synthetic tests/structural assertions. v2s is not fully local: Apple capabilities and configured provider operations can send data as disclosed above.

## Getting Started

### Install manually

1. Download the latest `.app.zip` from [NX-lite/v2s Releases](https://github.com/NX-lite/v2s/releases).
2. Unzip and move `v2s.app` to your Applications folder.

v2s may not be notarized by Apple. If macOS quarantines a manually installed copy, clear the flag once before launching it:

```bash
xattr -dr com.apple.quarantine /Applications/v2s.app
```

### First run

1. Launch v2s — it appears as an icon in your menu bar.
2. Select an input source (a running app or microphone).
3. Choose your input and subtitle languages.
4. Click **Start**.

v2s will ask for permissions on first use:

- **Speech Recognition** — to transcribe audio into text.
- **Microphone** — when using a microphone as the input source.
- **Audio Capture** — when capturing audio from another app.
- **Screen Capture** — only after an explicit Follow Up or Ask assistant request needs current-screen context.

## Requirements

- Speech transcription and translation require macOS 26 or newer
- Apple silicon and Intel Macs are supported. Which speech languages are available, and whether they recognize on device, depends on the Mac and the selected language.

## Building from Source

```bash
git clone https://github.com/NX-lite/v2s.git
cd v2s
open v2s.xcodeproj
```

Or from the terminal:

```bash
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug build
```

To build specifically for an Intel Mac:

```bash
swift build -c release --arch x86_64
```

## License

MIT
