# v2s

<p align="center">
  <img src="Assets.xcassets/AppIcon.appiconset/AppIcon-256.png" alt="v2s app icon" width="256" height="256">
</p>

<p align="center">
  <strong>Live bilingual subtitles for meetings, calls, streams, and videos on macOS.</strong>
</p>

<p align="center">
  v2s turns microphone input or app audio into a clean two-line subtitle bar so you can follow speech in one language and read it in another without leaving the screen you are already using.
</p>

![v2s screenshot](https://github.com/user-attachments/assets/d5f10b08-a4a2-463e-9c0c-ad18c5d890b0)

## Why v2s

- Follow live conversations with translated subtitles pinned at the top of your screen.
- Capture from your microphone or from a specific macOS app instead of your entire system mix.
- Keep the original speech and the translated line visible together for fast context switching.
- Stay in a lightweight menu bar workflow instead of juggling browser tabs or full-screen caption apps.

## Standout Features

- Menu bar app built for always-available subtitle access.
- Live subtitle overlay with translated text on the first line and source text on the second.
- Audio source selection for microphones and running macOS apps.
- Apple Speech transcription pipeline for live recognition.
- Apple Translation pipeline for bilingual subtitle output.
- Overlay styling controls so the subtitle bar stays readable on top of real work.

## What You Can Use Today

- Launch v2s as a macOS menu bar app.
- Pick a microphone or a supported app audio source.
- Start a live transcription session.
- See translated subtitles appear in a floating desktop overlay.
- Adjust overlay appearance from settings.

## In Progress

- Better subtitle segmentation and pacing.
- Wider app-audio compatibility and diagnostics.
- Signed and notarized distribution.
- Smoother release packaging workflow.

## Requirements

- macOS 15 or newer
- Xcode 17 or newer
- Speech Recognition permission
- Audio capture permission when using app audio sources

## Run Locally

Open the Xcode project:

```bash
open /Users/franklioxygen/Projects/v2s/v2s.xcodeproj
```

Build from the terminal:

```bash
cd /Users/franklioxygen/Projects/v2s
swift build
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/v2s.app
```

## Release

Create a GitHub release with an auto-bumped version and a versioned installer package:

```bash
cd /Users/franklioxygen/Projects/v2s
./scripts/release.sh
```

Optional bumps:

```bash
./scripts/release.sh patch
./scripts/release.sh minor
./scripts/release.sh major
./scripts/release.sh 1.2.0
```

The release script:

- requires a clean `main` worktree
- bumps `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `v2s.xcodeproj/project.pbxproj`
- builds the Release app with code signing disabled
- creates `dist/v2s-<version>.pkg` and `dist/v2s-<version>.sha256`
- commits the version bump, tags `v<version>`, pushes to GitHub, and creates a GitHub release with both assets attached

Requirements:

- authenticated GitHub CLI: `gh auth login`
- a buildable project state

Current release packaging is unsigned, so add signing and notarization later if you want a production-ready macOS distribution flow.

## Documents

- [System Design](docs/v2s-system-design.md)
- [MVP Plan](docs/v2s-mvp-plan.md)
