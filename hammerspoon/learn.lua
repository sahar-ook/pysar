--- Learning from edits: after a
--- take is pasted, the field is read again, the pasted words are aligned with
--- what is there now, and an isolated word the user replaced becomes a
--- dictionary suggestion. Pure Lua, no Hammerspoon, so it can be tested with
--- plain `lua hammerspoon/learn_test.lua`.
---
--- Only corrections that look like a name or a term are kept: the new form has
--- a Latin letter, a capital or a hyphen, and it sounds like what was replaced
--- (compared after transliteration). Rewrites, added sentences and grammar
--- fixes inside Ukrainian words are ignored.

local L = {}

-- Cyrillic lower case: А-Я, Ѐ-Џ (Є І Ї live there), Ґ.
local function lowerCp(cp)
  if cp >= 0x41 and cp <= 0x5A then return cp + 32 end
  if cp >= 0x410 and cp <= 0x42F then return cp + 0x20 end
  if cp >= 0x400 and cp <= 0x40F then return cp + 0x50 end
  if cp == 0x490 then return 0x491 end
  return cp
end

local function lower(s)
  local out = {}
  for _, cp in utf8.codes(s) do out[#out + 1] = utf8.char(lowerCp(cp)) end
  return table.concat(out)
end

local TRANSLIT = {
  ["а"] = "a", ["б"] = "b", ["в"] = "v", ["г"] = "h", ["ґ"] = "g", ["д"] = "d",
  ["е"] = "e", ["є"] = "ye", ["ж"] = "zh", ["з"] = "z", ["и"] = "y", ["і"] = "i",
  ["ї"] = "yi", ["й"] = "y", ["к"] = "k", ["л"] = "l", ["м"] = "m", ["н"] = "n",
  ["о"] = "o", ["п"] = "p", ["р"] = "r", ["с"] = "s", ["т"] = "t", ["у"] = "u",
  ["ф"] = "f", ["х"] = "kh", ["ц"] = "ts", ["ч"] = "ch", ["ш"] = "sh",
  ["щ"] = "shch", ["ь"] = "", ["ю"] = "yu", ["я"] = "ya", ["ы"] = "y",
  ["э"] = "e", ["ъ"] = "", ["ё"] = "yo", ["'"] = "", ["’"] = "",
}

--- A rough sound of the word in Latin letters: transliterated, then folded so
--- spelling differences that sound alike compare equal (c/k/q, w/v, y/i, ph/f).
local function sound(s)
  local out = {}
  for _, cp in utf8.codes(lower(s)) do
    local ch = utf8.char(cp)
    out[#out + 1] = TRANSLIT[ch] or (ch:match("[%a%d]") and ch) or ""
  end
  local t = table.concat(out)
  t = t:gsub("ph", "f"):gsub("[cq]", "k"):gsub("w", "v"):gsub("x", "ks"):gsub("y", "i")
  return t
end

local function levenshtein(a, b)
  if a == b then return 0 end
  local la, lb = #a, #b
  if la == 0 then return lb end
  if lb == 0 then return la end
  local prev, cur = {}, {}
  for j = 0, lb do prev[j] = j end
  for i = 1, la do
    cur[0] = i
    local ca = a:byte(i)
    for j = 1, lb do
      local cost = (ca == b:byte(j)) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev, cur = cur, prev
  end
  return prev[lb]
end

--- 0..1, how alike two spellings sound.
function L.similarity(a, b)
  local sa, sb = sound(a), sound(b)
  local n = math.max(#sa, #sb)
  if n == 0 then return 0 end
  return 1 - levenshtein(sa, sb) / n
end

--- Words with their surrounding punctuation stripped for comparison; the
--- original token is kept so a suggestion keeps the user's own spelling.
-- Punctuation that may hug a word. Multi-byte marks cannot go in a Lua
-- character class (it matches bytes, and would eat half a Cyrillic letter),
-- so the edges are trimmed one code point at a time.
local EDGE = {}
for _, ch in ipairs({ "«", "»", "“", "”", "„", "—", "–", "…", "’" }) do EDGE[utf8.codepoint(ch)] = true end
local function isEdge(cp) return EDGE[cp] or (cp < 128 and string.char(cp):match("%p") ~= nil) end

local function trimPunct(tok)
  local cps = {}
  for _, cp in utf8.codes(tok) do cps[#cps + 1] = cp end
  local i, j = 1, #cps
  while i <= j and isEdge(cps[i]) do i = i + 1 end
  while j >= i and isEdge(cps[j]) do j = j - 1 end
  return utf8.char(table.unpack(cps, i, j))
end

local function tokens(s)
  local out = {}
  for tok in s:gmatch("%S+") do
    local bare = utf8.len(tok) and trimPunct(tok) or tok
    if bare ~= "" then out[#out + 1] = { word = bare, key = lower(bare) } end
  end
  return out
end

local function termLike(s)
  return s:match("[A-Za-z]") or s:match("%-") or s:match("^[A-Z]")
      or s:match("^[\208][\128-\175]")   -- capital Cyrillic first letter (U+0400-042F)
end

local function join(list, i, j)
  local w = {}
  for k = i, j do w[#w + 1] = list[k].word end
  return table.concat(w, " ")
end

--- Pairs { from = what was pasted, to = what the user made of it }.
--- `pasted` is the exact text Pysar inserted; `after` is the field's text from
--- the paste point on (the caller cuts off the text that was there before).
function L.corrections(pasted, after, opts)
  opts = opts or {}
  local minSim = opts.minSimilarity or 0.45
  local P = tokens(pasted)
  if #P == 0 then return {} end
  local C = tokens(after)
  -- Only the stretch the paste can occupy: as many words again plus a margin.
  while #C > #P * 2 + 10 do table.remove(C) end

  -- Longest common subsequence on the comparison keys.
  local n, m = #P, #C
  local dp = {}
  for i = 0, n do dp[i] = {}; for j = 0, m do dp[i][j] = 0 end end
  for i = n - 1, 0, -1 do
    for j = m - 1, 0, -1 do
      if P[i + 1].key == C[j + 1].key then dp[i][j] = dp[i + 1][j + 1] + 1
      else dp[i][j] = math.max(dp[i + 1][j], dp[i][j + 1]) end
    end
  end
  local anchors, i, j = {}, 0, 0
  while i < n and j < m do
    if P[i + 1].key == C[j + 1].key then
      anchors[#anchors + 1] = { i + 1, j + 1 }; i, j = i + 1, j + 1
    elseif dp[i + 1][j] >= dp[i][j + 1] then i = i + 1
    else j = j + 1 end
  end
  -- Most of the take must still be there, or this was a rewrite, not a fix.
  if #anchors < math.max(1, math.floor(n * 0.6)) then return {} end

  local found = {}
  local function consider(pi, pj, ci, cj)
    local pn, cn = pj - pi + 1, cj - ci + 1
    if pn < 1 or pn > 2 or cn < 1 or cn > 3 then return end
    local from, to = join(P, pi, pj), join(C, ci, cj)
    if from == to or not termLike(to) then return end
    if lower(from) ~= lower(to) and L.similarity(from, to) < minSim then return end
    found[#found + 1] = { from = from, to = to }
  end

  local lastP, lastC = 0, 0
  for _, a in ipairs(anchors) do
    consider(lastP + 1, a[1] - 1, lastC + 1, a[2] - 1)
    lastP, lastC = a[1], a[2]
  end
  -- After the last anchor the field may run on with older text, so take only
  -- as many words as were pasted there.
  if lastP < n then
    local pn = n - lastP
    consider(lastP + 1, n, lastC + 1, math.min(m, lastC + pn))
  end
  return found
end

--------------------------------------------------------------------------------
-- Names on screen
--------------------------------------------------------------------------------

local function isUpperFirst(word)
  local cp = utf8.codepoint(word, 1)
  return lowerCp(cp) ~= cp
end

--- A word that reads as part of a name or a term: a capital first letter, or a
--- lower-case Latin word with a dot, a digit or a capital inside (z.ai, iOS).
--- Plain lower-case English ("the", "setup") is not a name.
local function nameLike(word)
  if utf8.len(word) < 2 or word:match("^%d+$") then return false end
  if isUpperFirst(word) then return true end
  return word:match("[A-Za-z]") ~= nil and (word:match("[%.%d]") or word:match(".[A-Z]")) ~= nil
end

--- A capital that may only mean "first word of a sentence". Acronyms and
--- words with a dot, digit or inner capital (MCP, z.ai, iOS) are names anywhere.
local function plainCapital(word)
  return not (word:match("^%u%u+$") or word:match("[%.%d]") or word:match(".%u"))
end

--- Names and terms out of the visible texts of a window, most frequent
--- first: runs of up to three name-like words ("Bluebird Design Studio"),
--- skipping what `known` (lower-cased dictionary) already has. A lone
--- capitalised word that only ever opens a sentence or a label ("Зараз",
--- "Add") is not counted unless it also turns up mid-sentence.
function L.names(texts, known, limit)
  known, limit = known or {}, limit or 40
  local count, order, mid = {}, {}, {}
  local function add(run)
    -- "Hi Marta", "Вчора Тарас": a sentence opener glued to a name. Drop the
    -- opener, unless the run is the whole text - a label like a project name.
    if run.start and not run.whole and #run.words > 1 and plainCapital(run.words[1]) then
      table.remove(run.words, 1)
      run.start = false
    end
    local phrase = table.concat(run.words, " ")
    if #run.words == 1 and run.start and plainCapital(phrase) then
      run.words = {}; return            -- judged at the end, by `mid`
    end
    if #run.words == 1 then mid[phrase] = true end
    local low = lower(phrase)
    if known[low] or utf8.len(phrase) > 40 then return end
    if not count[phrase] then count[phrase] = 0; order[#order + 1] = phrase end
    count[phrase] = count[phrase] + 1
  end
  for _, text in ipairs(texts) do
    if type(text) == "string" and utf8.len(text) then
      local run, atStart = { words = {} }, true
      local total, idx = 0, 0
      for _ in text:gmatch("%S+") do total = total + 1 end
      local function flush()
        if #run.words > 0 then
          run.whole = run.first == 1 and idx >= total and #run.words == total
          add(run)
        end
        run = { words = {} }
      end
      for tok in text:gmatch("%S+") do
        idx = idx + 1
        local bare = trimPunct(tok)
        local ends = tok ~= bare and tok:match("[%.!?:;]$")
        if bare ~= "" and nameLike(bare) then
          if #run.words == 3 then flush() end
          if #run.words == 0 then run.start, run.first = atStart, idx end
          run.words[#run.words + 1] = bare
        else
          flush()
        end
        if bare ~= "" then atStart = false end
        if ends or tok:match(",$") then flush() end
        if ends then atStart = true end
      end
      flush()
    end
  end
  local out = {}
  table.sort(order, function(a, b)
    if count[a] ~= count[b] then return count[a] > count[b] end
    return #a > #b
  end)
  for _, phrase in ipairs(order) do
    if #out >= limit then break end
    out[#out + 1] = phrase
  end
  return out
end

--------------------------------------------------------------------------------
-- Fixes made by the formatter, for the Usage section
--------------------------------------------------------------------------------

--- How many words of `final` are not what the recogniser wrote in `raw`
--- (case and punctuation aside), and how many of those are dictionary words
--- that were not in `raw` at all. `dictWords` is a set of lower-cased words.
function L.fixes(raw, final, dictWords)
  local R, F = tokens(raw or ""), tokens(final or "")
  local n, m = #R, #F
  if m == 0 then return 0, 0 end
  local dp = {}
  for i = 0, n do dp[i] = {}; for j = 0, m do dp[i][j] = 0 end end
  for i = n - 1, 0, -1 do
    for j = m - 1, 0, -1 do
      if R[i + 1].key == F[j + 1].key then dp[i][j] = dp[i + 1][j + 1] + 1
      else dp[i][j] = math.max(dp[i + 1][j], dp[i][j + 1]) end
    end
  end
  local matched, i, j = {}, 0, 0
  while i < n and j < m do
    if R[i + 1].key == F[j + 1].key then matched[j + 1] = true; i, j = i + 1, j + 1
    elseif dp[i + 1][j] >= dp[i][j + 1] then i = i + 1
    else j = j + 1 end
  end
  local inRaw = {}
  for _, t in ipairs(R) do inRaw[t.key] = true end
  local changed, dict = 0, 0
  for k = 1, m do
    if not matched[k] then
      changed = changed + 1
      local key = F[k].key
      if dictWords and dictWords[key] and not inRaw[key] then dict = dict + 1 end
    end
  end
  return changed, dict
end

L.lower = lower
return L
