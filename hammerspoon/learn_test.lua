-- lua hammerspoon/learn_test.lua  (from the repo root)
package.path = "hammerspoon/?.lua;" .. package.path
local L = require("learn")

local function show(list)
  local out = {}
  for _, c in ipairs(list) do out[#out + 1] = c.from .. " -> " .. c.to end
  return table.concat(out, "; ")
end

local cases = {
  -- pasted, field text from the paste point on, expected suggestions
  { "Скажу тобі щось дуже складне про Мспі, сервери і МДФайл.",
    "Скажу тобі щось дуже складне про MCP, сервери і МДФайл.", "Мспі -> MCP" },
  { "Окей, давай спробуємо про MD file.",
    "Окей, давай спробуємо про MD-файл.", "MD file -> MD-файл" },
  { "Я відкриваю лінеар кожен день і ще ноушн.",
    "Я відкриваю Linear кожен день і ще ноушн.", "лінеар -> Linear" },
  { "Додай це в писар сьогодні.",
    "Додай це в Pysar сьогодні.", "писар -> Pysar" },
  -- not suggestions:
  { "Я хочу бачити імейли цих юзорів.",
    "Я хочу бачити імейли цих юзерів.", "" },                 -- grammar, not a term
  { "Давай зробимо це завтра зранку.",
    "Ні, краще відкладемо все на наступний тиждень.", "" },  -- rewrite
  { "Додай задачу на понеділок.",
    "Додай задачу на понеділок. І ще одну на вівторок, Figma.", "" },  -- text added after
  { "Зустріч з командою о третій.",
    "Зустріч з Notion о третій.", "" },                     -- different word, not a fix
}

local fails = 0
for i, c in ipairs(cases) do
  local got = show(L.corrections(c[1], c[2]))
  local ok = got == c[3]
  if not ok then fails = fails + 1 end
  print(string.format("%s %d  expected [%s]  got [%s]", ok and "ok  " or "FAIL", i, c[3], got))
end
-- names on screen
local names = L.names({
  "Re: Invoice for Bluebird Design Studio",
  "Hi Marta, the Supabase project is ready. Check MCP setup in Brightline.",
  "Вчора Тарас написав, що Lumen Plus перенесла запис.",
  "ok", "12345", "Inbox",
}, { ["supabase"] = true })
local got = table.concat(names, " | ")
for _, want in ipairs({ "Bluebird Design Studio", "MCP", "Brightline", "Lumen Plus", "Тарас", "Marta" }) do
  local ok = got:find(want, 1, true) ~= nil
  if not ok then fails = fails + 1 end
  print(string.format("%s names has %-22s", ok and "ok  " or "FAIL", want))
end
local leaked = got:find("Supabase", 1, true) ~= nil
if leaked then fails = fails + 1 end
print((leaked and "FAIL" or "ok  ") .. " names skips terms already in the dictionary")
for _, noise in ipairs({ "Inbox", "Re", "Вчора" }) do
  local bad = (" | " .. got .. " | "):find(" | " .. noise .. " | ", 1, true) ~= nil
  if bad then fails = fails + 1 end
  print(string.format("%s names drops %-20s", bad and "FAIL" or "ok  ", noise))
end
print("     names: " .. got)

-- fixes
local dw = { ["mcp"] = true, ["supabase"] = true, ["workflow"] = true }
for _, c in ipairs({
  { "Додає Мсіпі сервер для Сікобейс і перевір, чи працює Веркфлоу.",
    "Додай MCP сервер для Supabase і перевір, чи працює workflow.", 4, 3 },
  { "так давай.", "Так, давай.", 0, 0 },
}) do
  local ch, d = L.fixes(c[1], c[2], dw)
  local ok = ch == c[3] and d == c[4]
  if not ok then fails = fails + 1 end
  print(string.format("%s fixes %d/%d (expected %d/%d)", ok and "ok  " or "FAIL", ch, d, c[3], c[4]))
end

print(fails == 0 and "all passed" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
