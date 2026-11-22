--- Pysar — dictation for macOS.
--- Press a key to record, press it again to stop; streams the take to Gemini
--- Transcribe Live while you speak (Parakeet locally as the fallback), formats
--- when needed, pastes into the focused app.

local M = {}

M.config = {
  -- Press once to start recording, press again to stop and transcribe. No
  -- holding. The right Command key does nothing on its own anywhere in macOS,
  -- needs no remapping, and sits under the right thumb. It acts on release, so
  -- a chord (⌘C, ⌘V…) pressed while a take is running neither starts nor stops
  -- anything - the shortcut just goes through.
  holdKey = 54,   -- right cmd. 61 right alt, 60 right shift, 62 right ctrl

  -- F5 on this machine is swallowed by the system before Hammerspoon sees it.
  -- Left here for keyboards where it does arrive; M.probe() shows which.
  micKey      = false,
  micKeyNames = { DICTATION = true, MICROPHONE = true, VOICE_COMMAND = true },
  -- Press once to start, once more to stop. For long dictation.
  toggle     = { mods = { "alt", "shift" }, key = "space" },
  -- Swap the last pasted take for its raw transcript, before formatting.
  undoKey    = { mods = { "alt", "shift" }, key = "z" },
  -- Command Mode: select text, tap the right Option key alone, say what to do
  -- with it ("скороти", "переклади англійською"), tap again. 61 = right ⌥.
  commandKey = 61,

  -- Gemini 3.5 Transcribe Live, streamed while the key is held through the
  -- local daemon server/live_server.py (launchd com.pysar.live). On the 20
  -- read-aloud takes (bench/transcribe_live.py, 2026-10-20): 10.5% of words
  -- wrong and the final text 0.36 s (median) after the end of speech, against
  -- 2.6 s for the file model and 21.5% in 3-3.6 s for Parakeet + WhisperKit.
  -- Any error, timeout or empty answer sends the take to `server` below.
  live = {
    enabled   = true,
    server    = "http://127.0.0.1:50063",
    stopTimeout = 3.0,   -- s after release before falling back to Parakeet
    partialEvery = 0.4,  -- s, pill refresh from /partial
  },
  -- When the live stream is off or fails, the take goes to Parakeet.
  -- Parakeet v3 on 50062: 0.2-0.7s a take, and the better Ukrainian. WhisperKit
  -- was the default for an hour on 2026-10-20 and turned Ukrainian into Russian
  -- («скажу тебе ... серверы и MD-файлы») at ~2s a take; Parakeet's weak spot,
  -- English terms («Мспі», «сіпі»), is the formatter's job.
  server   = "http://127.0.0.1:50062/v1/audio/transcriptions",
  serverEngine = "parakeet",
  -- Second opinion: a take the main engine could not answer, or answered with
  -- runaway text, goes here instead.
  fallbackServer = "http://127.0.0.1:50060/v1/audio/transcriptions",
  fallbackEngine = "whisperkit",
  -- Both recognisers on every take (2026-10-20) gave 21.5% of words wrong in
  -- 3-3.6 s on the read-aloud test; the live stream gives 10.5% in 0.4 s. The
  -- second opinion is removed; WhisperKit only rescues a failed Parakeet take.
  ensemble = false,
  -- The words in the pill while speaking, when the live stream is not running
  -- (it has its own, see live.partialEvery). Parakeet answers in 0.2-0.3s, so
  -- the preview keeps up; the final text still comes from `server`.
  previewServer = "http://127.0.0.1:50062/v1/audio/transcriptions",
  language = nil,   -- nil = detect. Russian is never right here; see retryLang.
  retryLang = "uk", -- what to force when detection comes back Russian

  maxSeconds = 300,
  minSeconds = 0.35,

  sox  = "/opt/homebrew/bin/sox",
  curl = "/usr/bin/curl",

  -- Context from the screen for the formatter, gathered while you speak: the
  -- window title and names visible in the focused window. Text only, no
  -- screenshots; password fields are never
  -- read, and these apps are skipped whole.
  screenContext     = true,
  screenContextSkip = { ["1Password"] = true, ["Keychain Access"] = true, ["Passwords"] = true },

  -- Transcripts older than this are deleted at launch and after every take.
  -- The folder holds everything ever dictated, so this is about what lingers
  -- on disk, not about space: a busy day is about 7 KB.
  transcriptDays = 15,
  -- Audio of every delivered take, in audio/, to replay against another engine.
  -- About 0.5 MB a minute of speech. 0 turns it off.
  audioDays = 7,

  -- When no text field has focus, offer the transcript in a window instead of
  -- pasting it somewhere unintended.
  fallbackWindow   = true,

  -- Structuring pass. GLM 4.7 on z.ai breaks a long take into paragraphs and
  -- lists and fixes punctuation (prompt.md). It is told not to reword
  -- anything, so the transcript stays yours.
  --
  -- Gemini 3.5 Flash-Lite since 2026-10-20: on 53 real takes, median 0.94s
  -- and p90 1.2s against z.ai's 5.5s, and it kept product names and first
  -- names that z.ai rewrote. Back to z.ai:
  --   endpoint "https://api.z.ai/api/paas/v4/chat/completions", model "glm-4.7",
  --   keyFile ~/.pysar/api-key, extra { thinking = { type = "disabled" } },
  --   minWords 25, timeout 15, keepWarm true.
  llm = {
    enabled     = true,
    endpoint    = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
    model       = "gemini-3.5-flash-lite",
    keyFile     = os.getenv("HOME") .. "/.pysar/gemini-key",
    -- A key from an AI Studio project without billing goes first (2026-10-27);
    -- keyFile, the paid one, only when Google refuses it (HTTP 429, or 400/401/
    -- 403 about the key), and then until the next midnight Pacific, when the
    -- daily quotas reset, or until this file changes. No file: keyFile alone.
    freeKeyFile = os.getenv("HOME") .. "/.pysar/gemini-key-free",
    promptFile  = os.getenv("HOME") .. "/.pysar/prompt.md",
    temperature = 0.1,
    -- Merged into every request body, provider-specific. Gemini 3 cannot turn
    -- reasoning off, "minimal" is the floor. GLM wants { thinking = { type =
    -- "disabled" } }. Ollama needs {think=false} for Qwen3 and keep_alive.
    extra       = { reasoning_effort = "minimal" },
    -- When the formatter runs. Transcribe Live punctuates and spells the
    -- dictionary's terms itself, so in "needed" a live take goes in as heard
    -- unless the app's style is not Formal, it has longWords or more (where
    -- paragraphs and lists are likely), or it carries a list cue (LIST_CUES)
    -- or a self-correction or filler (FIX_CUES). Text from Parakeet is always
    -- formatted: the dictionary and the English terms are the formatter's job
    -- there. The reason lands in takes.jsonl as llm.reason. "always" formats
    -- every take of minWords or more, as every take was before 2026-10-20.
    mode        = "needed",  -- "always" | "needed" | "never"
    longWords   = 40,
    -- "always" only: shorter takes go in as heard. 0 formats every take.
    minWords    = 0,
    -- p90 was 1.2s and the slowest 4.5s; past this the raw text goes in and
    -- takes.jsonl records "formatter timeout".
    timeout     = 4,
    -- A hosted model is always loaded; a warm-up call would only spend quota.
    keepWarm    = false,
  },
  -- Pill colours: "paper" - white fill, black edge and text - or "ink", the
  -- same inverted. Black and white only; state is told by shape, not colour.
  theme = "paper",

  -- Show words while they are still being spoken. Costs a transcription pass
  -- every few seconds; the result is thrown away, only the final one counts.
  livePreview      = true,    -- words appear in the pill while you speak
  previewEvery     = 2,

  -- Join the sentence already under the caret rather than butting against it.
  smartSpacing     = true,
  restoreClipboard = true,
  showLanguage     = true,
  sound            = true,
}

local RUN_DIR  = os.getenv("HOME") .. "/.pysar"

--- Never print() from the tool: Hammerspoon routes print through hs.ipc, and
--- with a stale CLI port around it throws, taking the caller down with it.
local function logLine(line)
  local f = io.open(RUN_DIR .. "/pysar.log", "a")
  if f then f:write(os.date("%H:%M:%S "), line, "\n"); f:close() end
end
local LOG_DIR  = RUN_DIR .. "/transcripts"
local TAKES    = RUN_DIR .. "/takes.jsonl"
local FAILED   = RUN_DIR .. "/failed"
local AUDIO    = RUN_DIR .. "/audio"
local DICT     = RUN_DIR .. "/dictionary.txt"
local PEEK_WAV = RUN_DIR .. "/peek.wav"
local WAV      = RUN_DIR .. "/take.wav"   -- tests only; a take records into its own file
-- Each take records into take-1..4.wav in turn, so the next take can start
-- while the last one is still being transcribed and formatted.
local wavOf = setmetatable({}, { __mode = "k" })
local inFlight = setmetatable({}, { __mode = "k" })   -- takes past the key, not yet journaled
local SUGG     = RUN_DIR .. "/suggestions.json"
local SNIPS    = RUN_DIR .. "/snippets.json"
local STYLES   = RUN_DIR .. "/styles.json"

-- Style per kind of app: it changes capitals and punctuation
-- only, never words. Formal is what Pysar always did.
local STYLE_KINDS = {
  { id = "email",    label = "Email",             apps = "Mail, Outlook, Gmail, Spark, Superhuman" },
  { id = "work",     label = "Work messages",     apps = "Slack, Teams, Linear, Jira, Zoom" },
  { id = "personal", label = "Personal messages", apps = "Telegram, WhatsApp, Messages, Signal, Viber, Instagram" },
  { id = "ai",       label = "AI assistants",     apps = "Claude, ChatGPT, Perplexity, Gemini, Copilot" },
  { id = "other",    label = "Everything else",   apps = "documents, notes, browser, anything not above" },
}
local STYLE_LEVELS = { "formal", "casual", "very casual" }
local STYLE_RULES = {
  casual = "casual - normal capitals and commas; the message does not end with a full stop. "
        .. "A question mark or an exclamation mark at the end stays",
  ["very casual"] = "very casual - lower-case start of the message and of sentences, commas kept, "
                 .. "the message does not end with a full stop (a question or exclamation mark stays); "
                 .. "names, terms and \"I\" keep their capitals",
}
local KIND_OF_APP = {
  Mail = "email", Outlook = "email", ["Microsoft Outlook"] = "email", Superhuman = "email",
  Spark = "email", ["Spark Desktop"] = "email", Airmail = "email", Mimestream = "email",
  Slack = "work", ["Microsoft Teams"] = "work", Teams = "work", Linear = "work", ["zoom.us"] = "work",
  Telegram = "personal", WhatsApp = "personal", Messages = "personal", Signal = "personal",
  Viber = "personal", Messenger = "personal", Instagram = "personal", Discord = "personal",
  Claude = "ai", ChatGPT = "ai", Perplexity = "ai", ["Microsoft Copilot"] = "ai", Copilot = "ai",
}
-- In a browser the app says nothing; the page title does.
local KIND_OF_TITLE = {
  { "Gmail", "email" }, { "Outlook", "email" },
  { "Slack", "work" }, { "Linear", "work" }, { "Jira", "work" },
  { "Telegram", "personal" }, { "WhatsApp", "personal" }, { "Instagram", "personal" },
  { "ChatGPT", "ai" }, { "Claude", "ai" }, { "Perplexity", "ai" }, { "Gemini", "ai" }, { "Copilot", "ai" },
}

local function loadStyles()
  local f = io.open(STYLES, "r")
  local data = f and f:read("a"); if f then f:close() end
  if not data or data == "" then return {} end
  local ok, t = pcall(hs.json.decode, data)
  return (ok and type(t) == "table") and t or {}
end

local function saveStyles(t)
  local f = io.open(STYLES, "w")
  if f then f:write(hs.json.encode(t, true)); f:close() end
end

--- The style that applies to the app (and, in a browser, the page title).
local function styleFor(app, title)
  local kind = KIND_OF_APP[app or ""]
  if not kind and title then
    for _, pair in ipairs(KIND_OF_TITLE) do
      if title:find(pair[1], 1, true) then kind = pair[2]; break end
    end
  end
  return loadStyles()[kind or "other"] or "formal"
end

-- learn.lua sits next to this file in the repo; ~/.hammerspoon/pysar.lua is a
-- symlink, so resolve it before looking for the neighbour. Without the module
-- Pysar works as before, it just does not learn.
local LEARN = (function()
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  local real = hs.fs.pathToAbsolute(src) or src
  local ok, mod = pcall(dofile, real:match("^(.*/)") .. "learn.lua")
  if not ok then logLine("learn.lua not loaded: " .. tostring(mod)) end
  return ok and mod or nil
end)()

local state = {
  phase       = "idle",   -- idle | recording | transcribing
  capturing   = false,    -- sox has actually started delivering audio
  preview     = nil,      -- words heard so far, for display only
  peeking     = false,
  liveId      = nil,      -- the live daemon's id for the take being recorded
  recorder    = nil,
  startedAt   = nil,
  target      = nil,
  ticker      = nil,
  level       = 0,
  levelAt     = 0,        -- when sox last reported a level
  peak        = 0,        -- loudest recent sox reading, for auto-gain
  levelStats  = nil,      -- { n, sum, max } of the take's dBFS readings, for takes.jsonl
  take        = nil,      -- the takes.jsonl record being filled in
  hideTimer   = nil,
}

--------------------------------------------------------------------------------
-- Microphone
--------------------------------------------------------------------------------
-- Auto-detect takes the highest-ranked connected mic, or
-- one device is picked by name. The ranking is by device name, so a mic keeps
-- its place across reconnects; disconnected ones stay in the list, greyed,
-- until forgotten. Virtual inputs (BlackHole, Zoom, aggregates) are never
-- ranked or picked automatically, only chosen on purpose.
--
-- With the lid closed macOS keeps the MacBook microphone as the default input
-- and it records silence (measured 2026-10-20: RMS 0.000015 against 0.00068
-- from the Studio Display mic in the same room), so Auto-detect skips the
-- built-in mic while the lid is shut. A change applies from the next take.

local MIC_FILE = RUN_DIR .. "/microphone.json"

local function lidClosed()
  local out = hs.execute("/usr/sbin/ioreg -r -k AppleClamshellState -d 4")
  return out:match('"AppleClamshellState" = Yes') ~= nil
end

local function isVirtual(transport)
  return transport == "Virtual" or transport == "Aggregate"
end

local function inputDevices()
  local list = {}
  for _, d in ipairs(hs.audiodevice.allInputDevices()) do
    local transport = tostring(d:transportType() or "")
    list[#list + 1] = { name = d:name(), transport = transport, virtual = isVirtual(transport) }
  end
  return list
end

-- New mics join at the bottom: built-in first, then wired, then Bluetooth
-- and the iPhone, which are slow to start and lose the first words.
local function transportRank(transport)
  if transport == "Built-in" then return 1 end
  if transport == "Bluetooth" or transport == "BluetoothLE" then return 3 end
  if transport == "UNKNOWN" then return 4 end   -- Continuity (iPhone) mics
  return 2
end

local function loadMic()
  local mic
  local file = io.open(MIC_FILE, "r")
  if file then
    local ok, data = pcall(hs.json.decode, file:read("*a"))
    file:close()
    if ok and type(data) == "table" then mic = data end
  end
  mic = mic or {}
  mic.choice  = mic.choice or "auto"
  mic.ranking = mic.ranking or {}
  return mic
end

local function saveMic(mic)
  local file = io.open(MIC_FILE, "w")
  if not file then return false end
  file:write(hs.json.encode(mic, true)); file:close()
  return true
end

--- Adds any physical mic seen for the first time to the bottom of the ranking.
local function syncRanking(mic, devices)
  local known, fresh = {}, {}
  for _, name in ipairs(mic.ranking) do known[name] = true end
  for _, d in ipairs(devices) do
    if not d.virtual and not known[d.name] then
      fresh[#fresh + 1] = d; known[d.name] = true
    end
  end
  if #fresh == 0 then return false end
  table.sort(fresh, function(a, b) return transportRank(a.transport) < transportRank(b.transport) end)
  for _, d in ipairs(fresh) do mic.ranking[#mic.ranking + 1] = d.name end
  saveMic(mic)
  return true
end

--- The device sox should open, and a word on why. Falls back to the system
--- default only when nothing in the list is connected.
local function resolveMic()
  local mic, devices = loadMic(), inputDevices()
  syncRanking(mic, devices)
  local byName = {}
  for _, d in ipairs(devices) do byName[d.name] = d end

  local shut = lidClosed()
  if mic.choice ~= "auto" then
    if byName[mic.choice] then return mic.choice, "chosen", shut end
    logLine("microphone: " .. mic.choice .. " is not connected, using auto-detect")
  end

  for _, name in ipairs(mic.ranking) do
    local d = byName[name]
    if d and not (shut and d.transport == "Built-in") then return name, "auto", shut end
  end
  return "default", "system default", shut
end

--------------------------------------------------------------------------------
-- Overlay
--------------------------------------------------------------------------------
-- A single pill, bottom-centre. While recording it is a timer, a scrolling
-- waveform and a cancel button and nothing else; in every other phase the
-- waveform and the button step aside for a status dot and a line of text.
-- Same public surface as before - show(), showBars(), setBars(), overlay(),
-- ui.canvas, IDX.dot, IDX.status, COL.* - so nothing outside this section
-- has to know the design changed.

local ui = { canvas = nil }

-- Two colours, ink #111111 and paper #ffffff, in two arrangements; pick with
-- config.theme. Both keep an outline so the pill reads on any background.
local function hex(h, alpha)
  return { red = tonumber(h:sub(1, 2), 16) / 255, green = tonumber(h:sub(3, 4), 16) / 255,
           blue = tonumber(h:sub(5, 6), 16) / 255, alpha = alpha or 1 }
end
local THEMES = {
  ["paper"] = { paper = "ffffff", ink = "111111", edge = { "111111", 1.0 } },
  ["ink"]   = { paper = "111111", ink = "ffffff", edge = { "ffffff", 0.35 } },
}
local COL = {}
local function applyTheme(name)
  local t = THEMES[name] or THEMES["paper"]
  COL.paper  = hex(t.paper)
  COL.ink    = hex(t.ink)
  COL.status = hex(t.ink, 0.75)
  COL.edge   = hex(t.edge[1], t.edge[2])
  -- State dots are all ink; show() tells them apart by shape: a ring while
  -- busy, a solid dot when done, a solid dot and a "!" before the text on an
  -- error. Separate tables, because show() compares them by identity.
  COL.rec  = hex(t.ink)
  COL.busy = hex(t.ink)
  COL.ok   = hex(t.ink)
  COL.err  = hex(t.ink)
end
applyTheme("paper")

local W, H   = 420, 56
local WAVE   = 12          -- bars in the meter
local BAR_W, BAR_GAP = 4, 4
local WAVE_W = WAVE * (BAR_W + BAR_GAP) - BAR_GAP
local WAVE_X = 92                                    -- meter sits left of the words
local IDX = { bg = 1, dot = 2, status = 3, cancelBg = 4, cancelX = 5, bars = 6, preview = 6 + WAVE,
              doneBg = 7 + WAVE, doneMark = 8 + WAVE }
local PREVIEW_X = WAVE_X + WAVE_W + 14
local PREVIEW_W = (W - 26 - 22 - 28) - PREVIEW_X   -- leaves room for ✓ and ×

-- The meter pulses in place rather than scrolling, but not as one block:
-- every bar has its own weight, its own attack/decay and its own slow
-- wobble, fixed once from a golden-ratio sequence so the pattern is stable
-- run to run. All bars are driven by the same live level; the spread comes
-- from how each one answers it. The wobble is scaled by the level, so a
-- silent room stays flat and speech makes the bars dance rather than march.
local bar = {}
for i = 1, WAVE do
  local g = (i * 0.6180339887) % 1
  bar[i] = {
    weight = 0.55 + 0.45 * g,                 -- how tall it can get
    attack = 0.55 + 0.35 * ((g * 7) % 1),     -- how fast it follows a rise
    decay  = 0.62 + 0.18 * ((g * 13) % 1),    -- how quickly it lets go
    freq   = 9 + 9 * ((g * 3) % 1),           -- wobble, rad/s
    phase  = g * 6.2831853,
    value  = 0,
  }
end
local BAR_MIN, BAR_MAX = 4, 36                -- bar height in px, silent → full

local function buildCanvas()
  local screen = hs.screen.mainScreen():frame()
  local c = hs.canvas.new({
    x = screen.x + (screen.w - W) / 2,
    y = screen.y + screen.h - H - 110,
    w = W, h = H,
  })

  c:appendElements({
    type = "rectangle", action = "strokeAndFill",
    fillColor = COL.paper, strokeColor = COL.edge, strokeWidth = 2,
    roundedRectRadii = { xRadius = 12, yRadius = 12 },   -- same corner as the cards
    frame = { x = 1, y = 1, w = W - 2, h = H - 2 },
  }, {
    type = "circle", action = "fill", fillColor = COL.busy,
    strokeColor = COL.ink, strokeWidth = 2,
    center = { x = 22, y = H / 2 }, radius = 5,
  }, {
    type = "text", text = "",
    textFont = "Menlo", textSize = 13, textColor = COL.ink,
    frame = { x = 34, y = 18, w = W - 60, h = 20 },
  }, {
    -- cancel button: an outlined disc with an ink ×; only shown while recording
    type = "circle", action = "strokeAndFill", fillColor = COL.paper,
    strokeColor = COL.ink, strokeWidth = 1.5,
    center = { x = W - 26, y = H / 2 }, radius = 10.5,
    id = "cancel", trackMouseUp = true,
  }, {
    type = "text", text = "×",
    textFont = ".AppleSystemUIFont", textSize = 16, textColor = COL.ink,
    textAlignment = "center",
    frame = { x = W - 37, y = H / 2 - 11, w = 22, h = 22 },
    id = "cancel", trackMouseUp = true,
  })

  for i = 1, WAVE do
    c:appendElements({
      type = "rectangle", action = "fill", fillColor = COL.ink,
      roundedRectRadii = { xRadius = 2, yRadius = 2 },
      frame = { x = WAVE_X + (i - 1) * (BAR_W + BAR_GAP), y = H / 2 - 3, w = BAR_W, h = 6 },
    })
  end

  -- last words heard so far; filled by the ticker while recording
  c:appendElements({
    type = "text", text = "", action = "skip",
    textFont = ".AppleSystemUIFont", textSize = 12, textColor = COL.status,
    textLineBreak = "truncateHead",
    frame = { x = PREVIEW_X, y = 19, w = PREVIEW_W, h = 20 },
  })

  -- done button, left of ×: ends the take and transcribes it, same as a second
  -- press of the key. A solid disc, where × is an outlined one.
  c:appendElements({
    type = "circle", action = "skip", fillColor = COL.ok,
    center = { x = W - 54, y = H / 2 }, radius = 11,
    id = "done", trackMouseUp = true,
  }, {
    type = "text", text = "✓", action = "skip",
    textFont = ".AppleSystemUIFont", textSize = 14, textColor = COL.paper,
    textAlignment = "center",
    frame = { x = W - 65, y = H / 2 - 10, w = 22, h = 22 },
    id = "done", trackMouseUp = true,
  })

  c:level(hs.canvas.windowLevels.overlay)
  c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces
           | hs.canvas.windowBehaviors.stationary)
  c:clickActivating(false)   -- a click on the pill must not steal the caret
  c:mouseCallback(function(_, message, id)
    if message == "mouseUp" and id == "cancel" then M.dismiss() end
    if message == "mouseUp" and id == "done" and M.finish then M.finish() end
  end)
  return c
end

local function overlay()
  if not ui.canvas then ui.canvas = buildCanvas() end
  return ui.canvas
end

--- Feeds one level into the meter and redraws it.
local function setBars(level)
  local c = overlay()
  level = math.max(0, math.min(level or 0, 1))
  local now = hs.timer.secondsSinceEpoch()
  for i = 1, WAVE do
    local b = bar[i]
    -- A slow sine per bar plus a little noise each frame: the sine keeps
    -- neighbours out of step, the noise keeps a held vowel from freezing.
    local wobble = 0.65 + 0.35 * math.sin(now * b.freq + b.phase)
    local target = level * b.weight * wobble * (0.85 + 0.3 * math.random())
    b.value = target > b.value and (b.value + (target - b.value) * b.attack) or (b.value * b.decay)
    local h = BAR_MIN + b.value * (BAR_MAX - BAR_MIN)
    local e = c[IDX.bars + i - 1]
    e.fillColor = COL.ink
    e.frame = { x = WAVE_X + (i - 1) * (BAR_W + BAR_GAP), y = H / 2 - h / 2, w = BAR_W, h = h }
  end
end

--- Recording layout on/off. On: timer at the left edge, waveform, cancel
--- button. Off: status dot plus a line of text, waveform dimmed, no button.
local function showBars(on)
  local c = overlay()
  -- Off-state hides the trace outright: a dimmed one sat under the status
  -- text and read as noise.
  for i = 1, WAVE do
    local e = c[IDX.bars + i - 1]
    e.action = on and "fill" or "skip"
    e.fillColor = COL.ink
    e.frame = { x = WAVE_X + (i - 1) * (BAR_W + BAR_GAP), y = H / 2 - BAR_MIN / 2, w = BAR_W, h = BAR_MIN }
    if on then bar[i].value = 0 end
  end
  c[IDX.cancelBg].action = on and "strokeAndFill" or "skip"
  c[IDX.cancelX].action  = on and "fill" or "skip"
  c[IDX.doneBg].action   = on and "fill" or "skip"
  c[IDX.doneMark].action = on and "fill" or "skip"
  c[IDX.preview].action  = on and "fill" or "skip"
  c[IDX.preview].text    = ""
  c[IDX.preview].textColor = COL.status
  c[IDX.dot].action      = on and "skip" or (state.dotRing and "stroke" or "fill")
  local f = c[IDX.status].frame
  c[IDX.status].frame = { x = on and 20 or 34, y = f.y, w = on and 60 or (W - 60), h = f.h }
  c[IDX.status].textFont = on and "Menlo" or ".AppleSystemUIFont"
  c[IDX.status].textColor = on and COL.ink or COL.status
end

--- Nothing on screen may outlive the work it describes. Every path that shows
--- the panel arms this; whichever finishes first wins, and a stall still ends
--- with a clean screen rather than a pill the user cannot get rid of.
local function armWatchdog(seconds)
  if state.watchdog then state.watchdog:stop() end
  state.watchdog = hs.timer.doAfter(seconds or 45, function()
    -- A held key is not a stall. The recording ticker re-arms this every
    -- tick, so firing here means the pipeline really stopped moving; if a
    -- recorder is somehow still alive, end it instead of orphaning it -
    -- one was found 113 s into a take after this fired at 45 s and the key
    -- release was then ignored.
    if state.phase == "recording" and state.capturing then
      armWatchdog(seconds)
      return
    end
    if state.recorder then
      pcall(function() hs.execute("/bin/kill -INT " .. state.recorder:pid()) end)
      state.recorder = nil
    end
    if ui.canvas then ui.canvas:hide() end
    state.phase = "idle"
  end)
end

local function show(dotColor, status, force)
  -- While a newer take records, messages about an older one stay off its pill.
  if state.phase == "recording" and state.capturing and not force then return end
  armWatchdog(45)
  if M.refreshMenu then M.refreshMenu() end
  local c = overlay()
  local dot = c[IDX.dot]
  state.dotRing = (dotColor == COL.busy)
  if dot.action ~= "skip" then dot.action = state.dotRing and "stroke" or "fill" end
  dot.fillColor = dotColor
  dot.strokeColor = dotColor
  if dotColor == COL.err and status and status ~= "" then status = "! " .. status end
  c[IDX.status].text = status or ""
  c:show()
end

local function hideLater(delay)
  if state.hideTimer then state.hideTimer:stop() end
  state.hideTimer = hs.timer.doAfter(delay, function()
    if state.phase == "recording" then return end
    if ui.canvas then ui.canvas:hide() end
  end)
end

--------------------------------------------------------------------------------
-- Insertion
--------------------------------------------------------------------------------

local TEXT_ROLES = {
  AXTextField = true, AXTextArea = true, AXComboBox = true, AXSearchField = true,
}

--- Roles that can never take typed text. Anything else - including "no focused
--- element at all" - is treated as a place to paste. The asymmetry decides the
--- default: ⌘V into a button or into nothing does nothing, while a wrongly
--- withheld paste sends the take to a window the user then has to copy from.
local NON_TEXT_ROLES = {
  AXButton = true, AXCheckBox = true, AXRadioButton = true, AXMenuItem = true,
  AXMenu = true, AXMenuBar = true, AXPopUpButton = true, AXSlider = true,
  AXTabGroup = true, AXToolbar = true, AXImage = true, AXStaticText = true,
  AXLink = true, AXDisclosureTriangle = true, AXScrollBar = true,
}

--- Every accessibility query is an IPC round-trip into the target app. If that
--- app is busy - or is an Electron app rebuilding its tree - the default wait
--- is long enough to freeze Hammerspoon's main thread, and with it the hotkey
--- taps, which the user experiences as the whole machine hanging. Half a
--- second is plenty for a healthy app and short enough to be harmless.
local AX_TIMEOUT = 0.5

local function bounded(el)
  if el then pcall(function() el:setTimeout(AX_TIMEOUT) end) end
  return el
end

--- Electron and Chromium build their accessibility tree lazily: until an
--- assistive client switches it on, the whole window reports a dozen nodes
--- and no focused element - which is what Claude, Slack, Notion and every
--- browser looked like to us. AXManualAccessibility is Chromium's own switch
--- for exactly this and is cheap. AXEnhancedUserInterface is deliberately
--- NOT set: it made the Claude app rebuild its entire tree and froze it.
local function wakeAccessibility(app)
  local ok, el = pcall(hs.axuielement.applicationElement, app)
  if not ok or not el then return end
  bounded(el)
  pcall(function() el:setAttributeValue("AXManualAccessibility", true) end)
end

local function focusedElement()
  local ok, el = pcall(function()
    return bounded(hs.axuielement.systemWideElement()):attributeValue("AXFocusedUIElement")
  end)
  if ok and el then return bounded(el) end
  -- Chromium sometimes answers the app-level query when the system-wide one
  -- comes back empty.
  local app = hs.application.frontmostApplication()
  if not app then return nil end
  local ok2, appEl = pcall(hs.axuielement.applicationElement, app)
  if not ok2 or not appEl then return nil end
  local ok3, el2 = pcall(function() return bounded(appEl):attributeValue("AXFocusedUIElement") end)
  return ok3 and bounded(el2) or nil
end

--- Decides whether to paste. See NON_TEXT_ROLES for why the default is yes.
local function hasTextFocus()
  local app = hs.application.frontmostApplication()
  if app then wakeAccessibility(app) end

  local focused = focusedElement()
  if not focused then return true end

  local role = focused:attributeValue("AXRole")
  if TEXT_ROLES[role] then return true end
  if NON_TEXT_ROLES[role] then return false end

  -- Web content and editors report their own roles (AXWebArea, AXGroup). A
  -- settable value is the reliable tell; failing that, still lean to pasting.
  local settable = select(2, pcall(function()
    return focused:isAttributeSettable("AXValue")
  end))
  if settable == true then return true end
  -- AXGroup / AXWebArea with a read-only value is what Chromium reports when
  -- the caret is NOT in its editor (the real editor shows up as AXTextArea
  -- once the tree is awake). Pasting there drops the text on the floor.
  return false
end

--------------------------------------------------------------------------------
-- Joining a take onto text already in the field
--------------------------------------------------------------------------------

--- Text on either side of the caret in the focused field. nil when the field
--- will not say (many web editors, everything non-text). Read while the
--- user's window is still in front, before any of the slow work.
local function caretContext()
  local focused = focusedElement()
  if not focused then return nil end
  local okv, value = pcall(function() return focused:attributeValue("AXValue") end)
  local okr, range = pcall(function() return focused:attributeValue("AXSelectedTextRange") end)
  if not (okv and okr) or type(value) ~= "string" or type(range) ~= "table" then return nil end
  local caret = tonumber(range.location or range.loc)
  if not caret then return nil end
  local selLen = tonumber(range.length or range.len) or 0
  -- Accessibility counts characters, Lua counts bytes; a Cyrillic letter is
  -- two bytes, so the caret has to be converted before slicing.
  local okb, byteAt = pcall(utf8.offset, value, caret + 1)
  if not okb or not byteAt then return nil end
  local after, selected = value:sub(byteAt), nil
  if selLen > 0 then
    local okS, selEnd = pcall(utf8.offset, after, selLen + 1)
    if okS and selEnd then selected, after = after:sub(1, selEnd - 1), after:sub(selEnd) end
  end
  local before = value:sub(1, byteAt - 1)
  -- Electron editors (Claude's input box) report the caret a few characters
  -- short in multi-line text - one more per line - which split the field in
  -- the middle of a word: the formatter then "continued" «…Instit» with
  -- «titute» (6 of 20 read-aloud takes, 2026-10-20). Nobody dictates into the
  -- middle of a word, so a split there means the caret is really at the end.
  if not selected and before:match("[%w\128-\255]$") and after:match("^[%w\128-\255]") then
    logLine("caret looked mid-word, taking the end of the field")
    before, after = value, ""
  end
  return { before = before, after = after, selected = selected, el = focused }
end

--- Last `n` characters of a UTF-8 string.
local function tailChars(str, n)
  local ok, at = pcall(utf8.offset, str, -n)
  if not ok or not at then return str end
  return str:sub(at)
end

-- string.upper/lower only know ASCII; Ukrainian needs its own table.
local CYR_UP = { [0x491] = 0x490, [0x454] = 0x404, [0x456] = 0x406, [0x457] = 0x407 }
local CYR_LO = {}
for lo, up in pairs(CYR_UP) do CYR_LO[up] = lo end

local function upperCp(cp)
  if (cp >= 0x61 and cp <= 0x7A) or (cp >= 0x430 and cp <= 0x44F) then return cp - 0x20 end
  return CYR_UP[cp] or cp
end
local function lowerCp(cp)
  if (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x410 and cp <= 0x42F) then return cp + 0x20 end
  return CYR_LO[cp] or cp
end
local function isUpperCp(cp) return lowerCp(cp) ~= cp end

--- Applies `f` to the first letter of `text`.
local function mapFirst(text, f)
  local ok, cp = pcall(utf8.codepoint, text, 1)
  if not ok or not cp then return text end
  local new = f(cp)
  if new == cp then return text end
  return utf8.char(new) .. text:sub(utf8.offset(text, 2))
end

--- True when the first word must keep its capital even mid-sentence: an
--- acronym or CamelCase name (two capitals), "I", or a dictionary term.
local function keepsCapital(text)
  local word = text:match("^([^%s%p]+)") or ""
  if word == "I" then return true end
  local caps = 0
  for _, cp in utf8.codes(word) do
    if isUpperCp(cp) then caps = caps + 1 end
  end
  if caps >= 2 then return true end
  local file = io.open(DICT, "r")
  if not file then return false end
  for line in file:lines() do
    local term = line:gsub("^%s+", ""):gsub("%s+$", "")
    if term ~= "" and not term:match("^#") and (term == word or term:match("^" .. word:gsub("%p", "%%%0") .. "[%s%p]")) then
      file:close()
      return true
    end
  end
  file:close()
  return false
end

--- Makes a take read as a continuation of what is already in the field.
--- After a full stop or on a fresh line it starts a sentence; after a word or
--- a comma it carries the sentence on in lower case, with a space if the
--- field ends without one. The formatter is told the same context, but short
--- takes skip the formatter, so the joining has to work on its own too.
local function fitToCaret(text, ctx)
  ctx = ctx or caretContext()
  local before = ctx and (ctx.joinBefore or ctx.before)
  if not before or before == "" then return text end

  if before:match("^%s*$") or before:match("\n%s*$") then
    return mapFirst(text, upperCp)             -- fresh line: a new sentence
  end
  local last = before:match("(%S)%s*$")
  local sep = before:match("%s$") and "" or " "
  if last:match("[.!?]") then
    return sep .. mapFirst(text, upperCp)      -- after a sentence: a new one
  end
  if last:match("[%(%[«\"'/-]") then sep = "" end
  -- Mid-sentence: continue it. A leading paragraph or list from the
  -- formatter would break the line, so fold that back into a space.
  text = text:gsub("^%s*[-*•]%s+", ""):gsub("^%s+", "")
  if not keepsCapital(text) then text = mapFirst(text, lowerCp) end
  return sep .. text
end

local function paste(text, ctx, exact, target)
  local previous = M.config.restoreClipboard and hs.pasteboard.getContents() or nil
  state.pasted = (M.config.smartSpacing and not exact) and fitToCaret(text, ctx) or text
  hs.pasteboard.setContents(state.pasted)
  target = target or state.target
  if target then target:activate() end
  hs.timer.doAfter(0.05, function()
    hs.eventtap.keyStroke({ "cmd" }, 9, 0)   -- keycode 9 = V on every layout
    if previous then
      hs.timer.doAfter(0.45, function() hs.pasteboard.setContents(previous) end)
    end
  end)
end

--------------------------------------------------------------------------------
-- Fallback window
--------------------------------------------------------------------------------

local fallback = {}

local function escapeHTML(str)
  return (str:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function closeFallback()
  if fallback.view then fallback.view:delete(); fallback.view = nil end
end

--- Shown when nothing on screen can take the text. The transcript is already on
--- the clipboard by the time this appears; the button is there for when the
--- clipboard has moved on.
local function showFallbackWindow(text)
  closeFallback()

  local W_, H_ = 560, 290
  local frame = hs.screen.mainScreen():frame()
  local rect = {
    x = frame.x + (frame.w - W_) / 2,
    y = frame.y + frame.h - H_ - 58,
    w = W_, h = H_,
  }

  local controller = hs.webview.usercontent.new("pysar")
  controller:setCallback(function(message)
    if message.body == "copy" then
      hs.pasteboard.setContents(text)
    elseif message.body == "close" then
      closeFallback()
    end
  end)

  local html = [[
<meta charset="utf-8">
<style>
  * { box-sizing: border-box; margin: 0; }
  html, body { background: transparent; height: 100%; }
  body { font: 14px/1.55 -apple-system, BlinkMacSystemFont, "Inter", sans-serif; color: #111111;
    -webkit-user-select: none; user-select: none; }
  /* Same surfaces as the main window: warm grey ground, off-white card. */
  .panel { height: 100%; display: flex; flex-direction: column; background: #f5f5f5;
    border: 1.5px solid #111111; border-radius: 12px; padding: 14px 18px 16px; }
  header { display: flex; align-items: center; gap: 12px; margin-bottom: 10px; }
  .brand { font-weight: 600; font-size: 18px; line-height: 1; letter-spacing: -0.02em; }
  h1 { flex: 1; text-align: center; font-size: 12px; font-weight: 400; color: #737373; }
  .x { width: 22px; height: 22px; border: 0; border-radius: 50%; cursor: pointer;
    background: #e5e5e5; color: #111111; font-size: 13px; line-height: 1; }
  .x:hover { background: #d9d9d9; }
  .body { flex: 1; overflow-y: auto; background: #ffffff; border: 1px solid #e5e5e5; border-radius: 10px;
    padding: 12px 14px; font-size: 14px; white-space: pre-wrap; -webkit-user-select: text; user-select: text; }
  footer { display: flex; justify-content: flex-end; padding-top: 12px; }
  .copy { border: 0; border-radius: 10px; padding: 7px 20px; cursor: pointer;
    background: #111111; color: #ffffff; font-size: 13px; font-weight: 600; }
  .copy:hover { background: #444444; }
  .copy.done { background: #ebebeb; color: #111111; }
</style>
<div class="panel">
  <header>
    <span class="brand">Pysar;</span>
    <h1>Select a text field first, then dictate</h1>
    <button class="x" onclick="send('close')">&times;</button>
  </header>
  <div class="body">__TEXT__</div>
  <footer><button class="copy" id="c" onclick="copyIt()">Copy</button></footer>
</div>
<script>
  function send(m) { window.webkit.messageHandlers.pysar.postMessage(m); }
  function copyIt() {
    send('copy');
    var b = document.getElementById('c');
    b.textContent = 'Copied';
    b.classList.add('done');
  }
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') send('close');
    if (e.key === 'c' && e.metaKey) copyIt();
  });
</script>]]

  fallback.view = hs.webview.new(rect, {}, controller)
  fallback.view:windowStyle({ "borderless" })
  fallback.view:level(hs.drawing.windowLevels.floating)
  fallback.view:transparent(true)
  fallback.view:shadow(true)
  fallback.view:allowTextEntry(true)
  fallback.view:html((html:gsub("__TEXT__", escapeHTML(text))))
  fallback.view:show()
  fallback.view:hswindow():focus()
end

--------------------------------------------------------------------------------
-- Structuring pass
--------------------------------------------------------------------------------

--- The whole point of this prompt is the first rule. The speaker dictates and
--- expects their own words back; the model is here to add paragraphs and lists, not to
--- write anything.
local FALLBACK_PROMPT = [[
Format this dictated transcript. Do not reword anything: keep the speaker's own
words and word order. Add paragraphs, and bullet or numbered lists where the
speaker enumerates. Fix punctuation and capitalisation. Write English terms in
Latin script and Ukrainian words in Cyrillic, whichever language surrounds
them, and never translate. Return only the text.
]]

--- The real prompt lives in prompt.md so it can be tuned without editing code.
--- The constant above is only what we fall back to if that file goes missing.
local function formatPrompt()
  local file = io.open(M.config.llm.promptFile, "r")
  if not file then return FALLBACK_PROMPT end
  local text = file:read("*a")
  file:close()
  if not text or text:gsub("%s", "") == "" then return FALLBACK_PROMPT end
  return text
end

--- Names and jargon the recogniser has never heard. Whisper takes this as a
--- hint about the vocabulary to expect, which is the only way to stop it
--- turning a product name into three unrelated words - once that happens the sound
--- is gone and no amount of reformatting brings it back.
local function dictionaryList()
  local file = io.open(DICT, "r")
  if not file then return nil end
  local terms = {}
  for line in file:lines() do
    local term = line:gsub("^%s+", ""):gsub("%s+$", "")
    if term ~= "" and not term:match("^#") then terms[#terms + 1] = term end
  end
  file:close()
  if #terms == 0 then return nil end
  return terms
end

--- The same, comma-joined, for the formatter and Whisper's `prompt`. The live
--- stream takes the list itself as customVocabulary.
local function dictionary()
  local terms = dictionaryList()
  return terms and table.concat(terms, ", ") or nil
end

local function apiKey(path)
  local file = io.open(path or M.config.llm.keyFile, "r")
  if not file then return nil end
  local key = file:read("*l")
  file:close()
  if not key then return nil end
  key = key:gsub("%s+", "")
  return key ~= "" and key or nil
end

local function wordCount(str)
  local n = 0
  for _ in str:gmatch("%S+") do n = n + 1 end
  return n
end

-- A live take that says these still goes through the formatter (llm.mode
-- "needed"): a dictated list, or a correction and filler to take out. Lua
-- patterns, matched against the lower-cased take.
local LIST_CUES = { "по%-перше", "по%-друге", "^перше[,:]", "пункт %d", "%d+[%.%)] ", "далі[,:]", "наступне[,:]" }
local FIX_CUES  = { "ні, не ", "тобто", "точніше", "не так,", "вибач", "е%-е", "ем,", " ну, ", "ще раз" }

local function lowerText(str)
  local ok, out = pcall(function()
    local cps = {}
    for _, cp in utf8.codes(str) do cps[#cps + 1] = utf8.char(lowerCp(cp)) end
    return table.concat(cps)
  end)
  return ok and out or str:lower()
end

--- Why the take goes through the formatter, or nil when it goes in as heard.
local function formatReason(text, job)
  local cfg = M.config.llm
  local mode = cfg.mode or "needed"
  if mode == "never" then return nil end
  if mode == "always" then return wordCount(text) >= (cfg.minWords or 0) and "always" or nil end
  if not job.liveText then return "offline engine" end
  -- A casual style is applied locally (localStyle), not a reason to format:
  -- on the first live take (2026-10-20 18:13, Claude, casual) the formatter
  -- cost 0.9 s and put «. » in front of a perfect transcript.
  if wordCount(text) >= (cfg.longWords or 40) then return "long" end
  local low = lowerText(text)
  for _, cue in ipairs(LIST_CUES) do if low:find(cue) then return "list cue" end end
  for _, cue in ipairs(FIX_CUES) do if low:find(cue) then return "fix cue" end end
  return nil
end

--- What STYLE_RULES ask of the formatter, done locally on a take that skipped
--- it: casual drops the final full stop; very casual also lower-cases the
--- start of the message and of every sentence. Terms and names are left to
--- the recogniser's spelling.
local function localStyle(text, style)
  if style ~= "casual" and style ~= "very casual" then return text end
  if not text:find("\n") then text = text:gsub("%.%s*$", "") end
  if style == "very casual" then
    text = mapFirst(text, lowerCp)
    text = text:gsub("([%.!?]%s+)(\240[\128-\191]*)", function(sep, ch)
      local ok, cp = pcall(utf8.codepoint, ch)
      return sep .. (ok and cp and utf8.char(lowerCp(cp)) or ch)
    end)
    text = text:gsub("([%.!?]%s+)(%u)", function(sep, ch) return sep .. ch:lower() end)
  end
  return text
end

--- Calls the formatter and hands the formatted text to `done`. Every failure path
--- falls back to the raw transcript with a reason - dictation must not be lost
--- because the network was unhappy.
--- Fired when recording starts. By the time there is a transcript to format,
--- the model is already loaded and answers in seconds rather than a minute.
local function warmFormatter()
  if not (M.config.llm.enabled and M.config.llm.keepWarm) then return end
  local key = apiKey()
  if not key and M.config.llm.endpoint:match("^https://") then return end

  local bodyPath = RUN_DIR .. "/warm.json"
  local rcPath   = RUN_DIR .. "/warm.curlrc"
  local body = io.open(bodyPath, "w")
  local warm = {
    model = M.config.llm.model,
    max_tokens = 1,
    messages = { { role = "user", content = "ok" } },
  }
  for k, v in pairs(M.config.llm.extra or {}) do warm[k] = v end
  body:write(hs.json.encode(warm))
  body:close()
  local rc = io.open(rcPath, "w")
  if key then rc:write('header = "Authorization: Bearer ' .. key .. '"\n') end
  rc:close()

  hs.task.new(M.config.curl, function() os.remove(rcPath) end, {
    "-s", "-o", "/dev/null", "--max-time", "60",
    "-K", rcPath, "-H", "content-type: application/json",
    "-d", "@" .. bodyPath, M.config.llm.endpoint,
  }):start()
end

--- The formatter is told where the text is going and which words are proper
--- nouns here. Both change the answer: a Slack message wants different shape
--- from a document, and a term list stops it "correcting" a real name.
local function context(caret, job)
  local lines = {}
  local target = job and job.target or state.target
  local app = target and target:name()
  if app then lines[#lines + 1] = "Target application: " .. app end
  local scr
  if job then scr = job.screen else scr = state.screen end
  if scr and scr.title and scr.title ~= "" then lines[#lines + 1] = "Window title: " .. scr.title end
  local style = styleFor(app, scr and scr.title)
  if STYLE_RULES[style] then lines[#lines + 1] = "Style: " .. STYLE_RULES[style] end
  local terms = dictionary()
  if terms then lines[#lines + 1] = "Known names and terms: " .. terms end
  if scr and scr.names and #scr.names > 0 then
    lines[#lines + 1] = "Names and terms visible on screen (spelling hints only): "
                        .. table.concat(scr.names, ", ")
  end
  local quoted = caret and (caret.joinBefore or caret.before)
  if quoted and not quoted:match("^%s*$") then
    lines[#lines + 1] = "Text already in the field, ending at the caret (continue it, do not repeat it):\n«"
                        .. tailChars(quoted, 400) .. "»"
  end
  if caret and caret.selected and not caret.selected:match("^%s*$") then
    local sel = caret.selected
    if utf8.len(sel) and utf8.len(sel) > 300 then sel = sel:sub(1, utf8.offset(sel, 301) - 1) .. "…" end
    lines[#lines + 1] = "Selected text, which the dictation replaces:\n«" .. sel .. "»"
  end
  if caret and caret.after and not caret.after:match("^%s*$") then
    local nxt = caret.after
    if utf8.len(nxt) and utf8.len(nxt) > 200 then nxt = nxt:sub(1, utf8.offset(nxt, 201) - 1) .. "…" end
    lines[#lines + 1] = "Text right after the caret (the new text goes before it; do not repeat it):\n«" .. nxt .. "»"
  end
  if #lines == 0 then return nil end
  return table.concat(lines, "\n")
end

--- Gemini sometimes opens with the tail of the quoted text before the caret
--- («ці. Перевір…» after «…до п'ятниці.»; 3 of 15 test takes, 2026-10-20).
--- Drop such a lead when it is a suffix of that text ending in punctuation.
local function dropEcho(out, before)
  if not before or before == "" then return out end
  local tail = tailChars((before:gsub("%s+$", "")), 40)
  local cps = {}
  for p in utf8.codes(tail) do cps[#cps + 1] = p end
  for i = 1, #cps do                                   -- longest suffix first
    local suffix = tail:sub(cps[i])
    if utf8.len(suffix) >= 2 and suffix:match("[%.!?,:;]$")
       and out:sub(1, #suffix) == suffix and out:sub(#suffix + 1):match("^%s+%S") then
      return (out:sub(#suffix + 1):gsub("^%s+", ""))
    end
  end
  return out
end

-- Command Mode's system prompt. The instruction is dictated, so it may carry
-- recognition errors; the selection is the user's own text.
local COMMAND_PROMPT = [[
You edit text for the user. You receive SELECTED TEXT and a spoken INSTRUCTION.
The instruction was dictated, mostly in Ukrainian, and may contain speech
recognition errors - read it for its intent.

Apply the instruction to the selected text and return only the resulting text:
no quotes around it, no comments, no explanations, no Markdown fences.

- Change only what the instruction asks for; keep everything else as it is.
- Keep the language of the selected text unless the instruction asks for a
  translation. Ukrainian stays Ukrainian, never Russian. English terms inside
  Ukrainian stay in Latin script.
- Keep the structure (paragraphs, lists) unless the instruction changes it.
- If the instruction asks a question about the text instead of an edit, return
  the text unchanged.
]]

-- { key, untilEpoch } after Google refused the free key; see llm.freeKeyFile.
local freeRefused = nil

--- Unix time of the next midnight Pacific, when Google resets daily quotas.
local function nextQuotaReset()
  local hms = hs.execute("TZ=America/Los_Angeles /bin/date +%H:%M:%S") or ""
  local h, m, sec = hms:match("(%d+):(%d+):(%d+)")
  if not h then return os.time() + 3600 end
  return os.time() + 86400 - (tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec))
end

--- { {label, key} } in the order to try: the free key unless refused since the
--- last quota reset, then the paid one.
local function formatterKeys()
  local keys, free = {}, M.config.llm.freeKeyFile and apiKey(M.config.llm.freeKeyFile)
  if free and not (freeRefused and freeRefused.key == free and os.time() < freeRefused.untilEpoch) then
    keys[#keys + 1] = { label = "free", key = free }
  end
  local paid = apiKey()
  if paid then keys[#keys + 1] = { label = "paid", key = paid } end
  return keys
end

--- Why Google turned the key down, or nil when the answer is about something else.
local function keyRefusal(status, raw)
  local lower = (raw or ""):lower()
  local aboutKey = lower:find("api key", 1, true) or lower:find("api_key", 1, true)
                   or lower:find("permission", 1, true)
  if status ~= 429 and not ((status == 400 or status == 401 or status == 403) and aboutKey) then return nil end
  local ok, resp = pcall(hs.json.decode, raw or "")
  local err = ok and type(resp) == "table" and (resp.error or (type(resp[1]) == "table" and resp[1].error))
  local msg = type(err) == "table" and type(err.message) == "string" and err.message or nil
  return "HTTP " .. status .. (msg and (": " .. msg:sub(1, 160)) or "")
end

local function structure(text, caret, done, opts)
  opts = opts or {}
  local keys = formatterKeys()
  -- A local endpoint has no key; a remote one without a key is a config error.
  if #keys == 0 and M.config.llm.endpoint:match("^https://") then
    return done(text, "no API key")
  end

  local body = {
    model       = M.config.llm.model,
    temperature = M.config.llm.temperature,
    messages    = {
      { role = "system", content = opts.system or formatPrompt() },
      { role = "user",   content = opts.user or (function()
          local ctx = context(caret, opts.job)
          return ctx and (ctx .. "\n\n---\n\n" .. text) or text
        end)() },
    },
  }
  for k, v in pairs(M.config.llm.extra or {}) do body[k] = v end
  local payload = hs.json.encode(body)

  local bodyPath = RUN_DIR .. "/request.json"
  local rcPath   = RUN_DIR .. "/request.curlrc"

  local body = io.open(bodyPath, "w"); body:write(payload); body:close()

  -- which key served, and why the free one was dropped; lands in takes.jsonl
  local info = {}
  local function attempt(i)
    local k = keys[i]
    info.key = k and k.label
    -- The key goes in a curl config file rather than argv, where every process on
    -- the machine could read it. RUN_DIR is chmod 700.
    local rc = io.open(rcPath, "w")
    if k then rc:write('header = "Authorization: Bearer ' .. k.key .. '"\n') end
    rc:close()

    hs.task.new(M.config.curl, function(code, stdout, _)
      os.remove(rcPath)

      -- -w appends the HTTP status as the last line
      local raw, status = (stdout or ""):match("^(.*)\n(%d%d%d)$")
      status = tonumber(status)
      if code ~= 0 or not raw or raw == "" then
        -- curl exits 28 when --max-time runs out
        return done(text, code == 28 and "formatter timeout" or "formatter unreachable", nil, info)
      end

      -- Refused free key: one retry with the next key, no other wait.
      local refusal = keys[i + 1] and keyRefusal(status, raw)
      if refusal then
        info.keySwitch = k.label .. " refused: " .. refusal
        if k.label == "free" then freeRefused = { key = k.key, untilEpoch = nextQuotaReset() } end
        logLine("formatter: " .. info.keySwitch .. ", retrying with the " .. keys[i + 1].label .. " key")
        return attempt(i + 1)
      end

      local ok, resp = pcall(hs.json.decode, raw)
      if not ok or type(resp) ~= "table" then return done(text, "formatter: bad response", nil, info) end
      local err = resp.error or (type(resp[1]) == "table" and resp[1].error)
      if err then
        return done(text, "formatter: " .. (type(err) == "table" and (err.message or err.code) or "error"), nil, info)
      end

      local choice = (resp.choices or {})[1]
      local formatted = choice and choice.message and choice.message.content
      if type(formatted) ~= "string" then return done(text, "formatter: no content", nil, info) end

      formatted = formatted:gsub("^%s+", ""):gsub("%s+$", "")
      -- Strip a code fence if the model wrapped the answer despite being told not to.
      formatted = formatted:gsub("^```[%a]*\n(.-)\n```$", "%1")
      formatted = dropEcho(formatted, caret and caret.before)
      if formatted == "" then return done(text, "formatter: empty", nil, info) end
      done(formatted, nil, resp.usage, info)
    end, {
      "-s", "--max-time", tostring(opts.timeout or M.config.llm.timeout),
      "-w", "\n%{http_code}",
      "-K", rcPath,
      "-H", "content-type: application/json",
      "-d", "@" .. bodyPath,
      M.config.llm.endpoint,
    }):start()
  end
  attempt(1)
end

--------------------------------------------------------------------------------
-- Never lose a take
--------------------------------------------------------------------------------

--- Whole days between that date and today. Computed here so the filter in the
--- history page is a number comparison and never has to do date maths.
local function daysAgo(day)
  local y, m, d = day:match("(%d+)-(%d+)-(%d+)")
  if not y then return nil end
  local noon = function(yy, mm, dd)
    return os.time({ year = tonumber(yy), month = tonumber(mm), day = tonumber(dd), hour = 12 })
  end
  return math.floor((noon(os.date("%Y"), os.date("%m"), os.date("%d")) - noon(y, m, d)) / 86400 + 0.5)
end

--- Deletes transcripts past the retention window. Runs at launch and after
--- every take, so the folder never needs a separate housekeeping job.
local function pruneTranscripts()
  local keep = M.config.transcriptDays
  if not keep or keep <= 0 then return 0 end
  local removed = 0
  -- The audio of failed takes keeps the same window as the text.
  for _, dir in ipairs({ LOG_DIR, FAILED, AUDIO }) do
    keep = dir == AUDIO and (M.config.audioDays or 0) or M.config.transcriptDays
    local ok, iter, dirobj = pcall(hs.fs.dir, dir)
    if ok and iter and keep > 0 then
      for name in iter, dirobj do
        local day = name:match("^(%d%d%d%d%-%d%d%-%d%d)_")
        local age = day and daysAgo(day)
        if age and age >= keep then
          os.remove(dir .. "/" .. name)
          removed = removed + 1
        end
      end
    end
  end
  return removed
end

--- Written the instant Whisper answers, before formatting is attempted. A slow
--- or broken formatter can then cost time, but never words.
local function keepTranscript(text)
  hs.fs.mkdir(LOG_DIR)
  local name = os.date("%Y-%m-%d_%H-%M-%S")
  local file = io.open(LOG_DIR .. "/" .. name .. ".txt", "w")
  if file then file:write(text); file:close() end
  M.lastTranscript = text
  state.transcriptName = name
  pruneTranscripts()
  return name
end

--- Once the formatter has answered, the file holds the text the user actually
--- got; the recogniser's version stays beside it as <name>.raw.txt.
local function keepFinal(text)
  local name = state.transcriptName
  if not name or text == M.lastTranscript then return end
  os.rename(LOG_DIR .. "/" .. name .. ".txt", LOG_DIR .. "/" .. name .. ".raw.txt")
  local file = io.open(LOG_DIR .. "/" .. name .. ".txt", "w")
  if file then file:write(text); file:close() end
  M.lastTranscript = text
end

--- Seconds of audio in a 16 kHz mono 16-bit WAV, from its size alone, so it
--- also works on a file sox is still writing.
local function wavSeconds(path)
  local attrs = hs.fs.attributes(path)
  if not attrs or attrs.size <= 44 then return 0 end
  return (attrs.size - 44) / 32000
end

--- Parakeet's failure mode, and WhisperKit's repeat loop: a reply hundreds
--- of characters per second long (6850 characters for 10.9 s). Speech runs at
--- about 15.
local function runaway(text, seconds)
  local chars = utf8.len(text) or #text
  return chars > 200 and chars > 60 * seconds
end

local function round(x, places)
  local m = 10 ^ (places or 0)
  return math.floor(x * m + 0.5) / m
end

-- Outcomes worth keeping the audio for: speech was there and got lost.
local LOST = { server_down = true, could_not_transcribe = true, garbage = true,
               no_speech = true, silence = true }

--- Closes a take's record: one JSON line in takes.jsonl. The text is not in
--- it - that lives in transcripts/, and `transcript` names the file. A lost
--- take, or one the fallback engine had to rescue, keeps its audio in failed/
--- so the failure can be replayed against a fix.
local function keepAudio(take, dir)
  if not take or take.audio then return end
  hs.fs.mkdir(dir)
  local name = take.at:gsub("T", "_"):gsub(":", "-") .. ".wav"
  local src = io.open(wavOf[take] or WAV, "rb")
  local data = src and src:read("a")
  if src then src:close() end
  local dst = data and io.open(dir .. "/" .. name, "wb")
  if dst then dst:write(data); dst:close(); take.audio = dir:match("[^/]+$") .. "/" .. name end
end

local function finishTake(take, outcome, problem)
  if not take or take.outcome then return end
  if inFlight[take] then
    inFlight[take] = nil
    state.busy = math.max(0, (state.busy or 1) - 1)
    if M.refreshMenu then M.refreshMenu() end
  end
  take.outcome = outcome
  take.problem = problem
  if LOST[outcome] or take.fallback then keepAudio(take, FAILED) end
  local ok, line = pcall(hs.json.encode, take)
  local file = ok and io.open(TAKES, "a")
  if file then file:write(line, "\n"); file:close() end
  if not ok then logLine("takes.jsonl: " .. tostring(line)) end
end

--------------------------------------------------------------------------------
-- Learning from edits
--------------------------------------------------------------------------------

-- After a paste the field is read again at 30 s and 2 min, and once more when
-- the next take starts. A word the user replaced with something that sounds
-- the same and looks like a term becomes a suggestion in the Dictionary
-- window; nothing goes into the dictionary without a click.
-- suggestions.json: { items = { { term, from = {...}, count, last } }, dismissed = { [lower] = true } }

local function loadSuggestions()
  local f = io.open(SUGG, "r")
  local data = f and f:read("a"); if f then f:close() end
  local ok, s = false, nil
  if data and data ~= "" then ok, s = pcall(hs.json.decode, data) end
  s = (ok and type(s) == "table") and s or {}
  s.items, s.dismissed = s.items or {}, s.dismissed or {}
  return s
end

local function saveSuggestions(s)
  local f = io.open(SUGG, "w")
  if f then f:write(hs.json.encode(s, true)); f:close() end
end

local function inDictionary(term)
  local low = LEARN.lower(term)
  local f = io.open(DICT, "r")
  if not f then return false end
  for line in f:lines() do
    if LEARN.lower((line:gsub("^%s+", ""):gsub("%s+$", ""))) == low then f:close(); return true end
  end
  f:close()
  return false
end

local function addSuggestion(from, to)
  if inDictionary(to) then return end
  local s = loadSuggestions()
  local low = LEARN.lower(to)
  if s.dismissed[low] then return end
  local hit
  for _, it in ipairs(s.items) do if LEARN.lower(it.term) == low then hit = it end end
  if not hit then hit = { term = to, from = {}, count = 0 }; s.items[#s.items + 1] = hit end
  hit.count, hit.last = hit.count + 1, os.date("%Y-%m-%dT%H:%M:%S")
  local known = false
  for _, f in ipairs(hit.from) do if f == from then known = true end end
  if not known and #hit.from < 5 then hit.from[#hit.from + 1] = from end
  saveSuggestions(s)
  logLine("learned: «" .. from .. "» -> «" .. to .. "»")
  if M.refreshMenu then M.refreshMenu() end
  -- Say so, unless a take is being recorded (show() stays quiet then anyway).
  if state.phase == "idle" then
    show(COL.ok, "suggested «" .. to .. "» for the Dictionary")
    hideLater(3)
  end
end

local function checkEdits(final)
  local w = state.watch
  if not w then return end
  if final then
    state.watch = nil
    for _, t in ipairs(w.timers) do t:stop() end
  end
  local ok, value = pcall(function() return w.el:attributeValue("AXValue") end)
  if not ok or type(value) ~= "string" then state.watch = nil; return end
  -- Text above the paste changed: positions no longer line up, try later.
  if value:sub(1, #w.before) ~= w.before then return end
  local okc, found = pcall(LEARN.corrections, w.text, value:sub(#w.before + 1))
  if not okc then logLine("learn: " .. tostring(found)); return end
  for _, c in ipairs(found) do
    if not w.seen[c.to] then w.seen[c.to] = true; addSuggestion(c.from, c.to) end
  end
end

local function watchEdits(text, caret)
  if not (LEARN and caret and caret.el and caret.before and text) then return end
  checkEdits(true)
  local w = { el = caret.el, before = caret.before, text = text, seen = {}, timers = {} }
  -- Every 5 s for 2 min: one AXValue read each, cheap, and a fix shows up as a
  -- suggestion seconds after it is typed rather than half a minute later.
  w.timers[1] = hs.timer.doEvery(5, function() if state.watch == w then checkEdits(false) end end)
  w.timers[2] = hs.timer.doAfter(120, function() if state.watch == w then checkEdits(true) end end)
  state.watch = w
end

--------------------------------------------------------------------------------
-- Snippets
--------------------------------------------------------------------------------

-- A take that is only a cue ("мій імейл") is replaced by its text, at once and
-- without the formatter. snippets.json: [ { cue, text } ]. The match ignores
-- case and punctuation and forgives a near miss of the recogniser.

local function loadSnippets()
  local f = io.open(SNIPS, "r")
  local data = f and f:read("a"); if f then f:close() end
  if not data or data == "" then return {} end
  local ok, list = pcall(hs.json.decode, data)
  return (ok and type(list) == "table") and list or {}
end

local function saveSnippets(list)
  local f = io.open(SNIPS, "w")
  if f then f:write(hs.json.encode(list, true)); f:close() end
end

local function normalCue(s)
  -- Multi-byte marks one by one: inside a [class] they would match single
  -- bytes and cut Cyrillic letters in half.
  s = LEARN.lower(s)
  for _, mark in ipairs({ "«", "»", "“", "”", "„", "—", "–", "…", "’" }) do s = s:gsub(mark, " ") end
  s = s:gsub("%p", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  return s
end

--- A cue field may hold several spellings separated by "|".
local function cuesOf(sn)
  local out = {}
  for part in ((sn.cue or "") .. "|"):gmatch("([^|]*)|") do
    local alt = part:gsub("^%s+", ""):gsub("%s+$", "")
    if alt ~= "" then out[#out + 1] = alt end
  end
  return out
end

local function matchSnippet(text)
  if not LEARN then return nil end
  local said = normalCue(text)
  if said == "" or (utf8.len(said) or #said) > 60 then return nil end
  for _, sn in ipairs(loadSnippets()) do
    for _, alt in ipairs(cuesOf(sn)) do
      local cue = normalCue(alt)
      if cue ~= "" and (cue == said or ((utf8.len(cue) or 0) >= 5 and LEARN.similarity(cue, said) >= 0.85)) then
        return sn
      end
    end
  end
  return nil
end

--- A cue said inside a longer take («надішли на мій імейл») is replaced in
--- place, after formatting. Case-insensitive, whole words only. Lower-casing
--- keeps byte lengths for Latin and Cyrillic, so positions carry over.
local function expandSnippets(text)
  if not LEARN then return text end
  local function isWordByte(b) return b and (b >= 0x80 or string.char(b):match("%w")) end
  for _, sn in ipairs(loadSnippets()) do
    for _, alt in ipairs(cuesOf(sn)) do
      local needle = LEARN.lower(alt)
      local from = 1
      while true do
        local low = LEARN.lower(text)
        local a, b = low:find(needle, from, true)
        if not a then break end
        if not isWordByte(text:byte(a - 1)) and not isWordByte(text:byte(b + 1)) then
          text = text:sub(1, a - 1) .. sn.text .. text:sub(b + 1)
          from = a + #sn.text
        else
          from = b + 1
        end
      end
    end
  end
  return text
end

local function dictionarySet()
  local set, f = {}, io.open(DICT, "r")
  if not f then return set end
  for line in f:lines() do
    local t = line:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" and not t:match("^#") then set[LEARN.lower(t)] = true end
  end
  f:close()
  return set
end

--- Every word of every dictionary term, lower-cased, for counting fixes.
local function dictWordSet()
  local set = {}
  for term in pairs(dictionarySet()) do
    for w in term:gmatch("%S+") do set[w] = true end
  end
  return set
end

--------------------------------------------------------------------------------
-- Usage
--------------------------------------------------------------------------------

-- Words, minutes, takes and money per day, for the Usage section. The journal
-- (takes.jsonl) has everything from 2026-10-20 11:58; days before it were
-- rebuilt once from transcripts/ into usage-history.json (words and takes, no
-- durations). Only formatting costs money; both recognisers run on the Mac.
local USAGE_HISTORY = RUN_DIR .. "/usage-history.json"
local PRICE = { ["gemini-3.5-flash-lite"] = { 0.30, 2.50 } }   -- $ per 1M tokens in / out
-- Per formatted take where tokens were not logged: Gemini from the 2026-10-20
-- benches (~2 400 tokens in, ~40 out), z.ai from its October balance.
local EST_GEMINI, EST_GLM = 0.00082, 0.0013

local function usageDays()
  local days = {}
  local function day(d)
    days[d] = days[d] or { takes = 0, words = 0, seconds = 0, cost = 0, est = false }
    return days[d]
  end
  local f = io.open(USAGE_HISTORY, "r")
  local data = f and f:read("a"); if f then f:close() end
  if data and data ~= "" then
    local ok, h = pcall(hs.json.decode, data)
    if ok and type(h) == "table" and type(h.days) == "table" then
      for d, v in pairs(h.days) do
        local x = day(d)
        x.takes, x.words = x.takes + (v.takes or 0), x.words + (v.words or 0)
        if (v.formatted or 0) > 0 then x.cost = x.cost + v.formatted * EST_GLM; x.est = true end
      end
    end
  end
  local jf = io.open(TAKES, "r")
  if jf then
    for line in jf:lines() do
      local ok, r = pcall(hs.json.decode, line)
      if ok and type(r) == "table" and r.outcome == "ok" and type(r.at) == "string" then
        local x = day(r.at:sub(1, 10))
        x.takes = x.takes + 1
        x.words = x.words + (tonumber(r.words) or 0)
        x.seconds = x.seconds + (tonumber(r.seconds) or 0)
        local l = r.llm
        if type(l) == "table" and type(l.model) == "string" then
          local pr = PRICE[l.model]
          if pr and l.tokensIn then
            x.cost = x.cost + (l.tokensIn * pr[1] + (l.tokensOut or 0) * pr[2]) / 1e6
          elseif l.model:match("^gemini") then x.cost, x.est = x.cost + EST_GEMINI, true
          elseif l.model:match("^glm") then x.cost, x.est = x.cost + EST_GLM, true end
        end
      end
    end
    jf:close()
  end
  return days
end

local function thousands(n)
  local s = tostring(math.floor(n + 0.5))
  return (s:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", ""))
end

local function money(cost, est)
  return (est and "≈ $" or "$") .. string.format(cost < 10 and "%.2f" or "%.0f", cost)
end

local function noonOf(d)
  local y, m, dd = d:match("^(%d+)-(%d+)-(%d+)$")
  return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 })
end

--- Words per hour of a given day, from the journal (the history file has no hours).
local function usageHours(day)
  local hours = {}
  for h = 0, 23 do hours[h] = { takes = 0, words = 0, seconds = 0, cost = 0, est = false } end
  local jf = io.open(TAKES, "r")
  if not jf then return hours end
  for line in jf:lines() do
    local ok, r = pcall(hs.json.decode, line)
    if ok and type(r) == "table" and r.outcome == "ok" and type(r.at) == "string" and r.at:sub(1, 10) == day then
      local x = hours[tonumber(r.at:sub(12, 13))]
      if x then
        x.takes, x.words = x.takes + 1, x.words + (tonumber(r.words) or 0)
        x.seconds = x.seconds + (tonumber(r.seconds) or 0)
        local l = r.llm
        if type(l) == "table" and type(l.model) == "string" then
          local pr = PRICE[l.model]
          if pr and l.tokensIn then x.cost = x.cost + (l.tokensIn * pr[1] + (l.tokensOut or 0) * pr[2]) / 1e6
          elseif l.model:match("^gemini") then x.cost, x.est = x.cost + EST_GEMINI, true end
        end
      end
    end
  end
  jf:close()
  return hours
end

local function level(w, steps)
  if w == 0 then return 0 end
  for i, cap in ipairs(steps) do if w < cap then return i end end
  return 4
end

local function tipOf(label, v)
  if not v or v.takes == 0 then return label .. " · nothing" end
  return string.format("%s · %s words · %s min · %s %s · %s", label, thousands(v.words),
    thousands(v.seconds / 60), thousands(v.takes), v.takes == 1 and "take" or "takes", money(v.cost, v.est))
end

-- Kinds of app for the Usage breakdown: the style kinds plus documents.
local DOC_APPS = { Notes = true, Notion = true, Obsidian = true, ["Microsoft Word"] = true, Pages = true,
                   TextEdit = true, Craft = true, Bear = true }
local KIND_LABEL = {
  { "ai", "AI prompts" }, { "personal", "Personal messages" }, { "work", "Work messages" },
  { "email", "Emails" }, { "documents", "Documents" }, { "other", "Other tasks" },
}

--- Every delivered take in the journal, with what the Usage section needs.
local function usageTakes()
  local list, dw = {}, nil
  local jf = io.open(TAKES, "r")
  if not jf then return list end
  for line in jf:lines() do
    local ok, r = pcall(hs.json.decode, line)
    if ok and type(r) == "table" and r.outcome == "ok" and type(r.at) == "string" then
      local t = { d = r.at:sub(1, 10), h = tonumber(r.at:sub(12, 13)), words = tonumber(r.words) or 0,
                  seconds = tonumber(r.seconds) or 0, cost = 0, est = false }
      local l = r.llm
      if type(l) == "table" and type(l.model) == "string" then
        local pr = PRICE[l.model]
        if pr and l.tokensIn then t.cost = (l.tokensIn * pr[1] + (l.tokensOut or 0) * pr[2]) / 1e6
        elseif l.model:match("^gemini") then t.cost, t.est = EST_GEMINI, true
        elseif l.model:match("^glm") then t.cost, t.est = EST_GLM, true end
      end
      local app = r.app or ""
      t.kind = KIND_OF_APP[app] or (DOC_APPS[app] and "documents") or "other"
      if type(r.fixes) == "table" then
        t.fixed, t.dict = tonumber(r.fixes.words) or 0, tonumber(r.fixes.dict) or 0
      elseif r.transcript and LEARN then
        -- Older takes: compare the files while transcripts/ still has them.
        local rf = io.open(LOG_DIR .. "/" .. r.transcript .. ".raw.txt", "r")
        local ff = rf and io.open(LOG_DIR .. "/" .. r.transcript .. ".txt", "r")
        if rf and ff then
          dw = dw or dictWordSet()
          local okf, ch, dc = pcall(LEARN.fixes, rf:read("a"), ff:read("a"), dw)
          if okf then t.fixed, t.dict = ch, dc end
        end
        if rf then rf:close() end
        if ff then ff:close() end
      end
      list[#list + 1] = t
    end
  end
  jf:close()
  return list
end

--- Days in a row with at least one take: the run ending today (or yesterday,
--- if nothing yet today) and the longest ever.
local function streaks(days)
  local set = {}
  for d, v in pairs(days) do if v.takes > 0 then set[d] = true end end
  local DAY, today = 86400, noonOf(os.date("%Y-%m-%d"))
  local cur, t = 0, today
  if not set[os.date("%Y-%m-%d", t)] then t = t - DAY end
  while set[os.date("%Y-%m-%d", t)] do cur = cur + 1; t = t - DAY end
  local sorted = {}
  for d in pairs(set) do sorted[#sorted + 1] = d end
  table.sort(sorted)
  local best, run, prev = 0, 0, nil
  for _, d in ipairs(sorted) do
    local nt = noonOf(d)
    run = (prev and math.abs(nt - prev - DAY) < 7200) and run + 1 or 1
    best = math.max(best, run); prev = nt
  end
  return cur, best
end

local function gauge(wpm)
  local frac = math.max(0, math.min(1, wpm / 200))
  return string.format('<svg class="gauge" viewBox="0 0 140 78">'
    .. '<path d="M12 72 A58 58 0 0 1 128 72" fill="none" stroke="#e5e5e5" stroke-width="12" stroke-linecap="round" pathLength="100"/>'
    .. '<path d="M12 72 A58 58 0 0 1 128 72" fill="none" stroke="#111111" stroke-width="12" stroke-linecap="round" pathLength="100" stroke-dasharray="%.1f 100"/>'
    .. '<text x="70" y="66" text-anchor="middle" class="gt">of 200</text></svg>', frac * 100)
end

--- The Usage section: a tab per period
--- (Today, Week, Month, All time); each with words per minute, fixes made,
--- totals, a breakdown by kind of app, the streak and the period's squares.
local function usageBox()
  local days, takes = usageDays(), usageTakes()
  local today = os.date("%Y-%m-%d")
  local now = noonOf(today)
  local DAY = 86400
  local weekFrom = os.date("%Y-%m-%d", now - 6 * DAY)
  local legend = '<div class="hlegend">Less <i class="l0"></i><i class="l1"></i><i class="l2"></i>'
    .. '<i class="l3"></i><i class="l4"></i> More</div>'
  local cur, best = streaks(days)

  local function squares(id)
    if id == "today" then
      local hours, cells, labels = usageHours(today), {}, {}
      for h = 0, 23 do
        local v = hours[h]
        cells[#cells + 1] = string.format('<i class="l%d" data-tip="%s"></i>', level(v.words, { 20, 100, 300 }),
          tipOf(os.date("%d %B %Y", now) .. string.format(", %02d:00–%02d:59", h, h), v))
        labels[#labels + 1] = '<span>' .. ((h % 3 == 0) and string.format("%02d", h) or "") .. '</span>'
      end
      return '<div class="sq24"><div class="sqlabels">' .. table.concat(labels) .. '</div><div class="sqrow">'
        .. table.concat(cells) .. '</div></div>'
    elseif id == "week" then
      local cells = {}
      for k = 6, 0, -1 do
        local t = now - k * DAY
        local v = days[os.date("%Y-%m-%d", t)]
        cells[#cells + 1] = string.format('<div class="dcell"><i class="l%d" data-tip="%s"></i><span>%s</span></div>',
          level(v and v.words or 0, { 100, 500, 1500 }), tipOf(os.date("%A, %d %B %Y", t), v), os.date("%a %d", t))
      end
      return '<div class="sq7">' .. table.concat(cells) .. '</div>'
    elseif id == "month" then
      local y, m = today:match("^(%d+)-(%d+)")
      local first = os.time({ year = tonumber(y), month = tonumber(m), day = 1, hour = 12 })
      local cells = {}
      for _, wd in ipairs({ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }) do
        cells[#cells + 1] = '<span class="wd">' .. wd .. '</span>'
      end
      for _ = 1, (tonumber(os.date("%w", first)) + 6) % 7 do cells[#cells + 1] = '<span></span>' end
      local t = first
      while os.date("%m", t) == m do
        local d = os.date("%Y-%m-%d", t)
        local v = days[d]
        cells[#cells + 1] = string.format('<i class="l%d%s" data-tip="%s">%d</i>',
          level(v and v.words or 0, { 100, 500, 1500 }), d == today and " now" or "",
          tipOf(os.date("%A, %d %B %Y", t), v), tonumber(os.date("%d", t)))
        t = t + DAY
      end
      return '<div class="cal">' .. table.concat(cells) .. '</div>'
    end
    local start = now - 364 * DAY
    start = start - ((tonumber(os.date("%w", start)) + 6) % 7) * DAY
    local cells, months, lastMonth, col, t = {}, {}, nil, 0, start
    while t <= now do
      if (tonumber(os.date("%w", t)) + 6) % 7 == 0 then
        col = col + 1
        local mon = os.date("%b", t)
        months[col] = (mon ~= lastMonth) and mon or ""
        lastMonth = mon
      end
      local v = days[os.date("%Y-%m-%d", t)]
      cells[#cells + 1] = string.format('<i class="l%d" data-tip="%s"></i>',
        level(v and v.words or 0, { 100, 500, 1500 }), tipOf(os.date("%A, %d %B %Y", t), v))
      t = t + DAY
    end
    local labels = {}
    for i = 1, col do labels[i] = '<span>' .. (months[i] or "") .. '</span>' end
    return '<div class="heatwrap"><div class="hmonths">' .. table.concat(labels) .. '</div>'
      .. '<div class="heat">' .. table.concat(cells) .. '</div></div>'
  end

  local function panel(id, inPeriod)
    local tot = { takes = 0, words = 0, seconds = 0, cost = 0, est = false }
    for d, v in pairs(days) do
      if inPeriod(d) then
        tot.takes, tot.words, tot.seconds = tot.takes + v.takes, tot.words + v.words, tot.seconds + v.seconds
        tot.cost, tot.est = tot.cost + v.cost, tot.est or v.est
      end
    end
    local wWords, wSecs, fixed, dict, jTakes, kinds = 0, 0, 0, 0, 0, {}
    for _, t in ipairs(takes) do
      if inPeriod(t.d) then
        jTakes = jTakes + 1
        if t.seconds > 0 then wWords, wSecs = wWords + t.words, wSecs + t.seconds end
        fixed, dict = fixed + (t.fixed or 0), dict + (t.dict or 0)
        local k = kinds[t.kind] or { takes = 0, words = 0 }
        k.takes, k.words = k.takes + 1, k.words + t.words
        kinds[t.kind] = k
      end
    end
    local wpm = wSecs > 0 and wWords / (wSecs / 60) or 0
    local kindWords = 0
    for _, k in pairs(kinds) do kindWords = kindWords + k.words end
    local bars, used = {}, 0
    for _, kl in ipairs(KIND_LABEL) do
      local k = kinds[kl[1]] or { takes = 0, words = 0 }
      if k.takes > 0 then used = used + 1 end
      local pct = kindWords > 0 and math.floor(k.words / kindWords * 100 + 0.5) or 0
      bars[#bars + 1] = string.format('<div class="bar"><div class="track"><div class="fill" style="width:%d%%">'
        .. '<span>%d%%</span></div></div><div class="blab">%s %s</div></div>',
        math.max(pct, 6), pct, thousands(k.takes), kl[2])
    end
    return '<div class="upanel' .. (id == "today" and " on" or "") .. '" id="u-' .. id .. '">'
      .. '<div class="ins3">'
      .. '<div class="icard"><div class="ibig">' .. thousands(wpm) .. '</div><div class="ilab">words per minute</div>'
      .. gauge(wpm) .. '</div>'
      .. '<div class="icard"><div class="ibig">' .. thousands(fixed) .. '</div><div class="ilab">fixes made by Pysar</div>'
      .. '<div class="irule"></div><div class="iline">' .. thousands(fixed - dict) .. ' words corrected</div>'
      .. '<div class="iline">' .. thousands(dict) .. ' dictionary fixes</div></div>'
      .. '<div class="icard"><div class="ibig">' .. thousands(tot.words) .. '</div><div class="ilab">words dictated</div>'
      .. '<div class="irule"></div><div class="iline">' .. thousands(tot.seconds / 60) .. ' min · '
      .. thousands(tot.takes) .. ' takes</div><div class="iline">' .. money(tot.cost, tot.est) .. ' spent</div></div>'
      .. '</div>'
      .. '<div class="icard wide"><div class="ihead"><h3>By app</h3><span>kinds used | ' .. used .. '</span></div>'
      .. table.concat(bars) .. '</div>'
      .. '<div class="icard wide"><div class="ihead"><h3>' .. cur .. ' day streak</h3><span>longest streak | '
      .. best .. ' days</span></div>' .. squares(id) .. legend .. '</div>'
      .. '</div>'
  end

  return '<nav class="utabs">'
    .. '<button class="utab on" data-p="u-today">Today</button>'
    .. '<button class="utab" data-p="u-week">Week</button>'
    .. '<button class="utab" data-p="u-month">Month</button>'
    .. '<button class="utab" data-p="u-all">All time</button></nav>'
    .. panel("today", function(d) return d == today end)
    .. panel("week", function(d) return d >= weekFrom and d <= today end)
    .. panel("month", function(d) return d:sub(1, 7) == today:sub(1, 7) end)
    .. panel("all", function() return true end)
    .. '<p class="note">Words per minute, fixes and the app breakdown come from the takes journal, '
    .. 'kept from 20 Oct 2026, 11:58; earlier days add words and takes only, and their cost (≈) is estimated. '
    .. 'The bill itself: AI Studio → Billing.</p>'
end

--------------------------------------------------------------------------------
-- Screen context
--------------------------------------------------------------------------------

-- While a take records, the focused window's accessibility tree is walked in
-- small slices (20 ms each, so the meter never stalls): its title, and names
-- and terms out of its visible text, go to the formatter as spelling hints.
-- Capped at 1500 nodes, 20 000 characters or 3 s; password fields and the
-- apps in screenContextSkip are never read. Nothing is stored.

local SCREEN_ROLES = { AXStaticText = true, AXHeading = true, AXLink = true, AXCell = true }



local function gatherScreen(retried)
  state.screen = nil
  local app = state.target
  if not (M.config.screenContext and LEARN and app) then return end
  if (M.config.screenContextSkip or {})[app:name() or ""] then return end
  wakeAccessibility(app)
  local ok, appEl = pcall(hs.axuielement.applicationElement, app)
  if not ok or not appEl then return end
  bounded(appEl)
  local okw, win = pcall(function() return appEl:attributeValue("AXFocusedWindow") end)
  if not okw or not win then return end
  bounded(win)
  local okt, title = pcall(function() return win:attributeValue("AXTitle") end)
  local scr = { title = (okt and type(title) == "string") and title or nil, names = {} }
  state.screen = scr
  local take = state.take

  -- head/tail by hand: nil-ing taken slots leaves holes, and #queue on a
  -- table with holes can read as 0 and end the walk at the third node.
  local queue, head, tail, seen, texts, chars = { win }, 1, 1, 0, {}, 0
  local started = hs.timer.secondsSinceEpoch()
  local function step()
    if state.screen ~= scr then return end            -- a newer take took over
    local sliceEnd = hs.timer.secondsSinceEpoch() + 0.02
    while head <= tail and seen < 1500 and chars < 20000
          and hs.timer.secondsSinceEpoch() < sliceEnd do
      local el = queue[head]; queue[head] = nil; head = head + 1; seen = seen + 1
      local okr, role = pcall(function() return el:attributeValue("AXRole") end)
      if okr and role ~= "AXSecureTextField" then
        if SCREEN_ROLES[role] then
          for _, attr in ipairs({ "AXValue", "AXTitle", "AXDescription" }) do
            local okv, v = pcall(function() return el:attributeValue(attr) end)
            if okv and type(v) == "string" and v ~= "" then
              texts[#texts + 1] = v; chars = chars + #v; break
            end
          end
        end
        local okc, kids = pcall(function() return el:attributeValue("AXChildren") end)
        if okc and type(kids) == "table" then
          for _, k in ipairs(kids) do tail = tail + 1; queue[tail] = bounded(k) end
        end
      end
    end
    local elapsed = hs.timer.secondsSinceEpoch() - started
    if head <= tail and seen < 1500 and chars < 20000 and elapsed < 3 then
      state.screenTimer = hs.timer.doAfter(0.03, step)
      return
    end
    -- Electron builds its tree only once woken; a first walk of a cold window
    -- sees a handful of nodes. Give it half a second and walk once more.
    if seen < 20 and not retried then
      state.screenTimer = hs.timer.doAfter(0.5, function()
        if state.screen == scr then gatherScreen(true) end
      end)
      return
    end
    local okn, names = pcall(LEARN.names, texts, dictionarySet(), 40)
    scr.names = okn and names or {}
    scr.nodes, scr.texts, scr.ms = seen, #texts, math.floor(elapsed * 1000 + 0.5)
    if take then
      take.screen = { nodes = seen, names = #scr.names, ms = math.floor(elapsed * 1000 + 0.5) }
    end
  end
  step()
end

--- What the formatter would be told about the frontmost window right now.
function M.screenContext()
  state.target = hs.application.frontmostApplication()
  gatherScreen()
  return state.screen
end
function M.screenState() return state.screen end

--------------------------------------------------------------------------------
-- Delivery
--------------------------------------------------------------------------------

--- `canPaste` is decided before the structuring pass runs, while the user's own
--- window is still the one in front.
local function deliver(text, lang, canPaste, caret, raw, target)
  target = target or state.target
  keepFinal(text)
  local tag = (M.config.showLanguage and lang) and (" · " .. lang:upper()) or ""
  local preview = text:len() > 42 and (text:sub(1, 42) .. "…") or text
  preview = preview:gsub("%s+", " ")

  if canPaste then
    paste(text, caret, false, target)
    watchEdits(state.pasted, caret)
    state.last = { raw = raw or text, pasted = state.pasted, caret = caret,
                   target = target, at = hs.timer.secondsSinceEpoch() }
    show(COL.ok, "→ " .. (target and target:name() or "?") .. tag
                 .. "  «" .. preview .. "»")
  else
    hs.pasteboard.setContents(text)
    if M.config.fallbackWindow then
      -- The window sits where the pill does, so the pill steps aside.
      if ui.canvas and state.phase ~= "recording" then ui.canvas:hide() end
      showFallbackWindow(text)
    else
      show(COL.ok, "no text field" .. tag .. " — text is on the clipboard")
      hideLater(2.4)
    end
    if M.config.sound then hs.sound.getByName("Tink"):play() end
    return
  end

  if M.config.sound then hs.sound.getByName("Tink"):play() end
  hideLater(2.4)
end

--------------------------------------------------------------------------------
-- Transcription
--------------------------------------------------------------------------------

--- Everything after the recogniser has answered, whichever one it was: keep
--- the text, decide where it goes, format it when needed, deliver it.
local function handleText(job, text, lang)
  local take = job.take
  -- On disk and on the clipboard before anything else can go wrong.
  keepTranscript(text)
  hs.pasteboard.setContents(text)
  -- Now, not after formatting: four takes later its take-N.wav is reused.
  if take and take.fallback then keepAudio(take, FAILED)
  elseif (M.config.audioDays or 0) > 0 then keepAudio(take, AUDIO) end

  -- Decide where the text is going while the user's window is still in front.
  local canPaste = hasTextFocus()
  local caret = canPaste and caretContext() or nil
  local lastPaste = state.last and state.last.pasted and state.last.pasted:gsub("^%s+", ""):gsub("%s+$", "")
  if caret and lastPaste and lastPaste ~= "" then
    -- Text "after the caret" that is the tail of our own last paste means the
    -- caret is really at the end - Electron's drift again («…о 14:» | «30»).
    local a = caret.after and caret.after:gsub("%s+$", "") or ""
    if a ~= "" and lastPaste:sub(-#a) == a then
      caret.before, caret.after = caret.before .. caret.after, ""
    end
    -- A take straight after our own take in the same field is a sentence of
    -- its own: casual styles drop the full stop, and the next take was read
    -- as its continuation («, перенеси…», 7 of 20 on 2026-10-20). Only the
    -- join sees the stop; the field and its watchers keep the real text.
    local b = caret.before:gsub("%s+$", "")
    if b:sub(-#lastPaste) == lastPaste and not b:match("[%.!?:;]$") then
      caret.joinBefore = b .. "."
    end
  end

  if take then
    take.transcript = state.transcriptName
    take.words = wordCount(text)
    take.delivered = canPaste and "pasted" or (M.config.fallbackWindow and "window" or "clipboard")
  end
  local function done(final, formatted)
    -- The formatter continuing the field sometimes starts with the join mark
    -- itself («. Наприклад…», 2026-10-20 18:13). Nothing dictated starts so.
    final = final:gsub("^%s*[%.,;:]+%s*", "")
    if not formatted then
      final = localStyle(final, styleFor(job.target and job.target:name(), job.screen and job.screen.title))
    end
    final = expandSnippets(final)
    -- The recogniser heard a question; the formatter sometimes drops the mark
    -- along with the full stop a casual style removes. Put it back.
    if text:match("%?%s*$") and not final:match("[%?!]%s*$") and not final:find("\n") then
      final = final:gsub("[%.%s]+$", "") .. "?"
    end
    if take and LEARN then
      local okf, ch, dc = pcall(LEARN.fixes, text, final, dictWordSet())
      if okf then take.fixes = { words = ch, dict = dc } end
    end
    deliver(final, lang, canPaste, caret, text, job.target)
    finishTake(take, "ok")
  end

  local snip = matchSnippet(text)
  if snip then
    if take then take.snippet = snip.cue end
    return done(snip.text)
  end

  -- Command Mode: the take is an instruction for the text selected when it
  -- started. The answer replaces the selection; ⌥⇧Z puts the original back.
  local cmd = job.cmd
  if cmd then
    if take then take.command = true end
    show(COL.busy, "editing the selection…")
    local terms = dictionary()
    local t1 = hs.timer.secondsSinceEpoch()
    return structure(text, nil, function(result, problem, usage, keyInfo)
      if take then
        take.llm = { model = M.config.llm.model, reason = "command", problem = problem,
                     ms = round((hs.timer.secondsSinceEpoch() - t1) * 1000),
                     tokensIn = usage and usage.prompt_tokens, tokensOut = usage and usage.completion_tokens,
                     key = keyInfo and keyInfo.key, keySwitch = keyInfo and keyInfo.keySwitch }
      end
      if problem then
        show(COL.err, problem .. " — selection left as it was")
        hideLater(2.4)
        return finishTake(take, "ok", problem)
      end
      paste(result, nil, true, job.target)
      state.last = { raw = cmd.selected, pasted = state.pasted, caret = cmd.caret,
                     target = job.target, at = hs.timer.secondsSinceEpoch() }
      keepFinal(result)
      if M.config.sound then hs.sound.getByName("Tink"):play() end
      show(COL.ok, "selection edited  ·  ⌥⇧Z puts it back")
      hideLater(2.4)
      finishTake(take, "ok")
    end, {
      system = COMMAND_PROMPT .. (terms and ("\nKnown names and terms, spelled exactly: " .. terms) or ""),
      user = "SELECTED TEXT:\n" .. cmd.selected .. "\n\nINSTRUCTION (dictated):\n" .. text,
      timeout = 12, job = job,
    })
  end

  local cfg = M.config.llm
  local reason = cfg.enabled and formatReason(text, job) or nil
  if reason then
    show(COL.busy, "formatting…")
    local t1 = hs.timer.secondsSinceEpoch()
    structure(text, caret, function(final, problem, usage, keyInfo)
      if take then
        take.llm = { model = cfg.model, reason = reason, ms = round((hs.timer.secondsSinceEpoch() - t1) * 1000),
                     problem = problem,
                     tokensIn = usage and usage.prompt_tokens, tokensOut = usage and usage.completion_tokens,
                     key = keyInfo and keyInfo.key, keySwitch = keyInfo and keyInfo.keySwitch }
      end
      if problem then
        show(COL.err, problem .. " — inserting raw")
        hs.timer.doAfter(1.1, function() done(final) end)
      else
        done(final, true)
      end
    end, { job = job })
  else
    done(text)
  end
end

--- `forceLang` is set only by the Russian retry below, and its presence also
--- marks the second attempt so we never loop.
local function transcribe(forceLang, fallback, job)
  -- job: what this take needs once the key is free for the next one -
  -- { take, target, cmd, screen, wav }, captured when the take stopped.
  if state.phase ~= "recording" then showBars(false) end
  show(COL.busy, fallback and ("retrying on " .. M.config.fallbackEngine .. "…")
              or forceLang and "retrying in Ukrainian…" or "transcribing…")

  local take = job.take
  local engine = fallback and M.config.fallbackEngine or M.config.serverEngine
  local t0 = hs.timer.secondsSinceEpoch()

  -- One retry on the other engine, never more, and never from the fallback.
  local function rescue(reason)
    if fallback or not M.config.fallbackServer then return false end
    logLine(M.config.serverEngine .. " " .. reason .. ", retrying on " .. M.config.fallbackEngine)
    if take then take.fallback = reason end
    transcribe(forceLang, true, job)
    return true
  end

  local args = { "-s", "-X", "POST", fallback and M.config.fallbackServer or M.config.server,
                 "-F", "file=@" .. job.wav,
                 "-F", "model=whisper-1",
                 "-F", "response_format=verbose_json" }
  local lang = forceLang or M.config.language
  if lang then
    table.insert(args, "-F"); table.insert(args, "language=" .. lang)
  end

  local terms = dictionary()
  if terms then
    table.insert(args, "-F"); table.insert(args, "prompt=" .. terms)
  end

  hs.task.new(M.config.curl, function(code, stdout, _)
    if take then take.stt = { engine = engine, ms = round((hs.timer.secondsSinceEpoch() - t0) * 1000) } end

    if code ~= 0 or not stdout or stdout == "" then
      if rescue("down") then return end
      show(COL.err, "transcription server is down")
      hideLater(3)
      return finishTake(take, "server_down", "curl exit " .. tostring(code))
    end

    local ok, body = pcall(hs.json.decode, stdout)
    if not ok or type(body) ~= "table" or not body.text then
      if rescue("bad reply") then return end
      show(COL.err, "could not transcribe")
      hideLater(3)
      local head = (stdout or ""):sub(1, 200)
      while #head > 0 and not utf8.len(head) do head = head:sub(1, -2) end   -- never cut a letter in half
      return finishTake(take, "could_not_transcribe", head)
    end

    if take then
      take.stt.chars = utf8.len(body.text) or #body.text
      take.stt.lang  = body.language
    end
    if runaway(body.text, wavSeconds(job.wav)) then
      if rescue("runaway text") then return end
      show(COL.err, "could not transcribe")
      hideLater(3)
      return finishTake(take, "garbage")
    end

    -- Ukrainian and Russian are close enough that a short take gets misread as
    -- Russian, and then transcribed into words that were never said. The
    -- speaker does not dictate in Russian, so that verdict is always wrong - redo it pinned.
    if body.language == "ru" and not forceLang and M.config.retryLang then
      if take then take.retryLang = M.config.retryLang end
      return transcribe(M.config.retryLang, fallback, job)
    end

    -- Whisper narrates over silence rather than returning nothing, and always
    -- with the same few stock phrases. Trust its own no-speech score instead.
    local speechless = true
    for _, seg in ipairs(body.segments or {}) do
      if (seg.no_speech_prob or 0) < 0.6 then speechless = false end
    end
    if speechless and #(body.segments or {}) > 0 then
      show(COL.err, "no speech")
      hideLater(1.4)
      return finishTake(take, "no_speech")
    end

    local text = body.text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
      show(COL.err, "silence")
      hideLater(1.6)
      return finishTake(take, "silence")
    end

    handleText(job, text, body.language)
  end, args):start()
end

--------------------------------------------------------------------------------
-- Live stream
--------------------------------------------------------------------------------
-- server/live_server.py tails the WAV sox is writing and streams it to Gemini
-- Transcribe Live while the key is held, so after release only the tail and
-- Google's answer are left (~0.4 s). Every call goes through curl in hs.task:
-- the network never blocks Hammerspoon.

local function livePost(path, body, maxTime, callback)
  hs.task.new(M.config.curl, callback or function() end, {
    "-s", "--max-time", tostring(maxTime), "-X", "POST",
    "-H", "content-type: application/json", "-d", hs.json.encode(body),
    M.config.live.server .. path,
  }):start()
end

local function liveCancel(id)
  if id and M.config.live then livePost("/cancel", { id = id }, 2) end
end

--- Opens the stream for the take sox has just started writing. The daemon
--- answers at once and connects to Google in the background; a take left
--- without an id goes to Parakeet when it stops.
local function liveStart(take)
  local live = M.config.live
  if not (live and live.enabled) then return end
  local terms, list = dictionaryList() or {}, {}
  for i = 1, math.min(#terms, 100) do list[i] = terms[i] end
  local body = { wav = state.wav }
  if #list > 0 then body.terms = list end
  livePost("/start", body, 2, function(code, stdout, _)
    local ok, reply = pcall(hs.json.decode, (code == 0 and stdout) or "")
    local id = ok and type(reply) == "table" and type(reply.id) == "string" and reply.id or nil
    if not id then
      local why = code ~= 0 and ("curl exit " .. tostring(code))
               or (ok and type(reply) == "table" and type(reply.error) == "string" and reply.error)
               or "bad reply"
      logLine("live start failed: " .. why)
      if take then take.liveFallback = "start: " .. why end
      return
    end
    -- A take shorter than the round trip is over already.
    if state.take == take and state.phase == "recording" then state.liveId = id else liveCancel(id) end
  end)
end

--- The pill's words while recording: what the stream has heard so far.
--- Self-throttling, like peek().
local function livePartial()
  local id = state.liveId
  if state.phase ~= "recording" or not id or state.partialing then return end
  state.partialing = true
  hs.task.new(M.config.curl, function(code, stdout, _)
    state.partialing = false
    if state.phase ~= "recording" or state.liveId ~= id or code ~= 0 or not stdout then return end
    local ok, body = pcall(hs.json.decode, stdout)
    if ok and type(body) == "table" and type(body.text) == "string" then
      local text = body.text:gsub("%s+", " "):gsub("^%s+", "")
      if text ~= "" then state.preview = text end
    end
  end, { "-s", "--max-time", "1", M.config.live.server .. "/partial?id=" .. id }):start()
end

--- After release: the daemon reads the WAV to its end, closes the stream and
--- waits for the final text. Anything short of a clean answer goes to Parakeet
--- exactly as a take without the stream would.
local function liveStop(job)
  local take, live = job.take, M.config.live
  if state.phase ~= "recording" then showBars(false) end
  show(COL.busy, "finishing…")

  local function fallBack(reason)
    logLine("live " .. reason .. ", falling back to " .. M.config.serverEngine)
    if take then take.liveFallback = reason end
    -- Give sox a moment to flush the WAV header before reading the file.
    hs.timer.doAfter(0.25, function() transcribe(nil, nil, job) end)
  end

  livePost("/stop", { id = job.liveId }, (live.stopTimeout or 3) + 1, function(code, stdout, _)
    if code ~= 0 then return fallBack(code == 28 and "timeout" or ("curl exit " .. tostring(code))) end
    local ok, body = pcall(hs.json.decode, stdout or "")
    if not ok or type(body) ~= "table" then return fallBack("bad reply") end
    if type(body.error) == "string" and body.error ~= "" then return fallBack(body.error) end
    if type(body.text) ~= "string" then return fallBack("no text") end

    local text = body.text:gsub("^%s+", ""):gsub("%s+$", "")
    local lang = type(body.language) == "string" and body.language or nil
    if take then
      take.stt = { engine = "gemini-live", ms = tonumber(body.afterEndMs), setupMs = tonumber(body.setupMs),
                   interim = tonumber(body.interim), lang = lang, chars = utf8.len(text) or #text,
                   key = type(body.key) == "string" and body.key or nil,
                   keySwitch = type(body.keySwitch) == "string" and body.keySwitch or nil }
    end
    if text == "" then
      show(COL.err, "silence")
      hideLater(1.6)
      return finishTake(take, "silence")
    end
    if runaway(text, wavSeconds(job.wav)) then return fallBack("runaway text") end
    job.liveText = true
    handleText(job, text, lang)
  end)
end

--------------------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------------------

local function onSoxOutput(_, _, stderr)
  if not stderr then return true end
  -- sox -S progress meter looks like:  [ -=====|=====- ]
  local meter = stderr:match("%[([^%]]*|[^%]]*)%]$") or stderr:match("%[([^%]]*|[^%]]*)%]")
  if meter then
    -- Opening the input device costs ~0.2s warm and up to 1.5s cold. Until the
    -- first meter line arrives nothing is being recorded, and saying otherwise
    -- would invite the user to speak into a gap.
    if not state.capturing then
      state.capturing = true
      state.startedAt = hs.timer.secondsSinceEpoch()
      if state.take then state.take.openMs = round((state.startedAt - state.pressedAt) * 1000) end
    end
  end
  return true
end

--- The level comes from the WAV sox is writing, not from sox's own VU meter:
--- that one shows nothing below -27 dBFS, and the Studio Display mic at 46%
--- input volume spoke at about -29 (2026-10-20), so the wave lay flat over a
--- good recording. sox writes in 8 KB blocks, about four a second; a smaller
--- --buffer made it drop audio, so the bars hold between blocks instead.
local function readLevel()
  local attrs = hs.fs.attributes(state.wav or WAV)
  local size = attrs and attrs.size or 0
  local from = math.max(state.wavRead or 44, size - 8192)
  if size - from < 64 then return nil end
  from = from - (from - 44) % 2
  local file = io.open(state.wav or WAV, "rb")
  if not file then return nil end
  file:seek("set", from)
  local data = file:read(size - from)
  file:close()
  if not data or #data < 64 then return nil end
  state.wavRead = from + #data
  local sum, n = 0, 0
  for pos = 1, #data - 1, 8 do        -- every fourth sample is plenty for a meter
    local v = string.unpack("<i2", data, pos)
    sum, n = sum + v * v, n + 1
  end
  local rms = math.sqrt(sum / n) / 32768
  return 20 * math.log(math.max(rms, 1e-6), 10)
end

--- Auto-gain in dB: the room's own noise is the bottom of the bar, the
--- loudest recent speech the top, at least 15 dB apart so a silent room is
--- never stretched to full.
local function updateLevel()
  local db = readLevel()
  local now = hs.timer.secondsSinceEpoch()
  if not db then
    if now - state.levelAt > 0.3 then state.level = state.level * 0.7 end
    return
  end
  state.levelAt = now
  state.noise  = math.min(db, (state.noise or db) + 0.3)     -- falls at once, rises slowly
  state.peakDb = math.max(db, (state.peakDb or -40) - 0.6, state.noise + 15)
  local lo = state.noise + 4
  state.level = math.max(0, math.min((db - lo) / (state.peakDb - lo), 1))
  local st = state.levelStats
  if st then st.n = st.n + 1; st.sum = st.sum + db; st.max = math.max(st.max, db) end
end

--- Transcribes whatever has been recorded so far, purely to put words on the
--- panel while the user is still talking. Self-throttling: a pass is skipped
--- while the previous one is still in flight, so a long take does not pile up
--- requests it can never finish. Not while the live stream runs: livePartial
--- has its words.
local function peek()
  if state.phase ~= "recording" or state.peeking or not state.capturing or state.liveId then return end
  state.peeking = true

  hs.execute(("/bin/cp %q %q"):format(state.wav or WAV, PEEK_WAV))

  local args = { "-s", "-X", "POST", M.config.previewServer or M.config.server,
                 "-F", "file=@" .. PEEK_WAV,
                 "-F", "model=whisper-1",
                 "-F", "response_format=json" }
  local terms = dictionary()
  if terms then
    table.insert(args, "-F"); table.insert(args, "prompt=" .. terms)
  end

  hs.task.new(M.config.curl, function(code, stdout, _)
    state.peeking = false
    if state.phase ~= "recording" or code ~= 0 or not stdout then return end
    local ok, body = pcall(hs.json.decode, stdout)
    if ok and type(body) == "table" and type(body.text) == "string" then
      local text = body.text:gsub("%s+", " "):gsub("^%s+", "")
      if text ~= "" and not runaway(text, wavSeconds(PEEK_WAV)) then state.preview = text end
    end
  end, args):start()
end

local function startRecording(mode, quiet)
  if state.phase ~= "idle" then return end
  state.cmd = nil
  if mode == "command" then
    local app = hs.application.frontmostApplication()
    if app then wakeAccessibility(app) end
    local caret = caretContext()
    if not (caret and caret.selected and not caret.selected:match("^%s*$")) then
      show(COL.err, "select some text first, then tap right ⌥")
      hideLater(1.8)
      return
    end
    state.cmd = { selected = caret.selected, caret = caret }
  end
  -- The last paste's field, read once more before this take can change it.
  if state.watch then hs.timer.doAfter(0, function() checkEdits(true) end) end

  hs.fs.mkdir(RUN_DIR)
  state.wavN = (state.wavN or 0) % 4 + 1
  state.wav = RUN_DIR .. "/take-" .. state.wavN .. ".wav"
  os.remove(state.wav)

  state.target    = hs.application.frontmostApplication()
  state.startedAt = hs.timer.secondsSinceEpoch()
  state.level     = 0
  state.levelAt   = 0
  -- The noise floor starts at a quiet room's level instead of the first
  -- reading: taking the first block as "silence" made speech that began at
  -- once the zero of the scale, and the wave stayed flat until the first
  -- pause (2026-10-20, flat from 1.3 to 2.3 s while speaking).
  state.noise, state.peakDb, state.wavRead = -65, nil, 44
  state.pressedAt, state.firstPeek = hs.timer.secondsSinceEpoch(), false
  state.levelStats = { n = 0, sum = 0, max = -120 }
  state.phase     = "recording"
  state.capturing = false
  state.preview   = nil
  state.peeking   = false
  state.liveId, state.partialing = nil, false

  local device, why, shut = resolveMic()
  state.take = {
    at = os.date("%Y-%m-%dT%H:%M:%S"), mic = device, micBy = why, lidClosed = shut,
    app = state.target and state.target:name() or nil,
  }
  wavOf[state.take] = state.wav

  state.recorder = hs.task.new(M.config.sox, function()
    state.recorder = nil
  end, onSoxOutput, {
    "-S", "-t", "coreaudio", device,
    "-c", "1", "-r", "16000", "-b", "16", "-e", "signed-integer",
    state.wav, "trim", "0", tostring(M.config.maxSeconds),
  })
  state.recorder:start()
  liveStart(state.take)

  warmFormatter()
  -- After the microphone is asked for, so reading the window never delays it.
  state.screen = nil
  hs.timer.doAfter(0.6, function() if state.phase == "recording" then gatherScreen() end end)

  -- Started on the key going down, the take may still turn out to be a chord
  -- (right ⌘ + C); the pill waits 150 ms so a shortcut does not flash it.
  local function showPill()
    showBars(true)
    show(COL.busy, state.capturing and "" or "opening the microphone…", true)
  end
  if quiet then
    hs.timer.doAfter(0.15, function() if state.phase == "recording" then showPill() end end)
  else
    showPill()
  end

  if M.config.livePreview then
    state.peeker = hs.timer.doEvery(M.config.previewEvery, peek)
    if M.config.live and M.config.live.enabled then
      state.partials = hs.timer.doEvery(M.config.live.partialEvery or 0.4, livePartial)
    end
  end

  state.ticker = hs.timer.doEvery(0.05, function()
    if state.phase ~= "recording" then return end
    if not state.capturing then return end

    local canvas = overlay()
    canvas[IDX.dot].fillColor = COL.rec
    armWatchdog(45)
    local secs = hs.timer.secondsSinceEpoch() - state.startedAt
    local clock = string.format("%d:%02d", math.floor(secs / 60), math.floor(secs % 60))

    canvas[IDX.status].text = clock
    if state.preview and state.preview ~= "" then
      canvas[IDX.preview].text = state.preview
    end
    updateLevel()
    setBars(state.level)

    -- First words on screen one second in, not at the first two-second tick.
    if M.config.livePreview and not state.firstPeek
       and hs.timer.secondsSinceEpoch() - state.startedAt >= 1 then
      state.firstPeek = true
      peek()
    end
  end)
end

--- Drops the take without transcribing it. Used when the hold key turns out to
--- have been part of a keyboard shortcut.
--- A take started on the key going down that turned into a chord: undo it
--- without a trace - no pill, no journal line.
local function abortRecording()
  if state.phase ~= "recording" then return end
  if state.ticker then state.ticker:stop(); state.ticker = nil end
  if state.peeker then state.peeker:stop(); state.peeker = nil end
  if state.partials then state.partials:stop(); state.partials = nil end
  liveCancel(state.liveId); state.liveId = nil
  if state.recorder then hs.execute("/bin/kill -INT " .. state.recorder:pid()); state.recorder = nil end
  state.phase, state.capturing, state.take, state.cmd = "idle", false, nil, nil
  showBars(false)
  if ui.canvas then ui.canvas:hide() end
end

local function cancelRecording()
  if state.phase ~= "recording" then return end
  if state.ticker then state.ticker:stop(); state.ticker = nil end
  if state.peeker then state.peeker:stop(); state.peeker = nil end
  if state.partials then state.partials:stop(); state.partials = nil end
  liveCancel(state.liveId); state.liveId = nil
  if state.recorder then hs.execute("/bin/kill -INT " .. state.recorder:pid()) end
  state.phase = "idle"
  showBars(false)
  if ui.canvas then ui.canvas:hide() end
  finishTake(state.take, "cancelled")
end

local function stopRecording()
  if state.phase ~= "recording" then return end
  if state.ticker then state.ticker:stop(); state.ticker = nil end
  if state.peeker then state.peeker:stop(); state.peeker = nil end
  if state.partials then state.partials:stop(); state.partials = nil end

  local elapsed = state.capturing
    and (hs.timer.secondsSinceEpoch() - state.startedAt) or 0

  -- What the meter saw, in dBFS RMS. Measured 2026-10-20 on whole takes: the
  -- closed MacBook mic -96, speech on the Studio Display mic -42 at 46% input
  -- volume and -31 at 87.5%.
  local take = state.take
  if take then
    take.seconds = round(elapsed, 1)
    local st = state.levelStats
    if st and st.n > 0 then
      take.meanDb, take.maxDb = round(st.sum / st.n, 1), round(st.max, 1)
    end
  end

  if state.recorder then
    hs.execute("/bin/kill -INT " .. state.recorder:pid())
  end

  if elapsed < M.config.minSeconds then
    state.phase = "idle"
    showBars(false)
    show(COL.err, "too short")
    hideLater(1.2)
    liveCancel(state.liveId); state.liveId = nil
    -- Never capturing means sox did not get the microphone open at all.
    return finishTake(take, state.capturing and "too_short" or "mic_not_open")
  end

  -- Everything the rest of this take needs, captured now: the key is free for
  -- the next take from here on.
  local job = { take = take, target = state.target, cmd = state.cmd,
                screen = state.screen, wav = state.wav }
  job.liveId = state.liveId; state.liveId = nil
  state.cmd = nil
  state.phase = "idle"
  state.busy = (state.busy or 0) + 1
  if take then inFlight[take] = true end
  if job.liveId then return liveStop(job) end
  -- Give sox a moment to flush the WAV header before reading the file.
  hs.timer.doAfter(0.25, function() transcribe(nil, nil, job) end)
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

--- Rebuilds the pill in the named theme and runs the preview, for choosing.
function M.previewTheme(name)
  applyTheme(name or M.config.theme)
  if ui.canvas then ui.canvas:delete(); ui.canvas = nil end
  return M.preview()
end

--- Every dictation, newest first, grouped by day; a click copies the text.
--- This is the answer to "it did not paste, where is my text" - the same
--- files the tool has been writing all along, on one screen.
local function readTranscripts()
  local items = {}
  -- hs.fs.dir returns iterator + state; wrapping it in `or` dropped the state
  local ok, iter, dirobj = pcall(hs.fs.dir, LOG_DIR)
  if not ok or not iter then return items end
  for name in iter, dirobj do
    local y, mo, d, h, mi, sec = name:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)_(%d%d)%-(%d%d)%-(%d%d)%.txt$")
    if y then
      local f = io.open(LOG_DIR .. "/" .. name, "r")
      local text = f and f:read("*a") or ""
      if f then f:close() end
      text = text:gsub("^%s+", ""):gsub("%s+$", "")
      if text ~= "" then
        items[#items + 1] = { day = y .. "-" .. mo .. "-" .. d, time = h .. ":" .. mi, key = name, text = text }
      end
    end
  end
  table.sort(items, function(a, b) return a.key > b.key end)
  -- The journal knows which audio file belongs to which transcript; audio is
  -- named by when the take started, the transcript by when it was saved.
  local audioOf = {}
  local jf = io.open(TAKES, "r")
  if jf then
    for line in jf:lines() do
      local okj, r = pcall(hs.json.decode, line)
      if okj and type(r) == "table" and r.transcript and r.audio then audioOf[r.transcript] = r.audio end
    end
    jf:close()
  end
  for _, it in ipairs(items) do
    local a = audioOf[it.key:gsub("%.txt$", "")]
    if a and hs.fs.attributes(RUN_DIR .. "/" .. a) then it.audio = RUN_DIR .. "/" .. a end
  end
  return items
end

local function dayLabel(day)
  local today = os.date("%Y-%m-%d")
  local yesterday = os.date("%Y-%m-%d", os.time() - 86400)
  if day == today then return "Today" elseif day == yesterday then return "Yesterday" end
  return day
end

--- Reads dictionary.txt into a comment header and a list of terms, so an edit
--- from the window can write the file back without eating the instructions at
--- the top of it.
local function readDictionary()
  local header, terms = {}, {}
  local file = io.open(DICT, "r")
  if not file then return header, terms end
  local seenTerm = false
  for line in file:lines() do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed:match("^#") or trimmed == "" then
      if not seenTerm then header[#header + 1] = line end
    else
      seenTerm = true
      terms[#terms + 1] = trimmed
    end
  end
  file:close()
  table.sort(terms, function(a, b) return a:lower() < b:lower() end)
  return header, terms
end

local function writeDictionary(header, terms)
  table.sort(terms, function(a, b) return a:lower() < b:lower() end)
  local file = io.open(DICT, "w")
  if not file then return false end
  for _, line in ipairs(header) do file:write(line, "\n") end
  if #header > 0 then file:write("\n") end
  for _, t in ipairs(terms) do file:write(t, "\n") end
  file:close()
  return true
end
local appView

--- One window, three sections, a sidebar to switch them. Both sections are rendered up front and toggled in the page, so
--- switching costs nothing and neither list is rebuilt.
function M.app(section)
  -- The old window may already be gone (closed from outside); never let that
  -- stop a new one from opening.
  if appView then pcall(function() appView:delete() end); appView = nil end

  local items = readTranscripts()
  local header, terms = readDictionary()

  local function historyRows()
    local rows, lastDay = {}, nil
    for i, it in ipairs(items) do
      if it.day ~= lastDay then
        if lastDay then rows[#rows + 1] = '</div>' end
        local age = tostring(daysAgo(it.day))
        rows[#rows + 1] = '<h2 data-age="' .. age .. '">' .. dayLabel(it.day)
          .. '</h2><div class="card" data-age="' .. age .. '">'
        lastDay = it.day
      end
      rows[#rows + 1] = string.format(
        '<div class="row" data-i="%d"><span class="t">%s</span><div class="x">%s</div>'
        .. '<div class="acts">%s<button class="c">Copy</button></div></div>',
        i, it.time, (escapeHTML(it.text):gsub("\n", "<br>")),
        it.audio and '<button class="p" title="Play the recording">&#9654;</button>' or "")
    end
    if lastDay then rows[#rows + 1] = '</div>' end
    if #rows == 0 then rows[1] = '<p class="empty">Nothing dictated yet.</p>' end
    return table.concat(rows, "\n")
  end

  local snips = loadSnippets()
  local function snipRows()
    local rows = {}
    for i, sn in ipairs(snips) do
      rows[#rows + 1] = string.format(
        '<div class="trow" data-i="%d"><div class="x"><span class="cue">%s</span> <span class="ms">→ %s</span></div>'
        .. '<button class="del" title="Remove">&times;</button></div>',
        i, escapeHTML(sn.cue or ""), (escapeHTML(sn.text or ""):gsub("\n", " ⏎ ")))
    end
    if #rows == 0 then rows[1] = '<p class="empty">No snippets yet.</p>' end
    return table.concat(rows, "\n")
  end
  local function refreshSnips()
    hs.timer.doAfter(0, function()
      if not appView then return end
      pcall(function()
        appView:evaluateJavaScript("document.getElementById('snips').innerHTML = "
          .. hs.json.encode({ snipRows() }) .. "[0];")
      end)
    end)
  end

  local sugg = loadSuggestions()
  local function suggRows()
    if #sugg.items == 0 then return "" end
    local rows = { '<h2>Suggested from your edits</h2><div class="card">' }
    for i, it in ipairs(sugg.items) do
      local from = {}
      for _, f in ipairs(it.from or {}) do from[#from + 1] = "«" .. escapeHTML(f) .. "»" end
      rows[#rows + 1] = string.format(
        '<div class="trow srow" data-i="%d"><div class="x">%s <span class="ms">← %s%s</span></div>'
        .. '<div><button class="sadd" data-op="add">Add</button>'
        .. '<button class="del sdrop" data-op="drop" title="Dismiss">&times;</button></div></div>',
        i, escapeHTML(it.term), table.concat(from, ", "),
        (it.count or 1) > 1 and (" · ×" .. it.count) or "")
    end
    rows[#rows + 1] = '</div><h2>Terms</h2>'
    return table.concat(rows, "\n")
  end

  local function termRows()
    local rows = {}
    for i, t in ipairs(terms) do
      rows[#rows + 1] = string.format(
        '<div class="trow" data-i="%d"><div class="x">%s</div><button class="del" title="Remove">&times;</button></div>',
        i, escapeHTML(t))
    end
    if #rows == 0 then rows[1] = '<p class="empty">No terms yet.</p>' end
    return table.concat(rows, "\n")
  end

  -- Rows of the microphone section, in the order they are drawn; the page
  -- sends back an index into this, so names never pass through HTML attributes.
  local micList = {}

  local function styleBox()
    local cur, rows = loadStyles(), {}
    for _, k in ipairs(STYLE_KINDS) do
      local chips = {}
      for _, lvl in ipairs(STYLE_LEVELS) do
        chips[#chips + 1] = string.format('<button class="schip%s" data-k="%s" data-v="%s">%s</button>',
          (cur[k.id] or "formal") == lvl and " on" or "", k.id, lvl, lvl:sub(1, 1):upper() .. lvl:sub(2))
      end
      rows[#rows + 1] = '<div class="mrow"><span class="mt">' .. k.label
        .. '<br><span class="ms">' .. k.apps .. '</span></span>'
        .. table.concat(chips) .. '</div>'
    end
    return table.concat(rows, "\n")
  end

  local function micBox()
    local mic, devices = loadMic(), inputDevices()
    syncRanking(mic, devices)
    local byName = {}
    for _, d in ipairs(devices) do byName[d.name] = d end
    local inUse = resolveMic()
    local shut = lidClosed()
    micList = {}

    local function row(name, title, sub, opts)
      micList[#micList + 1] = name
      local i = #micList
      local cls = "mrow" .. ((mic.choice == name) and " on" or "") .. (opts.off and " off" or "")
      local tools = ""
      if opts.rank then
        tools = '<button class="mb" data-op="up" title="Move up">&uarr;</button>'
             .. '<button class="mb" data-op="down" title="Move down">&darr;</button>'
             .. (opts.off and '<button class="mb del" data-op="forget" title="Forget">&times;</button>' or "")
      end
      return string.format(
        '<div class="%s" data-i="%d"><span class="radio"></span>%s<div class="mt"><div>%s</div><div class="ms">%s</div></div>%s</div>',
        cls, i, opts.n and ('<span class="n">' .. opts.n .. '</span>') or "", escapeHTML(title), sub, tools)
    end

    local out = {}
    out[#out + 1] = '<div class="card">' .. row("auto", "Auto-detect",
      "Highest connected mic in the ranking &middot; now: " .. escapeHTML(inUse == "default" and "system default" or inUse),
      {}) .. '</div>'

    out[#out + 1] = '<h2>Ranking</h2><p class="note">Auto-detect takes the first connected mic from the top.'
      .. ' The MacBook microphone is skipped while the lid is closed: it records silence then.</p><div class="card">'
    for n, name in ipairs(mic.ranking) do
      local d = byName[name]
      local sub
      if not d then sub = "Not connected"
      else
        sub = (d.transport == "UNKNOWN") and "iPhone or other" or d.transport
        if shut and d.transport == "Built-in" then sub = sub .. " &middot; lid closed" end
        if d.transport:match("^Bluetooth") then sub = sub .. " &middot; slow to start, more mistakes" end
      end
      out[#out + 1] = row(name, name, sub, { n = n, rank = true, off = not d })
    end
    if #mic.ranking == 0 then out[#out + 1] = '<p class="empty">No microphones found.</p>' end
    out[#out + 1] = '</div>'

    local virtual = {}
    for _, d in ipairs(devices) do
      if d.virtual then virtual[#virtual + 1] = row(d.name, d.name, "Virtual &middot; only when chosen", {}) end
    end
    if #virtual > 0 then
      out[#out + 1] = '<h2>Other devices</h2><div class="card">' .. table.concat(virtual) .. '</div>'
    end
    return table.concat(out, "\n")
  end

  local html = [==[
<meta charset="utf-8">
<style>
  * { box-sizing: border-box; margin: 0; }
  html, body { height: 100%; background: #f5f5f5; color: #111111;
    font: 14px/1.55 -apple-system, BlinkMacSystemFont, "Inter", sans-serif; }
  /* The OS window frame cannot be coloured, so the outline is drawn on the
     content edge. macOS rounds the bottom corners of the window, so the
     border follows the same radius there or it gets clipped and looks uneven. */
  body { display: flex; border: 1.5px solid #111111; border-radius: 0 0 12px 12px; overflow: hidden; }

  aside { width: 190px; flex: none; padding: 18px 10px; display: flex; flex-direction: column; gap: 3px; }
  .brand { padding: 0 10px 18px; font-weight: 600; font-size: 20px; line-height: 1;
    letter-spacing: -0.02em; }
  .nav { display: flex; align-items: center; gap: 10px; padding: 8px 10px; border-radius: 10px;
    color: #111111; cursor: pointer; border: 0; background: transparent; font: inherit;
    width: 100%; text-align: left; }
  .nav:hover { background: #e5e5e5; }
  .nav.on { background: #111111; color: #ffffff; font-weight: 600; }
  .nav.on svg { stroke: #ffffff; }
  .nav svg { width: 15px; height: 15px; stroke: #111111; fill: none; stroke-width: 1.8; flex: none; }

  .pane { flex: 1; background: #ffffff; border-left: 1px solid #e5e5e5;
    border-radius: 12px 0 12px 0; overflow-y: auto; }
  .inner { padding: 24px 28px 28px; }
  .top { display: flex; align-items: center; gap: 12px; margin-bottom: 16px; }
  h1 { font-size: 24px; font-weight: 600; letter-spacing: -0.01em; flex: none; }
  .top { margin-bottom: 20px; }
  .search { flex: 1; display: flex; align-items: center; gap: 8px; background: #f5f5f5;
    border: 1px solid #e5e5e5; border-radius: 10px; padding: 7px 12px; }
  .search:focus-within { border-color: #111111; }
  .search svg { width: 14px; height: 14px; stroke: #737373; fill: none; stroke-width: 2; }
  .search input { flex: 1; font: inherit; border: 0; outline: none; background: transparent; }
  .primary { font: inherit; font-size: 13px; font-weight: 600; border: 0; border-radius: 10px;
    padding: 8px 18px; background: #111111; color: #ffffff; cursor: pointer; flex: none; }
  .primary:hover { background: #444444; }

  .tabs { display: flex; align-items: center; border-bottom: 1px solid #e5e5e5; margin-bottom: 18px; }
  .chip { font: inherit; font-size: 15px; padding: 10px 2px 11px; margin-right: 24px; border: 0;
    border-bottom: 2px solid transparent; margin-bottom: -1px; background: transparent;
    color: #737373; cursor: pointer; }
  .chip:hover { color: #111111; }
  .chip.on { color: #111111; border-bottom-color: #111111; font-weight: 600; }
  .tabs .search { margin-left: auto; max-width: 240px; padding: 5px 10px; margin-bottom: 6px; }

  h2 { font-size: 11px; font-weight: 600; letter-spacing: .14em; text-transform: uppercase;
    color: #737373; margin: 16px 0 8px 4px; }
  .card { border: 1px solid #e5e5e5; border-radius: 12px; overflow: hidden; }
  .row, .trow { border-top: 1px solid #e5e5e5; display: grid; }
  .row { grid-template-columns: 68px 1fr auto; gap: 14px; align-items: start;
    padding: 14px 16px; cursor: pointer; }
  .trow { grid-template-columns: 1fr auto; gap: 12px; align-items: center; padding: 11px 16px; }
  .row:first-child, .trow:first-child { border-top: 0; }
  .row:hover, .trow:hover { background: #f5f5f5; }
  .row.hide { display: none; }
  .t { color: #737373; font-size: 13px; font-variant-numeric: tabular-nums; padding-top: 2px; }
  .x { white-space: pre-wrap; -webkit-user-select: text; user-select: text; }
  .c { visibility: hidden; align-self: center; border: 0; border-radius: 10px; padding: 6px 14px;
    font: inherit; font-size: 12px; font-weight: 600; background: #111111; color: #ffffff; cursor: pointer; }
  .row:hover .c { visibility: visible; }
  .acts { display: flex; gap: 6px; align-self: center; }
  .p { visibility: hidden; border: 0; border-radius: 10px; padding: 6px 10px; font: inherit;
    font-size: 11px; background: #ebebeb; color: #111111; cursor: pointer; }
  .row:hover .p, .p.on { visibility: visible; }
  .p.on { background: #111111; color: #ffffff; }
  .c.done { background: #ebebeb; color: #111111; }
  .del { visibility: hidden; border: 0; background: transparent; color: #737373;
    font-size: 20px; line-height: 1; cursor: pointer; padding: 0 4px; }
  .trow:hover .del { visibility: visible; }
  .del:hover { color: #111111; }
  .note { color: #737373; font-size: 12px; margin-bottom: 14px; }
  .srow .del { visibility: visible; }
  .sadd { border: 0; border-radius: 10px; padding: 5px 12px; margin-right: 6px; font: inherit;
    font-size: 12px; font-weight: 600; background: #111111; color: #ffffff; cursor: pointer; }
  .sadd:hover { background: #444444; }
  .addrow { margin-bottom: 14px; }
  .snipform { display: grid; gap: 8px; margin-bottom: 14px; }
  .snipform textarea { font: inherit; border: 1px solid #e5e5e5; border-radius: 10px; padding: 8px 12px;
    background: #f5f5f5; resize: vertical; outline: none; }
  .snipform textarea:focus { border-color: #111111; }
  .snipform .primary { justify-self: start; }
  .cue { font-weight: 600; }
  .utabs { display: flex; gap: 24px; border-bottom: 1px solid #e5e5e5; margin-bottom: 20px; }
  .utab { font: inherit; font-size: 15px; padding: 8px 2px 10px; border: 0; background: transparent;
    color: #737373; cursor: pointer; border-bottom: 2px solid transparent; margin-bottom: -1px; }
  .utab:hover { color: #111111; }
  .utab.on { color: #111111; border-bottom-color: #111111; font-weight: 600; }
  .upanel { display: none; } .upanel.on { display: block; }
  .ins3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px; margin-bottom: 14px; }
  .icard { border: 1px solid #e5e5e5; border-radius: 14px; padding: 18px 20px; background: #ffffff; }
  .icard.wide { margin-bottom: 14px; }
  .ibig { font-size: 36px; font-weight: 600; letter-spacing: -0.02em; line-height: 1.1; }
  .ilab { color: #737373; font-size: 11px; font-weight: 600; letter-spacing: .14em; text-transform: uppercase; margin-top: 4px; }
  .irule { border-top: 1px solid #e5e5e5; margin: 14px 0 10px; }
  .iline { font-size: 14px; margin-top: 6px; }
  .gauge { width: 150px; margin-top: 10px; display: block; }
  .gt { font-size: 11px; fill: #737373; }
  .ihead { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 14px; }
  .ihead h3 { font-size: 22px; font-weight: 600; margin: 0; }
  .ihead span { font-size: 11px; font-weight: 600; letter-spacing: .14em; text-transform: uppercase; }
  .bar { display: grid; grid-template-columns: 260px 1fr; gap: 14px; align-items: center; margin: 8px 0; }
  .track { height: 28px; }
  .fill { height: 28px; background: #111111; border-radius: 6px; display: flex; align-items: center;
    justify-content: center; color: #ffffff; font-size: 12px; font-weight: 600; min-width: 34px; }
  .blab { font-size: 12px; font-weight: 600; letter-spacing: .12em; text-transform: uppercase; }
  .sq24 .sqrow, .sq24 .sqlabels { display: grid; grid-template-columns: repeat(24, 22px); gap: 3px; }
  .sq24 .sqrow i { width: 22px; height: 22px; border-radius: 4px; }
  .sqlabels { font-size: 10px; color: #737373; margin-bottom: 4px; }
  .sq7 { display: flex; gap: 10px; }
  .dcell { display: flex; flex-direction: column; align-items: center; gap: 6px; font-size: 11px; color: #737373; }
  .dcell i { width: 54px; height: 54px; border-radius: 8px; }
  .cal { display: grid; grid-template-columns: repeat(7, 44px); gap: 5px; }
  .cal .wd { font-size: 11px; color: #737373; text-align: center; }
  .cal i { width: 44px; height: 36px; border-radius: 6px; font-style: normal; font-size: 12px;
    display: flex; align-items: flex-start; justify-content: flex-end; padding: 3px 5px; box-sizing: border-box; }
  .cal i.l3, .cal i.l4 { color: #ffffff; }
  .cal i.now { outline: 2px solid #111111; }
  #utip { position: fixed; pointer-events: none; display: none; z-index: 10; background: #111111;
    color: #ffffff; font-size: 12px; padding: 6px 9px; border-radius: 8px; white-space: nowrap; }
  [data-tip]:hover { outline: 1px solid #111111; }
  .heatwrap { margin-bottom: 14px; }
  .hmonths { display: grid; grid-auto-flow: column; grid-auto-columns: 11px; font-size: 10px;
    color: #737373; height: 14px; white-space: nowrap; }
  .heat { display: grid; grid-auto-flow: column; grid-template-rows: repeat(7, 9px);
    grid-auto-columns: 9px; gap: 2px; }
  .heat i, .hlegend i { width: 9px; height: 9px; border-radius: 2px; display: inline-block; }
  .sq24 i, .dcell i, .cal i { display: inline-block; }
  .l0 { background: #e5e5e5; } .l1 { background: #c9c9c9; } .l2 { background: #9a9a9a; }
  .l3 { background: #5c5c5c; } .l4 { background: #111111; }
  .hlegend { font-size: 11px; color: #737373; margin-top: 8px; display: flex; gap: 3px; align-items: center; }
  .schip { font: inherit; font-size: 14px; padding: 8px 2px 9px; margin-left: 20px; border: 0;
    border-bottom: 2px solid transparent; background: transparent; color: #737373; cursor: pointer; }
  .schip:hover { color: #111111; }
  .schip.on { color: #111111; border-bottom-color: #111111; font-weight: 600; }
  .empty { color: #737373; padding: 34px 0; text-align: center; }
  .section { display: none; }
  .section.on { display: block; }
  .card + h2 { margin-top: 22px; }
  .mrow { border-top: 1px solid #e5e5e5; display: flex; align-items: center; gap: 12px;
    padding: 11px 16px; cursor: pointer; }
  .mrow:first-child { border-top: 0; }
  .mrow:hover { background: #f5f5f5; }
  .mrow.off { color: #737373; cursor: default; }
  .radio { width: 16px; height: 16px; border-radius: 50%; border: 1.5px solid #111111; flex: none; }
  .mrow.on .radio { background: #111111; box-shadow: inset 0 0 0 3px #ffffff; }
  .mrow .n { color: #737373; font-size: 13px; width: 14px; font-variant-numeric: tabular-nums; }
  .mt { flex: 1; }
  .ms { color: #737373; font-size: 12px; }
  .mb { visibility: hidden; border: 0; background: transparent; color: #737373; font-size: 16px;
    line-height: 1; cursor: pointer; padding: 2px 5px; border-radius: 6px; }
  .mrow:hover .mb { visibility: visible; }
  .mb:hover { color: #111111; background: #e5e5e5; }
  .mb.del:hover { color: #111111; }
</style>

<aside>
  <div class="brand">Pysar;</div>
  <button class="nav __NAV_H__" data-s="history">
    <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>
    History
  </button>
  <button class="nav __NAV_D__" data-s="dictionary">
    <svg viewBox="0 0 24 24"><path d="M4 5a2 2 0 012-2h13v18H6a2 2 0 01-2-2z"/><path d="M8 7h7M8 11h7"/></svg>
    Dictionary
  </button>
  <button class="nav __NAV_U__" data-s="usage">
    <svg viewBox="0 0 24 24"><path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/></svg>
    Usage
  </button>
  <button class="nav __NAV_N__" data-s="snippets">
    <svg viewBox="0 0 24 24"><path d="M5 4h14v16H5z"/><path d="M9 9h6M9 13h4"/></svg>
    Snippets
  </button>
  <button class="nav __NAV_S__" data-s="settings">
    <svg viewBox="0 0 24 24"><path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2"/><circle cx="8" cy="17" r="2"/></svg>
    Settings
  </button>
</aside>

<div class="pane"><div class="inner">
  <div class="section __NAV_H__" id="history">
    <div class="top"><h1>History</h1></div>
    <nav class="tabs">
      <button class="chip on" data-min="0" data-max="0">Today</button>
      <button class="chip" data-min="1" data-max="1">Yesterday</button>
      <button class="chip" data-min="0" data-max="6">7 days</button>
      <button class="chip" data-min="0" data-max="__KEEP_MAX__">__KEEP__ days</button>
      <label class="search">
        <svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/></svg>
        <input id="q" placeholder="Search">
      </label>
    </nav>
    <div id="rows">__ROWS__</div>
    <p class="empty" id="none" style="display:none">Nothing matches.</p>
  </div>

  <div class="section __NAV_D__" id="dictionary">
    <div class="top">
      <h1>Dictionary</h1>
      <span style="flex:1"></span>
      <button class="primary" id="addbtn">Add new</button>
    </div>
    <p class="note">Names and terms the recogniser would otherwise mangle. Used when formatting every take.</p>
    <form class="search addrow" id="f">
      <input id="term" placeholder="Type a name or term and press Return" autocomplete="off">
    </form>
    <div id="sugg">__SUGG__</div>
    <div class="card" id="terms">__TERMS__</div>
  </div>

  <div class="section __NAV_U__" id="usage">
    <div class="top"><h1>Usage</h1></div>
    __USAGE__
  </div>

  <div class="section __NAV_N__" id="snippets">
    <div class="top"><h1>Snippets</h1></div>
    <p class="note">Say the cue anywhere in a take and the text goes in its place. Several spellings: separate them with |.</p>
    <form id="sf" class="snipform">
      <label class="search"><input id="cue" placeholder="Cue, e.g. мій імейл | мій мейл" autocomplete="off"></label>
      <textarea id="stext" rows="3" placeholder="Text to insert"></textarea>
      <button class="primary" type="submit">Add snippet</button>
    </form>
    <div class="card" id="snips">__SNIPS__</div>
  </div>

  <div class="section __NAV_S__" id="settings">
    <div class="top"><h1>Settings</h1></div>
    <h2>Microphone</h2>
    <div id="mic">__MIC__</div>
    <h2>Style</h2>
    <p class="note">Capitals and punctuation per kind of app. Words are never changed.</p>
    <div class="card" id="style">__STYLE__</div>
  </div>
</div></div>

<script>
  function send(m) { window.webkit.messageHandlers.pysar.postMessage(m); }

  document.querySelectorAll('.nav').forEach(function (b) {
    b.addEventListener('click', function () {
      document.querySelectorAll('.nav').forEach(function (o) { o.classList.remove('on'); });
      b.classList.add('on');
      document.querySelectorAll('.section').forEach(function (s) {
        s.classList.toggle('on', s.id === b.dataset.s);
      });
      var f = { history: 'q', dictionary: 'term', snippets: 'cue' }[b.dataset.s];
      if (f) document.getElementById(f).focus();
    });
  });

  var minAge = 0, maxAge = 0;
  function apply() {
    var q = document.getElementById('q').value.toLowerCase(), shown = 0;
    document.querySelectorAll('.card[data-age]').forEach(function (c) {
      var age = parseInt(c.dataset.age, 10);
      var stale = age < minAge || age > maxAge, any = false;
      c.querySelectorAll('.row').forEach(function (r) {
        var miss = q && r.querySelector('.x').textContent.toLowerCase().indexOf(q) < 0;
        var hide = stale || miss;
        r.classList.toggle('hide', hide);
        if (!hide) { any = true; shown++; }
      });
      c.style.display = any ? '' : 'none';
      c.previousElementSibling.style.display = any ? '' : 'none';
    });
    document.getElementById('none').style.display = shown ? 'none' : '';
  }
  document.getElementById('q').addEventListener('input', apply);
  document.querySelectorAll('.chip').forEach(function (b) {
    b.addEventListener('click', function () {
      document.querySelectorAll('.chip').forEach(function (o) { o.classList.remove('on'); });
      b.classList.add('on');
      minAge = parseInt(b.dataset.min, 10);
      maxAge = parseInt(b.dataset.max, 10);
      apply();
    });
  });
  document.getElementById('rows').addEventListener('click', function (e) {
    var r = e.target.closest('.row');
    if (!r) return;
    if (e.target.closest('.p')) {
      var p = e.target.closest('.p'), on = !p.classList.contains('on');
      document.querySelectorAll('.p.on').forEach(function (o) { o.classList.remove('on'); o.innerHTML = '&#9654;'; });
      if (on) { p.classList.add('on'); p.innerHTML = '&#9632;'; }
      send((on ? 'play:' : 'stop:') + r.dataset.i);
      return;
    }
    send('copy:' + r.dataset.i);
    var b = r.querySelector('.c');
    b.textContent = 'Copied'; b.classList.add('done');
    setTimeout(function () { b.textContent = 'Copy'; b.classList.remove('done'); }, 1200);
  });

  function addTerm() {
    var i = document.getElementById('term'), v = i.value.trim();
    if (v) { send('add:' + v); i.value = ''; }
  }
  document.getElementById('f').addEventListener('submit', function (e) { e.preventDefault(); addTerm(); });
  document.getElementById('addbtn').addEventListener('click', function () {
    var i = document.getElementById('term');
    if (i.value.trim()) addTerm(); else i.focus();
  });
  document.getElementById('sugg').addEventListener('click', function (e) {
    var b = e.target.closest('[data-op]');
    if (b) send('sugg:' + b.dataset.op + ':' + b.closest('.srow').dataset.i);
  });
  document.getElementById('sf').addEventListener('submit', function (e) {
    e.preventDefault();
    var c = document.getElementById('cue'), t = document.getElementById('stext');
    if (c.value.trim() && t.value.trim()) {
      send('snip-add:' + JSON.stringify({ cue: c.value.trim(), text: t.value }));
      c.value = ''; t.value = ''; c.focus();
    }
  });
  document.getElementById('snips').addEventListener('click', function (e) {
    if (e.target.classList.contains('del')) send('snip-del:' + e.target.closest('.trow').dataset.i);
  });
  document.getElementById('terms').addEventListener('click', function (e) {
    if (e.target.classList.contains('del')) send('remove:' + e.target.parentElement.dataset.i);
  });

  // Native title tooltips do not show in this window, so draw our own.
  var tip = document.createElement('div'); tip.id = 'utip'; document.body.appendChild(tip);
  document.getElementById('usage').addEventListener('mousemove', function (e) {
    var c = e.target.closest('[data-tip]');
    if (!c) { tip.style.display = 'none'; return; }
    tip.textContent = c.dataset.tip; tip.style.display = 'block';
    var x = e.clientX + 12, y = e.clientY + 14;
    if (x + tip.offsetWidth > window.innerWidth - 8) x = e.clientX - tip.offsetWidth - 12;
    tip.style.left = x + 'px'; tip.style.top = y + 'px';
  });
  document.getElementById('usage').addEventListener('mouseleave', function () { tip.style.display = 'none'; });
  document.getElementById('usage').addEventListener('click', function (e) {
    var b = e.target.closest('.utab');
    if (!b) return;
    document.querySelectorAll('.utab').forEach(function (o) { o.classList.toggle('on', o === b); });
    document.querySelectorAll('.upanel').forEach(function (p) { p.classList.toggle('on', p.id === b.dataset.p); });
  });
  document.getElementById('style').addEventListener('click', function (e) {
    var b = e.target.closest('.schip');
    if (!b) return;
    b.parentElement.querySelectorAll('.schip').forEach(function (o) { o.classList.remove('on'); });
    b.classList.add('on');
    send('style:' + b.dataset.k + ':' + b.dataset.v);
  });
  document.getElementById('mic').addEventListener('click', function (e) {
    var r = e.target.closest('.mrow');
    if (!r) return;
    var b = e.target.closest('.mb');
    if (b) send('mic:' + b.dataset.op + ':' + r.dataset.i);
    else if (!r.classList.contains('off')) send('mic:pick:' + r.dataset.i);
  });

  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') send('close'); });
  apply();
</script>]==]

  -- Called from inside the page's message handler. WKWebView will not always
  -- run script re-entrantly from there, so the update is pushed to the next
  -- turn of the loop, and any failure is printed rather than swallowed.
  local function refreshTerms()
    hs.timer.doAfter(0, function()
      if not appView then return end
      local ok, err = pcall(function()
        -- hs.json.encode takes a table, not a string: ship the HTML as [html]
        appView:evaluateJavaScript(
          "document.getElementById('terms').innerHTML = " .. hs.json.encode({ termRows() }) .. "[0];"
          .. "document.getElementById('sugg').innerHTML = " .. hs.json.encode({ suggRows() }) .. "[0];",
          -- the second argument is a table even on success; only a real
          -- message is worth a log line
          function(_, jsErr)
            local msg = type(jsErr) == "table" and (jsErr.message or jsErr.localizedDescription) or jsErr
            if type(msg) == "string" and msg ~= "" then logLine("dictionary refresh js error: " .. msg) end
          end)
      end)
      if not ok then logLine("dictionary refresh failed: " .. tostring(err)) end
    end)
  end

  local function refreshMic()
    hs.timer.doAfter(0, function()
      if not appView then return end
      local ok, err = pcall(function()
        appView:evaluateJavaScript(
          "document.getElementById('mic').innerHTML = " .. hs.json.encode({ micBox() }) .. "[0];",
          function(_, jsErr)
            local msg = type(jsErr) == "table" and (jsErr.message or jsErr.localizedDescription) or jsErr
            if type(msg) == "string" and msg ~= "" then logLine("microphone refresh js error: " .. msg) end
          end)
      end)
      if not ok then logLine("microphone refresh failed: " .. tostring(err)) end
    end)
  end
  M.refreshSettings = refreshMic

  -- Pick, move or forget, by index into micList. Moving swaps with the
  -- neighbour in the ranking; a virtual device has no place there to move.
  local function micAction(op, i)
    local name = micList[i]
    if not name then return end
    local mic = loadMic()
    if op == "pick" then
      mic.choice = name
    else
      local at
      for k, n in ipairs(mic.ranking) do if n == name then at = k end end
      if not at then return end
      if op == "up" and at > 1 then
        mic.ranking[at], mic.ranking[at - 1] = mic.ranking[at - 1], mic.ranking[at]
      elseif op == "down" and at < #mic.ranking then
        mic.ranking[at], mic.ranking[at + 1] = mic.ranking[at + 1], mic.ranking[at]
      elseif op == "forget" then
        table.remove(mic.ranking, at)
        if mic.choice == name then mic.choice = "auto" end
      end
    end
    saveMic(mic)
    refreshMic()
  end

  local controller = hs.webview.usercontent.new("pysar")
  controller:setCallback(function(message)
    local body = tostring(message.body)
    local copy = body:match("^copy:(%d+)$")
    local term = body:match("^add:(.+)$")
    local drop = body:match("^remove:(%d+)$")
    local micOp, micI = body:match("^mic:(%a+):(%d+)$")
    local sOp, sI = body:match("^sugg:(%a+):(%d+)$")
    local playI = body:match("^play:(%d+)$")
    local styleK, styleV = body:match("^style:(%a+):(.+)$")
    if styleK then
      local t = loadStyles(); t[styleK] = styleV; saveStyles(t)
      return
    end
    local snipAdd = body:match("^snip%-add:(.+)$")
    local snipDel = body:match("^snip%-del:(%d+)$")
    if snipAdd then
      local okd, sn = pcall(hs.json.decode, snipAdd)
      if okd and type(sn) == "table" and sn.cue and sn.text then
        snips[#snips + 1] = { cue = sn.cue, text = sn.text }
        saveSnippets(snips); refreshSnips()
      end
    elseif snipDel and snips[tonumber(snipDel)] then
      table.remove(snips, tonumber(snipDel))
      saveSnippets(snips); refreshSnips()
    elseif playI or body:match("^stop:") then
      -- afplay rather than hs.sound: NSSound stayed silent on sox's 16 kHz WAVs.
      if M._sound and M._sound:isRunning() then M._sound:terminate() end
      M._sound = nil
      local it = playI and items[tonumber(playI)]
      if it and it.audio then
        logLine("play: " .. it.audio)
        M._sound = hs.task.new("/usr/bin/afplay", function()
          if appView then
            pcall(function()
              appView:evaluateJavaScript("document.querySelectorAll('.p.on').forEach(function (o) "
                .. "{ o.classList.remove('on'); o.innerHTML = '&#9654;'; });")
            end)
          end
        end, { it.audio })
        M._sound:start()
      end
    elseif sOp and sugg.items[tonumber(sI)] then
      local it = table.remove(sugg.items, tonumber(sI))
      if sOp == "add" then
        local dup = false
        for _, t in ipairs(terms) do if t:lower() == it.term:lower() then dup = true end end
        if not dup then terms[#terms + 1] = it.term; writeDictionary(header, terms) end
      else
        sugg.dismissed[LEARN and LEARN.lower(it.term) or it.term:lower()] = true
      end
      saveSuggestions(sugg)
      refreshTerms()
      if M.refreshMenu then M.refreshMenu() end
    elseif micOp then
      micAction(micOp, tonumber(micI))
    elseif copy and items[tonumber(copy)] then
      hs.pasteboard.setContents(items[tonumber(copy)].text)
    elseif term then
      term = term:gsub("^%s+", ""):gsub("%s+$", "")
      local dup = false
      for _, t in ipairs(terms) do if t:lower() == term:lower() then dup = true end end
      if term ~= "" and not dup then
        terms[#terms + 1] = term
        writeDictionary(header, terms)
        refreshTerms()
      end
    elseif drop then
      table.remove(terms, tonumber(drop))
      writeDictionary(header, terms)
      refreshTerms()
    elseif body == "close" and appView then
      if M._sound and M._sound:isRunning() then M._sound:terminate() end
      M._sound = nil
      appView:delete(); appView = nil; M.refreshSettings = nil
    end
  end)

  local keep = M.config.transcriptDays
  local frame = hs.screen.mainScreen():frame()
  local W_, H_ = 1040, 760
  appView = hs.webview.new({
    x = frame.x + (frame.w - W_) / 2, y = frame.y + (frame.h - H_) / 2, w = W_, h = H_,
  }, {}, controller)
  appView:windowStyle({ "titled", "closable", "resizable" })
  appView:windowTitle("Pysar")
  appView:level(hs.drawing.windowLevels.floating)
  appView:allowTextEntry(true)
  local dict = (section == "dictionary")
  local sets = (section == "settings")
  local snp = (section == "snippets")
  local use = (section == "usage")
  appView:html((html
    :gsub("__ROWS__", function() return historyRows() end)
    :gsub("__TERMS__", function() return termRows() end)
    :gsub("__SUGG__", function() return suggRows() end)
    :gsub("__MIC__", function() return micBox() end)
    :gsub("__SNIPS__", function() return snipRows() end)
    :gsub("__STYLE__", function() return styleBox() end)
    :gsub("__KEEP_MAX__", tostring(keep - 1))
    :gsub("__KEEP__", tostring(keep))
    :gsub("__USAGE__", function() return usageBox() end)
    :gsub("__NAV_U__", use and "on" or "")
    :gsub("__NAV_H__", (dict or sets or snp or use) and "" or "on")
    :gsub("__NAV_N__", snp and "on" or "")
    :gsub("__NAV_D__", dict and "on" or "")
    :gsub("__NAV_S__", sets and "on" or "")))
  appView:show()
  appView:hswindow():focus()
  M._app = appView

  return #items, #terms
end

function M.history() return M.app("history") end
function M.dictionary() return M.app("dictionary") end
function M.settings() return M.app("settings") end
function M.snippets() return M.app("snippets") end
function M.usage() return M.app("usage") end

--- Runs the overlay through every state without touching the microphone.
--- Handy for checking the visuals and for debugging after a config change.
function M.preview()
  showBars(true)
  show(COL.rec, "0:03")
  local step = 0
  local t = hs.timer.doEvery(0.09, function()
    step = step + 1
    setBars(0.35 + 0.45 * math.abs(math.sin(step / 3)))
  end)
  hs.timer.doAfter(2.4, function()
    t:stop(); showBars(false)
    show(COL.busy, "transcribing…")
  end)
  hs.timer.doAfter(3.6, function()
    show(COL.ok, "→ Notion · UK  «Pysar overlay check»")
    hideLater(2.2)
  end)
  return overlay()
end

--- Records for a few seconds through the real capture path, then reports what
--- landed on disk. Proves the microphone permission and sox wiring without
--- needing the hotkey.
function M.testRecord(seconds)
  seconds = seconds or 4
  startRecording()
  M._recTimer = hs.timer.doAfter(seconds, function()
    stopRecording()
    M._statTimer = hs.timer.doAfter(1.0, function()
      local out, ok = hs.execute("/opt/homebrew/bin/sox " .. (state.wav or WAV) .. " -n stat 2>&1")
      print("──── pysar record test ────")
      print(out or "no output")
      print("──── end ────")
    end)
  end)
  return ("recording %ds"):format(seconds)
end

--- Runs a WAV through the real transcribe -> format -> deliver chain, skipping
--- only the microphone. Everything downstream is the production path.
function M.testTranscribe(wavPath)
  if wavPath then
    hs.fs.mkdir(RUN_DIR)
    hs.execute(("/bin/cp %q %q"):format(wavPath, WAV))
  end
  state.target = hs.application.frontmostApplication()
  state.phase  = "idle"
  transcribe(nil, nil, { target = state.target, wav = WAV })
  return "running - watch the overlay"
end

--- Sends one sample through the formatter and prints both sides to the console.
--- Checks the key, endpoint, model and prompt without touching the microphone.
function M.testFormat(text)
  text = text or
    "так давай по пунктах перше треба зробити воркфлоу для онбордингу друге "
    .. "переписати лендінг і третє це поговорити з командою про деплоймент в "
    .. "пятницю і ще я хочу щоб ми подивились на фідбек від користувачів бо "
    .. "там є кілька речей які нас дуже здивували"

  print("──── pysar formatter test ────")
  print("IN:  " .. text)
  structure(text, nil, function(result, problem)
    if problem then
      print("ERR: " .. problem)
    else
      print("OUT: " .. result)
    end
    print("──── end ────")
  end)
  return "sent — watch the Hammerspoon console"
end

--- Prints what the paste decision sees for the frontmost app. Run it from the
--- console with the cursor where dictation would go.
--- Pure joining logic, for the harness.
function M.fitToCaret(text, before) return fitToCaret(text, { before = before, after = "" }) end
function M.caretContext() return caretContext() end
function M.microphone() return resolveMic() end

function M.whatIsFocused()
  local app = hs.application.frontmostApplication()
  if app then wakeAccessibility(app) end
  local el = focusedElement()
  local function g(k)
    if not el then return "-" end
    local ok, v = pcall(function() return el:attributeValue(k) end)
    return ok and tostring(v) or "?"
  end
  local settable = el and select(2, pcall(function() return el:isAttributeSettable("AXValue") end))
  local line = string.format("%s | role=%s sub=%s desc=%s valueSettable=%s -> %s",
    app and app:name() or "?", g("AXRole"), g("AXSubrole"), g("AXRoleDescription"),
    tostring(settable), hasTextFocus() and "PASTE" or "WINDOW")
  print(line)
  return line
end

--- Shows the no-text-field window with sample text, for checking the layout.
function M.previewWindow(text)
  showFallbackWindow(text or
    "This is the window that appears when nothing on screen can take the text. "
    .. "The transcript is already on the clipboard.\n\n- first bullet\n- second bullet\n\n"
    .. "Українські слова лишаються кирилицею, English terms stay in Latin script.")
  return fallback.view
end

--- Prints what each key on the keyboard actually emits. Run it, press the key
--- with the microphone glyph, and read the Hammerspoon console.
function M.probe(seconds)
  seconds = seconds or 10
  local seen = {}

  M._probeTap = hs.eventtap.new({
    hs.eventtap.event.types.keyDown,
    hs.eventtap.event.types.systemDefined,
  }, function(event)
    if event:getType() == hs.eventtap.event.types.systemDefined then
      local key = event:systemKey()
      if key and key.key then
        seen[#seen + 1] = ("systemDefined  key=%s  down=%s")
          :format(tostring(key.key), tostring(key.down))
      end
    else
      local code = event:getKeyCode()
      seen[#seen + 1] = ("keyDown        code=%s  name=%s")
        :format(tostring(code), tostring(hs.keycodes.map[code]))
    end
    return false
  end)
  M._probeTap:start()

  M._probeTimer = hs.timer.doAfter(seconds, function()
    M._probeTap:stop()
    print("──── pysar probe: " .. #seen .. " events ────")
    for _, line in ipairs(seen) do print(line) end
    print("──── end ────")
  end)

  return ("probing for %ds — press the microphone key now"):format(seconds)
end

-- Menu bar icon: an ink ring at rest, a solid ink disc while recording, a
-- grey disc while transcribing or formatting.
local function stateIcon(phase)
  local c = hs.canvas.new({ x = 0, y = 0, w = 18, h = 18 })
  local fill = (phase == "recording") and hex("111111")
            or (phase == "transcribing") and hex("9a9a9a")
            or { alpha = 0 }
  c:appendElements({ type = "circle", action = "strokeAndFill", center = { x = 9, y = 9 }, radius = 6,
    fillColor = fill, strokeColor = hex("111111"), strokeWidth = 1.6 })
  local img = c:imageFromCanvas()
  c:delete()
  return img
end

--- The microphone submenu: the mic in use, Auto-detect, then every ranked mic.
--- Disconnected ones stay in the list, greyed, as in the ranking.
local function micMenu()
  local mic, devices = loadMic(), inputDevices()
  syncRanking(mic, devices)
  local byName = {}
  for _, d in ipairs(devices) do byName[d.name] = d end
  local inUse = resolveMic()
  local shut = lidClosed()

  local function pick(choice)
    return function()
      local m = loadMic(); m.choice = choice; saveMic(m)
      if M.refreshSettings then M.refreshSettings() end
    end
  end

  local items = {
    { title = "Mic in use: " .. (inUse == "default" and "system default" or inUse), disabled = true },
    { title = "-" },
    { title = "Auto-detect", checked = mic.choice == "auto", fn = pick("auto") },
    { title = "-" },
  }
  for _, name in ipairs(mic.ranking) do
    local d = byName[name]
    local note = not d and " — not connected"
              or (shut and d.transport == "Built-in") and " — lid closed"
              or ""
    items[#items + 1] = { title = name .. note, checked = mic.choice == name,
                          disabled = not d, fn = pick(name) }
  end
  for _, d in ipairs(devices) do
    if d.virtual then
      items[#items + 1] = { title = d.name .. " (virtual)", checked = mic.choice == d.name, fn = pick(d.name) }
    end
  end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Edit ranking…", fn = function() M.settings() end }
  return items
end

--- The tool has no window of its own, so this is the only way to tell whether
--- it is alive and what it is doing.
local function refreshMenu()
  if not M._menu then return end
  M._menu:setIcon(stateIcon(state.phase == "idle" and (state.busy or 0) > 0 and "transcribing" or state.phase), false)

  local items = {
    { title = "Pysar — " .. state.phase, disabled = true },
    { title = "-" },
    { title = "Right ⌘: press to start, press to stop", disabled = true },
    { title = "⌥⇧Space does the same", disabled = true },
    { title = "-" },
  }

  if M.lastTranscript then
    local preview = M.lastTranscript:gsub("%s+", " "):sub(1, 40)
    items[#items + 1] = {
      title = "Copy last: «" .. preview .. "…»",
      fn = function() hs.pasteboard.setContents(M.lastTranscript) end,
    }
  else
    items[#items + 1] = { title = "Nothing dictated yet", disabled = true }
  end

  items[#items + 1] = {
    title = "Undo formatting of the last take  ⌥⇧Z",
    disabled = not state.last,
    fn = function() M.undoFormatting() end,
  }
  items[#items + 1] = { title = "History…", fn = function() M.history() end }
  local pending = #loadSuggestions().items
  items[#items + 1] = { title = pending > 0 and ("Dictionary… · " .. pending .. " suggested") or "Dictionary…",
                        fn = function() M.dictionary() end }
  items[#items + 1] = { title = "Usage…", fn = function() M.usage() end }
  items[#items + 1] = { title = "Snippets…", fn = function() M.snippets() end }
  items[#items + 1] = { title = "Settings…", fn = function() M.settings() end }
  items[#items + 1] = {
    title = "Open transcript folder",
    fn = function() hs.execute("/usr/bin/open " .. LOG_DIR) end,
  }
  items[#items + 1] = { title = "-" }
  items[#items + 1] = {
    title = "Formatting",
    checked = M.config.llm.enabled,
    fn = function()
      M.config.llm.enabled = not M.config.llm.enabled
      refreshMenu()
    end,
  }
  items[#items + 1] = { title = "Microphone", menu = {} }
  local micItem = #items
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Reload", fn = function() hs.reload() end }
  items[#items + 1] = { title = "Quit Pysar", fn = function() hs.application.get("Hammerspoon"):kill() end }

  -- Built when the menu opens, so a closed lid or a mic plugged in since the
  -- last refresh shows up without a watcher of its own.
  M._menu:setMenu(function()
    items[micItem].menu = micMenu()
    return items
  end)
end

--- Panic button. Stops whatever is running and clears the screen.
--- Puts the raw transcript where the formatted one was pasted. Selects the
--- pasted span through Accessibility when the field still holds it as pasted;
--- otherwise asks the app to undo its own paste (⌘Z) and pastes over that.
function M.undoFormatting()
  local last = state.last
  if not last or hs.timer.secondsSinceEpoch() - last.at > 600 then
    show(COL.err, "nothing to undo"); hideLater(1.2); return
  end
  local rawFitted = M.config.smartSpacing and fitToCaret(last.raw, last.caret) or last.raw
  if rawFitted == last.pasted then
    show(COL.ok, "this take was pasted as said"); hideLater(1.4); return
  end
  local selected = false
  local c = last.caret
  -- Multi-line text is where Electron's caret offsets drift (see caretContext):
  -- selecting by position there could hit the wrong span, so let ⌘Z do it.
  if c and c.el and c.before and not c.before:find("\n", 1, true) then
    pcall(function()
      local value = c.el:attributeValue("AXValue")
      if type(value) == "string" and value:sub(1, #c.before) == c.before
         and value:sub(#c.before + 1, #c.before + #last.pasted) == last.pasted then
        c.el:setAttributeValue("AXSelectedTextRange",
          { location = utf8.len(c.before), length = utf8.len(last.pasted) })
        selected = true
      end
    end)
  end
  if last.target then last.target:activate() end
  if not selected then hs.eventtap.keyStroke({ "cmd" }, 6, 0) end   -- keycode 6 = Z
  hs.timer.doAfter(0.12, function()
    paste(last.raw, c)
    last.pasted = state.pasted
    logLine("undo formatting: raw text put back (" .. (selected and "selected" or "cmd-z") .. ")")
    show(COL.ok, "raw text put back"); hideLater(1.4)
  end)
end

--- The pill's ✓: finish the take as a second key press would.
function M.finish()
  if state.phase == "recording" then stopRecording() end
end

function M.dismiss()
  if state.ticker   then state.ticker:stop();   state.ticker = nil end
  if state.peeker   then state.peeker:stop();   state.peeker = nil end
  if state.partials then state.partials:stop(); state.partials = nil end
  if state.watchdog then state.watchdog:stop(); state.watchdog = nil end
  liveCancel(state.liveId); state.liveId = nil
  if state.recorder then
    hs.execute("/bin/kill -INT " .. state.recorder:pid())
    state.recorder = nil
  end
  if state.phase ~= "idle" then finishTake(state.take, "dismissed", state.phase) end
  state.phase, state.capturing = "idle", false
  if ui.canvas then ui.canvas:hide() end
  closeFallback()
  if M.refreshMenu then M.refreshMenu() end
  return "dismissed"
end

function M.start(overrides)
  for k, v in pairs(overrides or {}) do M.config[k] = v end

  applyTheme(M.config.theme)

  -- Hammerspoon's own hammer says nothing about Pysar; ours says everything.
  hs.menuIcon(false)
  M._menu = hs.menubar.new()
  M.refreshMenu = refreshMenu
  M.micMenu = micMenu
  refreshMenu()

  pruneTranscripts()

  -- Carry the last take across restarts so "Copy last" is not empty after a
  -- reboot; the files are right there.
  local newest
  local ok, iter, dirobj = pcall(hs.fs.dir, LOG_DIR)
  if ok and iter then
    for name in iter, dirobj do
      if name:match("^%d%d%d%d%-%d%d%-%d%d_%d%d%-%d%d%-%d%d%.txt$")
         and (not newest or name > newest) then
        newest = name
      end
    end
  end
  if newest then
    local file = io.open(LOG_DIR .. "/" .. newest, "r")
    if file then
      local text = file:read("*a"); file:close()
      text = text:gsub("^%s+", ""):gsub("%s+$", "")
      if text ~= "" then M.lastTranscript = text end
    end
  end

  -- The API key and request bodies live here, so keep the directory private.
  hs.execute(("/bin/mkdir -p %s && /bin/chmod 700 %s"):format(RUN_DIR, RUN_DIR))

  -- A mic plugged in or out while Settings is open shows up there at once.
  hs.audiodevice.watcher.setCallback(function(event)
    if event == "dev#" and M.refreshSettings then M.refreshSettings() end
  end)
  hs.audiodevice.watcher.start()

  hs.hotkey.bind(M.config.toggle.mods, M.config.toggle.key, function()
    if state.phase == "recording" then stopRecording() else startRecording() end
  end)
  if M.config.undoKey then
    hs.hotkey.bind(M.config.undoKey.mods, M.config.undoKey.key, function() M.undoFormatting() end)
  end

  -- Taps on bare modifiers: the dictation key, and the Command Mode key.
  -- hs.hotkey cannot bind one, so watch the flag changes directly and track
  -- whether the key was used as a chord (⌥ + a letter types ґ and the like).
  local modes = { [M.config.holdKey] = "dictate" }
  if M.config.commandKey then modes[M.config.commandKey] = "command" end
  local held, chorded, started = {}, {}, {}

  -- Escape gets the screen back, but only while something of ours is showing.
  -- A hotkey binding would swallow it everywhere, so pass it through instead.
  M._escTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    if event:getKeyCode() ~= 53 then return false end
    if state.phase ~= "idle" or (ui.canvas and ui.canvas:isShowing()) then
      M.dismiss()
      return true
    end
    return false
  end)
  M._escTap:start()

  M._holdTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged },
    function(event)
      local kc = event:getKeyCode()
      local mode = modes[kc]
      if not mode then return false end

      -- A modifier is "down" when its own flag is still set on the change.
      local flags = event:getFlags()
      local down = (mode == "command" and flags.alt) or (mode ~= "command"
        and (flags.cmd or flags.alt or flags.shift or flags.ctrl)) or false

      if down and not held[kc] then
        held[kc], chorded[kc], started[kc] = true, false, false
        -- Start on the way down: people start talking as they press, and
        -- waiting for the release cut the first syllable off 13 of 15 test
        -- takes (2026-10-20). A chord undoes it, see the keyDown tap.
        if state.phase == "idle" then
          startRecording(mode, true)
          started[kc] = state.phase == "recording"
        end
      elseif not down and held[kc] then
        held[kc] = false
        -- A clean press (no other key while it was down) toggles the take:
        -- a take this press started keeps going, a running one stops.
        if not chorded[kc] then
          if started[kc] then
            started[kc] = false
          elseif state.phase == "recording" then
            stopRecording()
          end
        end
      end
      return false
    end)
  M._holdTap:start()

  M._chordTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown },
    function()
      for kc, h in pairs(held) do
        if h then
          chorded[kc] = true
          if started[kc] then started[kc] = false; abortRecording() end
        end
      end
      return false
    end)
  M._chordTap:start()

  -- On a MacBook the microphone key may arrive as a system-defined event rather
  -- than an F5 keycode, depending on the function-key setting. Swallowing it
  -- also keeps macOS Dictation from firing alongside us.
  if M.config.micKey then
    M._micTap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined },
      function(event)
        local key = event:systemKey()
        if not key or not key.key then return false end
        if not M.config.micKeyNames[key.key] then return false end
        if key.down then startRecording() else stopRecording() end
        return true
      end)
    M._micTap:start()
  end

  return M
end

return M
