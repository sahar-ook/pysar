# Pysar

Pysar (PY-sar, писар: Ukrainian for "scribe") is a speech-to-text tool for macOS that handles Ukrainian and English in the same sentence. Speech streams to Gemini Transcribe Live on your own API key, so the text lands about 0.4 s after you stop talking and you pay per use, not a subscription. With no key or no network it falls back to a local Parakeet model, and then nothing leaves the Mac.

## Why I built it

I think and work in two languages at once: a Ukrainian sentence with "workflow", "pull request" and a product name in the middle. The dictation tools I tried pick one language per take, so half of every sentence came back wrong. Pysar is the tool I wanted: press a key, talk the way I actually talk, get clean text where the cursor is.

## What it does

- **Press, speak, press.** Right `⌘` starts a take, right `⌘` again ends it, and the text is pasted where the cursor was. `⌥⇧Space` does the same for long takes.
- **Words while you talk.** A small pill at the bottom of the screen shows a timer, a live level meter and the last words heard.
- **Formatting only when needed.** Long takes, lists and self-corrections ("on Tuesday, no, sorry, on Friday") go through a formatter that adds paragraphs and lists and never rewords. Short clean takes are pasted as heard.
- **Dictionary.** Names and terms you add are spelled your way. Pysar also watches what you fix after a paste and suggests new entries.
- **Command Mode.** Select text, tap right `⌥`, say what to do with it ("shorten", "translate to English"), tap again.
- **Style per app.** Formal, casual or very casual capitals and punctuation for mail, work chats, personal chats and AI assistants. Words never change.
- **Snippets.** Say a cue ("my email") and a saved text is pasted instead.
- **Undo formatting.** `⌥⇧Z` puts back the raw transcript.
- **History and usage.** Every take for the last 15 days, searchable, with replay; words per minute, fixes made and a day streak.

## How it works

```
right ⌘ down
   │
   ▼
sox records a WAV (16 kHz mono)
   │   while you speak: a local daemon tails the file and streams it
   │   to Gemini Transcribe Live; partial text shows in the pill
   ▼
right ⌘ again: final text about 0.4 s later
   │   (error, silence or 3 s without an answer → Parakeet v3 on the Mac;
   │    Parakeet fails → WhisperKit on the Mac)
   ▼
Gemini Flash-Lite formats the text, only when the take needs it
   ▼
pasted at the cursor; a line goes to the local takes journal
```

The pieces: a Hammerspoon module in Lua (`hammerspoon/pysar.lua`) for keys, the pill, windows and pasting; a standard-library Python daemon (`server/live_server.py`) that proxies audio to the Live API; a Parakeet server on MLX (`server/parakeet_server.py`); and three launchd agents that keep them running.

## What leaves your Mac

| Mode | What is sent | Where |
|---|---|---|
| Live stream (default with a key) | The audio of the take, up to 100 dictionary terms, the language codes | Google Gemini API |
| Formatter (only on takes that need it) | The transcript, your dictionary, the app name, the window title, the text around the cursor, the selected text, and up to 40 names visible in the focused window | Google Gemini API |
| Command Mode | The selected text and your spoken instruction | Google Gemini API |
| No key, or no network | Nothing | Nowhere |

Things worth knowing before you use it for anything sensitive:

- Pysar has no server of its own. Requests go from your Mac to Google with your key.
- On Google's free tier, Google may use what you send to improve its products, and people may read it. On a paid key it does not. This is Google's policy, not a Pysar setting: see the [Gemini API terms](https://ai.google.dev/gemini-api/terms).
- Screen context is text only, never a screenshot. Password fields are never read, and 1Password, Keychain Access and Passwords are skipped entirely. Turn it off with `screenContext = false`.
- Everything Pysar keeps is in `~/.pysar`: transcripts for 15 days, audio of delivered takes for 7 days, a takes journal with timings (no expiry), logs, and the last formatter request (`request.json`, overwritten by the next one).

## Measured

All numbers are from my own voice on an M-series MacBook. "Words wrong" is word error rate against the sentence I read: case and punctuation ignored.

| What | Result | How it was measured |
|---|---|---|
| Live stream, accuracy | 10.5% of words wrong | 20 read-aloud takes replayed through `bench/transcribe_live.py`, October 2026 |
| Live stream, speed | Final text 0.36 s (median) after the end of speech | Same 20 takes |
| Local Parakeet + WhisperKit together, the setup before the stream | 21.5% of words wrong, 3 to 3.6 s | Same 20 sentences, dictated live |
| A week of daily use | 99% of takes served by the stream; 0.41 s median from key release to text, 0.65 s at the 90th percentile | The takes journal, about a thousand takes |
| Offline fallback alone, no formatter | 43.2% of words wrong, 0.2 to 0.4 s | The 20 sentences in `bench/reference2.txt`, dictated live, November 2026 |

What these numbers do not show:

- The 10.5% is a replay of recorded takes, not a live round. A live round on the stream has not been repeated since the switch.
- The October numbers were taken on a private set of 20 sentences of the same shape as `bench/reference2.txt`. The sentences in this repo are invented replacements; only the offline row was measured on them.
- One speaker, one microphone, one accent.
- The offline fallback is rough on mixed speech: English terms come out in Cyrillic and some Ukrainian comes out as Russian. It keeps you working without a network; it is not the product.

## Cost

About $0.27 for 30 minutes of speech on a paid Gemini key (Google's list price for `gemini-3.5-transcribe-live`, November 2026), free on the free tier. The formatter adds a fraction of a cent per formatted take. The local models cost nothing to run.

## Install

You need Apple Silicon, macOS 14 or later, Homebrew and about 4 GB of disk for the models. A Gemini API key from [aistudio.google.com](https://aistudio.google.com) is optional: without it Pysar runs on the local model only.

```bash
git clone https://github.com/sahar-ook/pysar.git ~/Dev/pysar
cd ~/Dev/pysar && ./install.sh
```

The installer adds `whisperkit-cli`, `sox`, `ffmpeg`, `uv` and Hammerspoon, downloads two models (Parakeet v3 and WhisperKit large-v3, about 600 MB each), starts three background services and asks for the key. Then, by hand:

1. System Settings → Privacy & Security → Accessibility → Hammerspoon
2. System Settings → Privacy & Security → Microphone → Hammerspoon
3. Menu bar icon → Reload

To check it: open Notes, click into the text, press right `⌘`, say a sentence, press again.

The installer has been run end to end on one machine. If something fails, `~/.pysar/pysar.log` and `~/.pysar/live.log` say why. To store or change the key later, run `./set-gemini-key.sh`.

## Configuration

Settings live in the call in `~/.hammerspoon/init.lua`:

```lua
require("pysar").start({
  holdKey    = 54,       -- right ⌘; 61 right ⌥, 60 right ⇧, 62 right ⌃
  language   = nil,      -- "uk" or "en" to pin the language
  theme      = "paper",  -- or "ink"
  screenContext  = true, -- names from the focused window for the formatter
  transcriptDays = 15,
  audioDays      = 7,    -- 0 keeps no audio
})
```

The dictionary is a plain text file, one term per line, edited from the menu bar. `dictionary.example.txt` is a starting point.

## Repository layout

- `hammerspoon/` the app: `pysar.lua`, and `learn.lua` for dictionary suggestions, with its tests
- `server/` the Live API daemon, the Parakeet server and their tests
- `launchd/` the three service definitions
- `prompt.md` the formatter's instructions
- `bench/` the scripts and reference sentences behind the numbers above

## Uninstall

```bash
./uninstall.sh
```

This stops the services and removes the Hammerspoon module. Recordings, logs and the key stay in `~/.pysar` until you delete that folder.

## Licence

MIT. The speech models and tools Pysar installs (Parakeet, WhisperKit, Hammerspoon, sox, ffmpeg) keep their own licences.
