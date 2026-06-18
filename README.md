# April AI

A native macOS SwiftUI assistant that lives as both a full desktop window and a menu bar assistant. It is designed as a read-only, sarcastic, polymathic thinking partner: it can critique, explain, summarize, research, inspect on-demand screenshots, index a local context folder, and speak replies.

## Run

Recommended daily use: open the generated app bundle:

```text
../AprilAI.app
```

To rebuild that app bundle after code changes:

```bash
./scripts/make-app.sh
```

From this folder:

```bash
swift run
```

Use `swift run` only for development/debugging. It launches a raw executable, not a normal Dock app, so macOS can be weird about focus and app identity. You can also open `Package.swift` in Xcode and run the `AprilAI` target.

## First Setup

1. Open **Settings**.
2. Add your Gemini API key.
3. Keep the default text model, `gemini-3.5-flash`, or change it from the picker.
4. Keep the default Live model, `gemini-3.1-flash-live-preview`, for the future Live API voice path.
5. Open the **Context** tab.
6. Drop PDFs, Markdown, text files, notes, logs, or code into `context/inbox`.
7. Click **Index inbox**.

If macOS does not focus the API key field when running from `swift run`, use **Paste Clipboard** or **Enter in Dialog** in Settings. You can also launch with an environment key:

```bash
GEMINI_API_KEY="your-key" swift run
```

Then click **Use Env Key** and **Save Gemini Settings**.

The default context folder is created on first launch at:

```text
~/Library/Application Support/AprilAI/context
```

You can choose another folder from the **Context** or **Settings** screen.

## Implemented

- SwiftUI macOS app with full window and menu bar surface.
- Gemini text/image/audio request client.
- Gemini speech generation using `gemini-3.1-flash-tts-preview` with the `Aoede` voice.
- Gemini Live WebSocket session using the saved Live model for lower-latency talk.
- Fast text model option `gemini-3.1-flash-lite` in Settings.
- Two-part assistant replies: a short spoken response and a full Markdown answer in chat.
- Read-only system prompt and action boundary.
- On-demand main-display screenshot capture.
- Push-to-talk style voice clip recording.
- Live mic streaming from the Talk button, with returned audio chunks played as they arrive.
- Live screen sharing sends low-resolution JPEG frames into the active Gemini Live session.
- Live sessions enable context-window compression and session resumption hints to reduce abrupt audio-video session termination.
- Local playback of Gemini-generated speech audio for short replies.
- Local `context/` folder structure:
  - `inbox/`
  - `memory/`
  - `research/`
  - `index/`
- PDF and text extraction from `context/inbox`.
- SQLite FTS5 local search index.
- Automatic local session memory saving, plus manual memory saving and delete controls.
- Research reports saved to `context/research`.

## Read-Only Boundary

The app does not expose tools for clicking, typing, deleting, sending, buying, scheduling, running shell commands, or operating other apps. It can recommend and draft, but it cannot act.

## Live Talk

The **Talk** button opens a persistent Gemini Live WebSocket session the first time you use it. Press **Talk** to stream mic audio; press **Stop** to pause the mic while keeping the Live session open. Use **Share screen** to stream screen frames into that same Live session. Use **Disconnect live** from the full chat view or **Close** from the menu bar popover when you want to close the socket.

The Live mic path keeps CoreAudio's realtime callback away from SwiftUI/MainActor state. If macOS has microphone permission enabled, the app should not close when starting the mic.

Gemini Live audio-video sessions can be shorter than audio-only sessions. April AI enables context-window compression, listens for Live session rotation signals, and retries transient screen-frame failures so screen sharing does not immediately kill the conversation.

## Memory

April AI automatically reviews recent chat/live turns, saves useful durable memories locally, embeds them when the Gemini API key is available, and refreshes Live memory context when Live is connected. It still avoids obvious secrets and high-sensitivity candidates. Delete bad memories from the **Memory** tab using the trash button.

## Current V1 Notes

- Live API support is implemented with raw WebSockets and PCM audio streaming.
- Speech output uses Gemini speech generation first, with macOS local speech only as a fallback if TTS fails.
- Deep Research is implemented as a grounded Gemini research prompt with optional Google Search grounding and saved Markdown output.
- Screen capture is on-demand only.
- Exact copyrighted character impersonation and exact catchphrases are intentionally not used; the app uses an original brutal chaotic-scientist style.
