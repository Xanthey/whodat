
--[[========================================================================================
WhoDAT — Achievements Tracker (Wrath 3.3.5a, standalone & production-hardened)
===========================================================================================
- No dependency on tracker.lua
- Backfill using Wrath overload: GetAchievementInfo(categoryID, index)
- Live logging on ACHIEVEMENT_EARNED
- Dedupe ledger prevents duplicates across scans/events
- Date-tuple fallback: earned if (completed == true) OR (month/day/year all > 0)
- Safe, one-time UI priming (invisible show/hide + select categories) via /wdachprime
- Zero chat spam; small diagnostics via /wdachdiag
=========================================================================================]]

-------------------------------------
-- SavedVariables & containers (SV) --
-------------------------------------
WhoDatDB = WhoDatDB or {}
WhoDatDB.timeseries = WhoDatDB.timeseries or {}
WhoDatDB.timeseries.achievements = WhoDatDB.timeseries.achievements or {}
WhoDatDB._internals = WhoDatDB._internals or {}
WhoDatDB._internals.achievementsLogged = WhoDatDB._internals.achievementsLogged or {}

-- Defensive initializer: call before any access to WhoDatDB.* paths
local function ensureDB()
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.timeseries = WhoDatDB.timeseries or {}
  WhoDatDB._internals = WhoDatDB._internals or {}
  WhoDatDB.timeseries.achievements = WhoDatDB.timeseries.achievements or {}
  WhoDatDB._internals.achievementsLogged = WhoDatDB._internals.achievementsLogged or {}
end

-- Ensure once on file load
ensureDB()

--------------------
-- Local helpers  --
--------------------
local MAX_SERIES = 500
local lastTs = 0
local function now()
  local t = time()
  lastTs = math.max(t or 0, lastTs or 0)
  return lastTs
end

local function pushSeries(tbl, entry, cap)
  ensureDB()
  if type(tbl) ~= "table" then return end
  cap = cap or MAX_SERIES
  tbl[#tbl+1] = entry
  local excess = #tbl - cap
  if excess > 0 then
    for i = 1, excess do table.remove(tbl, 1) end
  end
end

local function alreadyLogged(id)
  ensureDB()
  if not id then return true end
  return WhoDatDB._internals.achievementsLogged[tostring(id)] == true
end

local function markLogged(id)
  ensureDB()
  if not id then return end
  WhoDatDB._internals.achievementsLogged[tostring(id)] = true
end

-- earned if completed is true OR date tuple exists (month/day/year all > 0)
local function isEarned(completed, month, day, year)
  if completed == true or (type(completed) == "number" and completed > 0) then return true end
  local m = tonumber(month) or 0
  local d = tonumber(day) or 0
  local y = tonumber(year) or 0
  return (m > 0 and d > 0 and y > 0)
end

local function computeEarnedTime(month, day, year)
  local m = tonumber(month) or 0
  local d = tonumber(day) or 0
  local y = tonumber(year) or 0
  if m > 0 and d > 0 and y > 0 then
    return time({ year = y, month = m, day = d, hour = 12, min = 0, sec = 0 })
  end
  return now()
end

local function pushAchievement(id, name, points, description, earnedTs)
  ensureDB()
  if not id or alreadyLogged(id) then return end
  local entry = {
    ts = earnedTs or now(),
    id = tonumber(id) or 0,
    name = name or "",
    points = tonumber(points) or 0,
    description = description or "",
    earned = true,
    earnedDate = earnedTs or now(),
  }
  pushSeries(WhoDatDB.timeseries.achievements, entry, MAX_SERIES)
  markLogged(id)
end

-----------------------
-- Live earn logging --
-----------------------
local function logByID(achievementID)
  ensureDB()
  if not (GetAchievementInfo and achievementID) then return end
  -- ID-only overload
  local name, points, completed, month, day, year, description = GetAchievementInfo(achievementID)
  if isEarned(completed, month, day, year) then
    local ts = computeEarnedTime(month, day, year)
    pushAchievement(achievementID, name, points, description, ts)
  end
end

-----------------------------------
-- Backfill via category-index API --
-----------------------------------
local _scanRunning = false
local function scanAll()
  ensureDB()
  if _scanRunning then return end
  _scanRunning = true
  local ok = pcall(function()
    if not (GetCategoryList and GetCategoryNumAchievements and GetAchievementInfo) then return end
    local cats = GetCategoryList()
    if type(cats) ~= "table" then return end
    for _, catID in ipairs(cats) do
      local count = GetCategoryNumAchievements(catID, true) or 0 -- include FoS
      for index = 1, count do
        -- Wrath overload: id first
        local id, name, points, completed, month, day, year, description = GetAchievementInfo(catID, index)
        if id and isEarned(completed, month, day, year) then
          local ts = computeEarnedTime(month, day, year)
          pushAchievement(id, name, points, description, ts)
        end
      end
    end
  end)
  _scanRunning = false
end

--------------------------
-- Blizzard UI priming  --
--------------------------
local _primedOnce = false

local function ensureAchievementUILoaded()
  ensureDB()
  if type(LoadAddOn) == "function" then pcall(LoadAddOn, "Blizzard_AchievementUI") end
  if type(AchievementFrame_LoadUI) == "function" then pcall(AchievementFrame_LoadUI) end
end

local function hookAchievementFrameOnShow()
  ensureDB()
  if AchievementFrame and not AchievementFrame._WhoDatAchievementsHooked then
    AchievementFrame._WhoDatAchievementsHooked = true
    AchievementFrame:HookScript("OnShow", function() scanAll() end)
  end
end

-- Carefully prime: invisible show/hide + select categories
local function primeAchievementFrameOnce()
  ensureDB()
  if _primedOnce then return end
  ensureAchievementUILoaded()
  local frame = AchievementFrame
  if not frame then return end

  local wasShown = frame:IsShown()
  local prevAlpha = frame:GetAlpha() or 1
  frame:SetAlpha(0)

  local ShowPanel = _G.ShowUIPanel or function(f) f:Show() end
  local HidePanel = _G.HideUIPanel or function(f) f:Hide() end
  ShowPanel(frame)

  local cats = GetCategoryList and GetCategoryList() or {}
  if type(AchievementFrame_SelectCategory) == "function" and type(cats) == "table" then
    for _, catID in ipairs(cats) do
      pcall(AchievementFrame_SelectCategory, catID)
    end
  end

  if not wasShown then
    HidePanel(frame)
  end
  frame:SetAlpha(prevAlpha > 0 and prevAlpha or 1)

  _primedOnce = true
end

----------------
-- Event wire --
----------------
local f = CreateFrame("Frame")
f:RegisterEvent("ACHIEVEMENT_EARNED")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")

f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ACHIEVEMENT_EARNED" then
    logByID(arg1)

  elseif event == "ADDON_LOADED" then
    if arg1 == "Blizzard_AchievementUI" then
      hookAchievementFrameOnShow()
    end

  elseif event == "PLAYER_LOGIN" then
    ensureAchievementUILoaded()
    hookAchievementFrameOnShow()
    scanAll()         -- try once early

  elseif event == "PLAYER_ENTERING_WORLD" then
    hookAchievementFrameOnShow()
    scanAll()         -- try once after entering world
  end
end)


-------------------
-- Slash commands --
-------------------

-- Defensive initializer (local reuse in handlers)
local function ensureDB()
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.timeseries = WhoDatDB.timeseries or {}
  WhoDatDB._internals = WhoDatDB._internals or {}
  WhoDatDB.timeseries.achievements = WhoDatDB.timeseries.achievements or {}
  WhoDatDB._internals.achievementsLogged = WhoDatDB._internals.achievementsLogged or {}
end

-- /wdachping -> quick sanity
SLASH_WhoDATACHPING1 = "/wdachping"
SlashCmdList["WhoDATACHPING"] = function()
  ensureDB()
  print("[WhoDAT] achievements tracker loaded; tsAchCount=", #WhoDatDB.timeseries.achievements)
end

-- /wdach -> scan immediately (quiet)
SLASH_WhoDATACH1 = "/wdach"
SlashCmdList["WhoDATACH"] = function()
  ensureDB()
  scanAll()
end

-- /wdachprime -> prime invisibly, then scan
SLASH_WhoDATACHPRIME1 = "/wdachprime"
SlashCmdList["WhoDATACHPRIME"] = function()
  ensureDB()
  primeAchievementFrameOnce()
  scanAll()
end

-- /wdachdiag -> minimal diagnostics
SLASH_WhoDATACHDIAG1 = "/wdachdiag"
SlashCmdList["WhoDATACHDIAG"] = function()
  ensureDB()
  local cats = GetCategoryList and GetCategoryList() or {}
  local firstCat = type(cats) == "table" and cats[1] or nil
  local count = (firstCat and GetCategoryNumAchievements and GetCategoryNumAchievements(firstCat, true))
                and GetCategoryNumAchievements(firstCat, true) or nil
  local id, name, points, completed, month, day, year, description =
      (firstCat and GetAchievementInfo) and GetAchievementInfo(firstCat, 1) or nil

  print("[WhoDAT] cats=", type(cats)=="table" and #cats or "nil",
        " firstCat=", firstCat or "nil",
        " firstCount=", count or "nil",
        " firstId=", id or "nil",
        " firstCompleted=", tostring(completed),
        " firstDate=", (month or "nil").."/"..(day or "nil").."/"..(year or "nil"),
        " tsAchCount=", #WhoDatDB.timeseries.achievements)
end
