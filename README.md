<p align="center">
  <img src="./public/assets/readme/character.png" alt="Mac Whisper mascot" width="120">
</p>

<h1 align="center">Mac Whisper</h1>

<p align="center">
  <em>Hold Fn, speak, and paste clean dictation into the app you are using.</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-0.0.1-111111?style=flat-square" alt="Version 0.0.1">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-111111?style=flat-square" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-111111?style=flat-square" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-5.9-111111?style=flat-square" alt="Swift 5.9">
</p>

<p align="center">
  <sub><a href="./README.md">English</a> &middot; <a href="./README.ko.md">한국어</a></sub>
</p>

<p align="center">
  <a href="https://github.com/bytonylee/mac-whisper/releases/latest/download/MacWhisper.dmg"><img src="./public/assets/readme/download-macos.png" alt="Download MacWhisper.dmg for Mac OS" width="270"></a>
</p>

---

<p align="center">
  <img src="./public/assets/readme/mac-whisper-demo.gif" alt="Mac Whisper push-to-talk dictation demo" width="100%">
</p>

Mac Whisper is a macOS menu bar app for push-to-talk dictation. Hold Fn, speak,
release, and the transcript is pasted into the text field that already has
focus.

It can also run a conservative LLM cleanup pass before pasting. The cleanup is
optional, and the raw transcript is used if the LLM request fails.

> Built for writing in any app without switching windows, opening a recorder, or
> managing a separate transcript box.

**The app listens for the Fn key through HID, records with Speech framework,
shows a floating HUD while you talk, and pastes through the clipboard with a
simulated Cmd+V. It prefers the built-in microphone during dictation so
Bluetooth headphones can stay in high quality playback mode.**

## Why this exists

macOS dictation works, but it is not tuned for quick push-to-talk writing across
every app. Mac Whisper keeps the flow simple:

- hold Fn to start
- release Fn to stop
- see the live transcript while speaking
- paste into the focused text field
- optionally clean up recognition mistakes with an LLM

It is meant for short writing bursts: messages, notes, prompts, search boxes,
issue comments, and anywhere else your cursor already is.

## Status

| Area | Behavior | Notes |
|---|---|---|
| Trigger | Hold Fn or Globe | Read from keyboard HID, not a global hotkey |
| Speech | Live streaming recognition | Supports English, Korean, Chinese, and Japanese |
| HUD | Floating transcript panel | Uses Liquid Glass on macOS 26 |
| Audio | Built-in mic preference | Avoids forcing Bluetooth headsets into call mode |
| Paste | Clipboard plus Cmd+V | Restores the previous clipboard after insertion |
| LLM | Optional cleanup | Supports OpenAI-compatible and Anthropic-compatible endpoints |

Menu controls:

- `Language` changes the recognition locale.
- `LLM Refinement` toggles cleanup and opens settings.
- `Auto-stop on Silence` ends recording after a quiet pause.
- `Permissions...` shows microphone, speech, input monitoring, and accessibility status.

## Install

Download the latest `MacWhisper.dmg` from
[Releases](https://github.com/bytonylee/mac-whisper/releases/latest), open it,
and drag **Mac Whisper** into Applications.

Or build the app locally:

```bash
git clone https://github.com/bytonylee/mac-whisper.git
cd mac-whisper
make app
open "build/Mac Whisper.app"
```

Requirements:

- macOS 26+
- Xcode command-line tools
- Microphone permission
- Speech Recognition permission
- Input Monitoring permission
- Accessibility permission

For stable local permissions across rebuilds, create a self-signed signing
identity once:

```bash
make cert
make app
```

Without that identity, ad hoc signing can make macOS ask for Input Monitoring
and Accessibility permissions again after each rebuild.

## How It Works

The app creates a fresh speech session when Fn is pressed.

```text
Fn key down -> start audio engine -> stream recognition -> update HUD
Fn key up   -> stop recognition -> optionally refine -> paste text
```

The API key for LLM refinement comes from the environment:

```bash
cp .env.example .env
# edit .env:
#   MACWHISPER_LLM_API_KEY=sk-...
make run
```

Installed apps launched from Finder can use:

```bash
launchctl setenv MACWHISPER_LLM_API_KEY sk-...
```

You can also put the same line in `~/.config/macwhisper/.env`.

## Build

Compile:

```bash
make build
```

Build and launch:

```bash
make run
```

Create a DMG:

```bash
make dmg
```

## For agents

One-time setup to build and launch the app:

```bash
cd /path/to/mac-whisper
make app
open "build/Mac Whisper.app"
```

For a quick compile check, run:

```bash
swift build
```

## Security

- The app needs microphone and speech recognition access to transcribe audio.
- Input Monitoring is used only to read the Fn or Globe key.
- Accessibility is used to paste text into the focused app.
- Transcript text is not written to the diagnostic log.
- The LLM API key is read from the environment, not from UserDefaults.
- If LLM cleanup fails, the app pastes the raw transcript.

## Tests

```bash
swift build
```

Manual checks still matter because macOS permissions, HID input, paste
injection, and audio routing depend on system state.

## Release

Current tag: [`0.0.1`](https://github.com/bytonylee/mac-whisper/releases/tag/0.0.1)

The `0.0.1` release includes push-to-talk dictation, the floating transcript
HUD, language selection, optional LLM cleanup, local build scripts, and DMG
packaging.

## License

MIT
