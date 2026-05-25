# VocalDraft

A small macOS overlay for hold-to-transcribe dictation and voice-driven text edits.

## What It Does

- Shows a draggable always-on-top pill overlay.
- Displays an animated waveform while recording.
- Hold `Command+3` to dictate; release to paste the final transcript into the active text field.
- Hold `Command+4` to voice edit the current text target; release to replace the selected text, or the focused text field contents if nothing is selected.
- Streams 24 kHz mono PCM audio to an OpenAI Realtime transcription session with `gpt-realtime-whisper`.
- Uses `gpt-realtime-2` for edit instructions and requests text-only replacement output.
- Commits the audio buffer when the held hotkey is released.
- Preserves the pasteboard after inserting generated text.

## Setup

Set your API key in a local `.env` file:

```bash
./scripts/set-api-key.sh sk-...
```

Build the app bundle:

```bash
./scripts/build-app.sh
```

Run it:

```bash
open build/VocalDraft.app
```

On first launch, macOS will ask for permissions. Grant:

- Microphone, so the app can record while the hotkey is held.
- Accessibility and Input Monitoring, so it can detect the global hold hotkeys, inspect the focused text field for edits, and paste into the active field.

If the microphone prompt appears the first time you hold `Command+3` or `Command+4`, grant access and then hold the hotkey again to start recording.

If the key is not set, right-click the pill and choose `Set API Key...`.

## Development

The app reads `OPENAI_API_KEY` from the process environment first, then from `.env`.
You can also run from SwiftPM with an inline environment variable:

```bash
OPENAI_API_KEY=sk-... swift run
```

Running from SwiftPM may prompt for permissions under Terminal or your shell instead of the app bundle. For normal use, prefer the `.app` bundle.
