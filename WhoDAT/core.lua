--[[=====================================================================
 WhoDAT - core.lua (Production)
 Unified, color-coded logging + single colored startup announcement.
 Wrath 3.3.5a safe (uses DEFAULT_CHAT_FRAME:AddMessage and |cff...|r).
 Color scheme:
 Prefix [WhoDAT:LEVEL] -> BLUE
 ERROR body -> RED
 WARN body  -> GOLD
 INFO body  -> GREEN
 DEBUG body -> GRAY
 Example:
 |cff0070dd[WhoDAT:INFO]|r |cff00ff00ADDON_LOADED: WhoDAT|r
======================================================================]]
-- FIXED: Don't overwrite existing namespace, preserve it!
local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS -- publish shared namespace

-----------------------------------------------------------------------
-- WhoDAT_Util (colors, logging sink, timers) — single choke point
-----------------------------------------------------------------------
_G.WhoDAT_Util = _G.WhoDAT_Util or {}
-- Level map and threshold (default WARN => show WARN/ERROR, hide INFO/DEBUG)
WhoDAT_Util._LEVELS = { ERROR=1, WARN=2, INFO=3, DEBUG=4 }
WhoDAT_Util._THRESH = WhoDAT_Util._THRESH or WhoDAT_Util._LEVELS.WARN
WhoDAT_Util.verbose = WhoDAT_Util.verbose == true and true or false
-- WoW chat color hex (RRGGBB)
WhoDAT_Util.COLOR_BLUE   = "0070dd" -- prefix
WhoDAT_Util.COLOR_GREEN  = "00ff00" -- info body
WhoDAT_Util.COLOR_YELLOW = "ffd100" -- warn body
WhoDAT_Util.COLOR_RED    = "ff4c4c" -- error body
WhoDAT_Util.COLOR_GRAY   = "a0a0a0" -- debug body
-- level -> body color
WhoDAT_Util._L2COLOR = {
  ERROR = WhoDAT_Util.COLOR_RED,
  WARN  = WhoDAT_Util.COLOR_YELLOW,
  INFO  = WhoDAT_Util.COLOR_GREEN,
  DEBUG = WhoDAT_Util.COLOR_GRAY,
}
-- colorize helper
local function _c(hex, text)
  if not text or text == "" then return "" end
  hex = hex or WhoDAT_Util.COLOR_BLUE
  return ("|cff%s%s|r"):format(hex, text)
end
-- set/get log level at runtime
function WhoDAT_Util.SetLogLevel(name)
  local lvl = WhoDAT_Util._LEVELS[(name or ""):upper()]
  if lvl then WhoDAT_Util._THRESH = lvl end
end
function WhoDAT_Util.GetLogLevel()
  for k,v in pairs(WhoDAT_Util._LEVELS) do if v == WhoDAT_Util._THRESH then return k end end
  return "WARN"
end
-- central sink: writes a fully formatted line (Wrath-safe)
function WhoDAT_Util.Write(level, msg)
  level = (type(level) == "string" and level:upper()) or "INFO"
  local lvlNum = WhoDAT_Util._LEVELS[level] or WhoDAT_Util._LEVELS.INFO
  if lvlNum > WhoDAT_Util._THRESH then return end
  local tag  = _c(WhoDAT_Util.COLOR_BLUE, ("[WhoDAT:%s] "):format(level)) -- blue prefix
  local body = _c(WhoDAT_Util._L2COLOR[level], tostring(msg or ""))       -- level-colored
  local line = tag .. body
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(line)
  else
    print(line) -- fallback
  end
end
-- conveniences (legacy-compatible)
function WhoDAT_Util.notifyDone(msg)
  local prefix = _c(WhoDAT_Util.COLOR_BLUE, "[WhoDAT]")
  local body   = _c(WhoDAT_Util.COLOR_GREEN, msg or "Recorded Auction House Data")
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(prefix .. " " .. body)
  else
    print(prefix .. " " .. body)
  end
end
function WhoDAT_Util.log(msg) -- legacy "verbose" path -> DEBUG
  if WhoDAT_Util.verbose then WhoDAT_Util.Write("DEBUG", msg or "") end
end
-- lightweight timer (no C_Timer on Wrath)
function WhoDAT_Util.after(delay, fn)
  local f = CreateFrame("Frame"); local acc = 0
  f:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc >= (delay or 0) then f:SetScript("OnUpdate", nil); pcall(fn) end
  end)
end

-----------------------------------------------------------------------
-- Authoritative addon logger (use this in all modules)
-----------------------------------------------------------------------
NS.Log = function(level, fmt, ...)
  level = level or "INFO"
  local msg = fmt and fmt:format(...) or ""
  WhoDAT_Util.Write(level, msg)
end
NS.LogLine = function(level, msg)
  WhoDAT_Util.Write(level or "INFO", msg or "")
end

-----------------------------------------------------------------------
-- safeCall (optional hooks are INFO; errors are ERROR)
-----------------------------------------------------------------------
local function safeCall(name, fn, ...)
  if type(fn) ~= "function" then
    -- Change to "DEBUG" if you want total silence at WARN threshold:
    NS.Log("INFO", "safeCall skipped: %s is not defined (optional)", tostring(name))
    return false, "not-a-function"
  end
  local ok, err = pcall(fn, ...)
  if not ok then
    NS.Log("ERROR", "%s failed: %s", tostring(name), tostring(err))
    return false, err
  end
  return true
end

-----------------------------------------------------------------------
-- defer (C_Timer.After if present, else immediate with WARN/ERROR logs)
-----------------------------------------------------------------------
local defer
defer = function(seconds, fn, tag)
  -- Always use frame-based timer (Wrath-safe)
  local frame = CreateFrame("Frame")
  local elapsed = 0
  frame:SetScript("OnUpdate", function(self, delta)
    elapsed = elapsed + delta
    if elapsed >= (seconds or 0) then
      frame:SetScript("OnUpdate", nil)
      local ok, err = pcall(fn)
      if not ok then 
        NS.Log("ERROR", "Deferred '%s' failed: %s", tostring(tag or "defer"), tostring(err))
      end
    end
  end)
end

-----------------------------------------------------------------------
-- Core init state
-----------------------------------------------------------------------
NS._init = NS._init or {
  addonLoaded      = false,
  playerLoggedIn   = false,
  statsInitialized = false,
  configInitialized= false,
}

-----------------------------------------------------------------------
-- Event frame & registration
-----------------------------------------------------------------------
local CoreFrame = CreateFrame("Frame", ADDON_NAME .. "Core")
CoreFrame:RegisterEvent("ADDON_LOADED")
CoreFrame:RegisterEvent("PLAYER_LOGIN")
CoreFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
CoreFrame:RegisterEvent("PLAYER_LOGOUT")

-----------------------------------------------------------------------
-- Config & Stats init helpers
-----------------------------------------------------------------------
local function InitConfigIfAvailable()
  if NS._init.configInitialized then return end
  if type(_G.WhoDAT_InitConfig) == "function" then
    local ok, err = pcall(_G.WhoDAT_InitConfig)
    if not ok then
      NS.Log("ERROR", "WhoDAT_InitConfig failed: %s", tostring(err))
      return
    end
    NS._init.configInitialized = true
    NS.Log("INFO", "Configuration initialized via WhoDAT_InitConfig()")
  else
    NS.Log("INFO", "WhoDAT_InitConfig not found; skipping config init")
  end
end

local function InitStatsIfAvailable()
  if NS._init.statsInitialized then return end
  if type(NS.Stats_Init) == "function" then
    defer(1, function()
      local ok = safeCall("Stats_Init", NS.Stats_Init)
      if ok then
        NS._init.statsInitialized = true
        NS.Log("INFO", "Stats initialized")
      end
    end, "init:stats")
  else
    NS.Log("INFO", "NS.Stats_Init not found; skipping stats init")
  end
end

local function InitOptionalSubsystems()
  -- Optional modules; safe no-ops if not present
  safeCall("UI_Init",          NS.UI_Init)
  safeCall("Trackers_Init",    NS.Trackers_Init)
  safeCall("Analytics_Init",   NS.Analytics_Init)
end

-----------------------------------------------------------------------
-- Single, colorized startup announcement (printed once at login)
-----------------------------------------------------------------------
do
  local MOD_COLORS = {
    UI           = "66ffff", -- cyan
    Stats        = "ffd100", -- gold
    Items        = "00ff7f", -- spring green
    Inventory    = "a070ff", -- violet
    Quests       = "ff7f50", -- coral
    Auction      = "b0ff00", -- lime
    Graphs       = "4080ff", -- azure
    Export       = "c0c0c0", -- silver
    Widget       = "90c0ff", -- light blue
    Config       = "00ff00", -- bright green
    Achievements = "ffcc66", -- warm amber
  }
  
  local function c(hex, text) 
    return ("|cff%s%s|r"):format(hex or "ffffff", text or "") 
  end
  
  local function moduleLoaded(name)
    if name == "UI"          then return type(NS.UI_Init) == "function" or NS.mainFrame ~= nil end
    if name == "Stats"       then return type(NS.Stats_Init) == "function" end
    if name == "Items"       then return type(NS.Items_OnBagUpdate) == "function" or type(NS.Items_RegisterEvents) == "function" end
    if name == "Inventory"   then return type(NS.Inventory_Snapshot) == "function" or type(NS.Inventory_RegisterEvents) == "function" end
    if name == "Quests"      then return type(NS.Quests_ScanAll) == "function" or type(NS.Quests_RegisterEvents) == "function" end
    if name == "Auction"     then return _G.TrackerAuction ~= nil end
    if name == "Graphs"      then return type(NS.CreateSparkline) == "function" or type(NS.Graphs_Init) == "function" end
    if name == "Export"      then return type(NS.Export_Now) == "function" end
    if name == "Widget"      then return NS.widgetFrame ~= nil or type(NS.Widget_Init) == "function" end
    if name == "Config"      then return NS._init and NS._init.configInitialized == true end
    if name == "Achievements"then return type(NS.Achievements_RegisterEvents) == "function" or (NS.Achievements and NS.Achievements.Snapshot) end
    return false
  end
  
  local function segment(name)
    local hex = MOD_COLORS[name] or "ffffff"
    local status = moduleLoaded(name) and name or (name .. "(!)")
    return c(hex, status)
  end
  
  -- Simplified startup announcement (for public release)
  function NS.AnnounceStartup()
    local version = WhoDAT_Config and WhoDAT_Config.version or "unknown"
    NS.Log("INFO", "WhoDAT v%s loaded successfully", version)
  end
end 

-----------------------------------------------------------------------
-- Event handler (color-coded logs) + Session lifecycle wiring
-----------------------------------------------------------------------
CoreFrame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 == ADDON_NAME then
      NS._init.addonLoaded = true
      NS.Log("INFO", "ADDON_LOADED: %s", tostring(ADDON_NAME))
      InitOptionalSubsystems()
      -- Early identity bootstrapping so session start can include identity
      safeCall("Stats_UpdateIdentity", NS.Stats_UpdateIdentity)
    end

  elseif event == "PLAYER_LOGIN" then
    NS._init.playerLoggedIn = true
    NS.Log("INFO", "PLAYER_LOGIN")

    -- New session for login or UI reload
    safeCall("Session_Start", NS.Session_Start, "login_or_reload")

    -- Initialize SavedVariables/config and stats
    InitConfigIfAvailable()
    InitStatsIfAvailable()

-- NEW: Comprehensive item lifecycle tracking
if type(NS.ItemLifecycle_RegisterEvents) == "function" then 
  NS.ItemLifecycle_RegisterEvents(CoreFrame)
end

-- NEW: Unified container tracking
if NS.Containers and type(NS.Containers.RegisterEvents) == "function" then
  NS.Containers:RegisterEvents(CoreFrame)
end
    if type(NS.Quests_RegisterEvents)      == "function" then NS.Quests_RegisterEvents(CoreFrame)      end
    if type(NS.Achievements_RegisterEvents)== "function" then NS.Achievements_RegisterEvents(CoreFrame) end
-- NEW: Loot event tracking with mob context
if type(NS.Loot_RegisterEvents) == "function" then 
  NS.Loot_RegisterEvents(CoreFrame)
end
    -- Post-login optional hooks
    safeCall("UI_PostLogin",        NS.UI_PostLogin)
    safeCall("Trackers_PostLogin",  NS.Trackers_PostLogin)

    -- Emit the single, colored announcement
    if type(NS.AnnounceStartup) == "function" then NS.AnnounceStartup() end

  elseif event == "PLAYER_ENTERING_WORLD" then
    -- After zoning and UI stabilization; refresh identity/zone lightly
    NS.Log("INFO", "PLAYER_ENTERING_WORLD")
    safeCall("Stats_UpdateIdentity", NS.Stats_UpdateIdentity)
    safeCall("Stats_OnZoneChanged",  NS.Stats_OnZoneChanged)
    -- Optional: module hook
    safeCall("OnEnteringWorld",      NS.OnEnteringWorld)

  elseif event == "PLAYER_LOGOUT" then
    -- Reliable end signal on client logout
    NS.Log("INFO", "PLAYER_LOGOUT")
    safeCall("Session_End", NS.Session_End, "logout")
  end
  -- Update item tracker zone
  safeCall("ItemLifecycle_OnZoneChanged", NS.ItemLifecycle_OnZoneChanged)
end)
-- Update loot tracker zone
    safeCall("Loot_OnZoneChanged", NS.Loot_OnZoneChanged)
-----------------------------------------------------------------------
-- Public API (status)
-----------------------------------------------------------------------
NS.Core = NS.Core or {}
function NS.Core.IsInitialized()
  return NS._init.addonLoaded and NS._init.playerLoggedIn
end
function NS.Core.Status()
  local S = NS._init
  return {
    addonLoaded      = S.addonLoaded,
    playerLoggedIn   = S.playerLoggedIn,
    configInitialized= S.configInitialized,
    statsInitialized = S.statsInitialized,
  }
end
-- End of core.lua