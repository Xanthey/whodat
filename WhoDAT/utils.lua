
-- WhoDAT - utils.lua (production-ready)
-- Purpose: Safe helpers for item meta, tooltip parsing, player identity, table ops,
-- throttling/retries, locale-aware patterns, lightweight logging, and Event Bus logging.

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- ------------------------------------------------------------------------------
-- Module state
-- ------------------------------------------------------------------------------
NS.Utils = NS.Utils or {}

-- Money formatter (unified)
-- Usage: NS.Utils.FormatMoney(totalCopper) -> 'Xd Ys Zc'
function NS.Utils.FormatMoney(copper)
  copper = tonumber(copper or 0) or 0
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  return string.format("%dg %ds %dc", g, s, c)
end
local U = NS.Utils

-- Versioning for hotfix audits
U.__VERSION = "2.4.3-prod"

-- Local references (Wrath-safe)
local CreateFrame   = CreateFrame
local GetItemInfo   = GetItemInfo
local UnitName      = UnitName
local GetRealmName  = GetRealmName
local UnitClass     = UnitClass
local GetLocale     = GetLocale
local time          = time

-- ------------------------------------------------------------------------------
-- Logger (pluggable)
-- ------------------------------------------------------------------------------
local LOG_LEVELS = { ERROR=1, WARN=2, INFO=3, DEBUG=4 }
NS.__logLevel = NS.__logLevel or LOG_LEVELS.WARN -- default: show WARN/ERROR only

function NS.SetLogLevel(name)
  if name and LOG_LEVELS[name] then NS.__logLevel = LOG_LEVELS[name] end
end

NS.Log = function(level, fmt, ...)
  level = level or "INFO"
  local lvl = LOG_LEVELS[level] or LOG_LEVELS.INFO
  if lvl > NS.__logLevel then return end
  local prefix = ("[WhoDAT:%s] "):format(level)
  local msg = fmt and (fmt):format(...) or ""
  -- Use DEFAULT_CHAT_FRAME in Wrath instead of print for consistent output
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(prefix .. msg)
  else
    print(prefix .. msg)
  end
end

-- Convenience: expose a public setter under Utils as well
function U.SetLoggerLevel(levelName) NS.SetLogLevel(levelName) end

-- ------------------------------------------------------------------------------
-- Player identity
-- ------------------------------------------------------------------------------
-- Prefer the identity persisted by config.lua bootstrapping; fall back to Units.
local function safeIdentity()
  local id = (type(WhoDAT_GetIdentity) == "function") and WhoDAT_GetIdentity() or nil
  if type(id) == "table" and (id.realm or id.player_name) then
    return id.realm or "UnknownRealm",
           id.player_name or "Unknown",
           id.class_file or "UNKNOWN"
  end
  -- Fallbacks if called before WhoDAT_InitConfig()
  local name = UnitName("player") or "Unknown"
  local realm = GetRealmName() or "UnknownRealm"
  local _, classFile = UnitClass("player")
  return realm, name, classFile or "UNKNOWN"
end

-- Stable player key; canonical format realm:name:classfile (classfile helps disambiguate clones)
function U.GetPlayerKey()
  local realm, name, classFile = safeIdentity()
  return string.format("%s:%s:%s", realm, name, classFile)
end

-- ------------------------------------------------------------------------------
-- Tooltip infrastructure (hygienic + throttled)
-- ------------------------------------------------------------------------------
-- Dedicated, hidden tooltip to avoid taint and cross-use issues
local itemTip = CreateFrame("GameTooltip", "WhoDATItemTooltip", UIParent, "GameTooltipTemplate")
local function Tip_Clear()
  itemTip:ClearLines()
  itemTip:Hide()
end
local function Tip_SetHyperlink(linkOrId)
  Tip_Clear()
  if type(linkOrId) == "string" then
    itemTip:SetHyperlink(linkOrId)
  elseif type(linkOrId) == "number" then
    itemTip:SetHyperlink("item:" .. tostring(linkOrId))
  else
    return false
  end
  return true
end
-- Throttling window to avoid heavy tooltip spam on private cores
local TIP_THROTTLE_SEC = 0.25
local lastTipTs = 0
local function Tip_Throttled()
  local now = time()
  if (now - lastTipTs) < TIP_THROTTLE_SEC then
    return false
  end
  lastTipTs = now
  return true
end

-- ------------------------------------------------------------------------------
-- Link parsing helpers
-- ------------------------------------------------------------------------------
function U.GetItemNameFromLink(link)
  if type(link) ~= "string" then return nil end
  -- Standard WoW link format:
  -- |cffaabbcc|Hitem:itemId:...|h[Item Name]|h|r
  -- Prefer the [Item Name] portion to avoid localization differences elsewhere
  local name = link:match("%[(.+)%]")
  return name
end

function U.GetItemIdFromLink(link)
  if type(link) ~= "string" then return nil end
  local id = link:match("item:(%d+)")
  if id then return tonumber(id) end
  return nil
end

-- ------------------------------------------------------------------------------
-- Locale-aware patterns (expandable if you parse system text)
-- ------------------------------------------------------------------------------
U.Locale = GetLocale() or "enUS"
U.Patterns = {
  -- Expand with localized patterns when you later parse CHAT_MSG_SYSTEM, etc.
  -- Example (enUS): "You won an auction for (.+)" or "Your auction of (.+) sold"
}

-- ------------------------------------------------------------------------------
-- Retry helper (for cache-warm API like GetItemInfo)
-- ------------------------------------------------------------------------------
-- Retry strategy: fixed small attempts with OnDemand calls only from your code path.
-- Do NOT schedule OnUpdate here to keep utils low-level; call retries from callers.
function U.Retry_GetItemInfo(linkOrId, attempts)
  attempts = attempts or 1
  -- Correct Wrath ordering: name, link, quality, iLevel, reqLevel, class, subClass,
  -- maxStack, equipLoc, icon, itemId
  local name, _, quality, ilvl, reqLevel, class, subclass, maxStack, equipLoc, icon, itemId = GetItemInfo(linkOrId)
  if name or attempts <= 1 then
    return name, ilvl, quality, reqLevel, class, subclass, maxStack, equipLoc, icon, itemId
  end
  -- Try a tooltip poke to encourage cache (throttled)
  if Tip_Throttled() and Tip_SetHyperlink(linkOrId) then
    name, _, quality, ilvl, reqLevel, class, subclass, maxStack, equipLoc, icon, itemId = GetItemInfo(linkOrId)
  end
  return name, ilvl, quality, reqLevel, class, subclass, maxStack, equipLoc, icon, itemId
end

-- ------------------------------------------------------------------------------
-- Public: GetItemMeta(linkOrId)
-- Returns: name, itemLevel, quality, reqLevel, class, subclass, maxStack, equipLoc, iconPath, itemID
-- ------------------------------------------------------------------------------
function U.GetItemMeta(linkOrId)
  -- First try cached API (single call)
  local name, ilvl, quality, reqLevel, class, subclass, maxStack, equipLoc, icon, itemId =
    U.Retry_GetItemInfo(linkOrId, 1)
  if name then
    return name, ilvl, quality, reqLevel, class, subclass, maxStack, equipLoc, icon, itemId
  end
  -- Fallback: tooltip read + second attempt to GetItemInfo (minimal work)
  if Tip_Throttled() and Tip_SetHyperlink(linkOrId) then
    local tipName = (WhoDATItemTooltipTextLeft1 and WhoDATItemTooltipTextLeft1:GetText()) or nil
    name = name or tipName
    -- Optional: iLvl can appear in Wrath tooltips; scan first few lines conservatively
    -- Keep lightweight to avoid locale brittleness; callers can augment when needed.
    for i = 2, math.min(itemTip:NumLines() or 0, 6) do
      local line = _G["WhoDATItemTooltipTextLeft"..i]
      local txt = line and line:GetText()
      if txt then
        -- Example heuristic for iLvl patterns you might enable later:
        -- local lvl = txt:match("[Ii]tem [Ll]evel (%d+)")
        -- if lvl then ilvl = tonumber(lvl) break end
      end
    end
    -- Parse itemId from link string when available
    if type(linkOrId) == "string" then
      itemId = U.GetItemIdFromLink(linkOrId)
    else
      itemId = linkOrId
    end
    -- One more GetItemInfo after tooltip poke (Wrath ordering)
    local n2, _, q2, i2, r2, c2, sc2, ms2, el2, ic2, id2 = GetItemInfo(linkOrId)
    name     = n2 or name
    quality  = q2 or quality
    reqLevel = r2 or reqLevel
    ilvl     = i2 or ilvl
    class    = c2 or class
    subclass = sc2 or subclass
    maxStack = ms2 or maxStack
    equipLoc = el2 or equipLoc
    icon     = ic2 or icon
    itemId   = id2 or itemId
  else
    NS.Log("DEBUG", "Tooltip throttle prevented immediate meta for %s", tostring(linkOrId))
    -- minimally return what we have (often just itemId)
    if type(linkOrId) == "string" then
      itemId = U.GetItemIdFromLink(linkOrId)
      name = U.GetItemNameFromLink(linkOrId)
    else
      itemId = linkOrId
    end
  end
  return name, ilvl, quality, reqLevel, class, subclass, maxStack, equipLoc, icon, itemId
end

-- ------------------------------------------------------------------------------
-- ResolveItemLink: normalize to a hyperlink string if we get an itemString or itemId
-- ------------------------------------------------------------------------------
function U.ResolveItemLink(maybe)
  if type(maybe) == "string" then
    if maybe:find("|Hitem:") then
      return maybe -- already a hyperlink
    end
    -- itemString like "item:12345:..."
    if maybe:match("^item:%d+") then
      -- Force the client to resolve: tooltip poke, then GetItemInfo for link
      if Tip_Throttled() then Tip_SetHyperlink(maybe) end
      local name, link = GetItemInfo(maybe)
      return link or maybe
    end
  elseif type(maybe) == "number" then
    if Tip_Throttled() then Tip_SetHyperlink(maybe) end
    local name, link = GetItemInfo(maybe)
    return link or ("item:" .. tostring(maybe))
  end
  return nil
end

-- ------------------------------------------------------------------------------
-- Table ops (nil-safe)
-- ------------------------------------------------------------------------------
function U.Table_ShallowCopy(src, dst)
  if type(src) ~= "table" then return dst end
  dst = dst or {}
  for k, v in pairs(src) do dst[k] = v end
  return dst
end

function U.Table_DeepCopy(src, seen)
  if type(src) ~= "table" then return src end
  if seen and seen[src] then return seen[src] end
  local s = seen or {}
  local t = {}
  s[src] = t
  for k, v in pairs(src) do
    local nk = U.Table_DeepCopy(k, s)
    local nv = U.Table_DeepCopy(v, s)
    t[nk] = nv
  end
  return t
end

function U.Table_ForceArray(tbl)
  -- Ensures a sequence array index (1..n) for export stability
  if type(tbl) ~= "table" then return { tbl } end
  local out, n = {}, 0
  for _, v in pairs(tbl) do
    n = n + 1
    out[n] = v
  end
  return out
end

function U.Safe_Insert(tbl, value)
  if type(tbl) ~= "table" then return false end
  tbl[#tbl + 1] = value
  return true
end

-- ------------------------------------------------------------------------------
-- Defensive helpers
-- ------------------------------------------------------------------------------
function U.IsNonEmptyString(s) return type(s) == "string" and s ~= "" end

function U.Try(fn, ...)
  -- Simple protected call to isolate rare API quirks
  local ok, a, b, c, d, e = pcall(fn, ...)
  if not ok then NS.Log("ERROR", "Utils.Try failed: %s", tostring(a)) end
  return ok, a, b, c, d, e
end

-- ------------------------------------------------------------------------------
-- WhoDAT utility helpers (colors, logging, timers)
-- ------------------------------------------------------------------------------
_G.WhoDAT_Util = _G.WhoDAT_Util or {}

-- Verbose flag (set to true to see detailed logs)
WhoDAT_Util.verbose = false -- production: false

-- Colors (hex without 0x, WoW’s |cffRRGGBB)
WhoDAT_Util.COLOR_BLUE  = "0070dd" -- Rare item blue
WhoDAT_Util.COLOR_GREEN = "00ff00" -- Bright green
-- Optional alternates:
-- WhoDAT_Util.COLOR_DODGER = "1e90ff"

-- Colorize a string with a hex code (safe on nil)
function WhoDAT_Util.color(text, hex)
  if not text or text == "" then return "" end
  hex = hex or WhoDAT_Util.COLOR_BLUE
  return ("|cff%s%s|r"):format(hex, text)
end

-- Single “done” notification line (blue tag + green text)
function WhoDAT_Util.notifyDone(msg)
  local prefix = WhoDAT_Util.color("[WhoDAT]", WhoDAT_Util.COLOR_BLUE)
  local body   = WhoDAT_Util.color(msg or "Recorded Auction House Data", WhoDAT_Util.COLOR_GREEN)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(prefix .. " " .. body)
  else
    print(prefix .. " " .. body)
  end
end

-- Verbose logger (respects WhoDAT_Util.verbose)
function WhoDAT_Util.log(msg)
  if WhoDAT_Util.verbose then
    local prefix = WhoDAT_Util.color("[WhoDAT]", WhoDAT_Util.COLOR_BLUE)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
      DEFAULT_CHAT_FRAME:AddMessage(prefix .. " " .. (msg or ""))
    else
      print(prefix .. " " .. (msg or ""))
    end
  end
end

-- Lightweight timer utility: WhoDAT_Util.after(seconds, fn)
function WhoDAT_Util.after(delay, fn)
  local f = CreateFrame("Frame")
  local acc = 0
  f:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc >= (delay or 0) then
      f:SetScript("OnUpdate", nil)
      pcall(fn)
    end
  end)
end

-- ------------------------------------------------------------------------------
-- Event Bus: unified append-only per-character domain streams
-- ------------------------------------------------------------------------------
-- Usage:
--   WhoDAT_LogEvent("items", "equip", { itemId=12345, slot=16, ilvl=200 }, { mirror_global=true })
-- Guarantees all buckets exist and appends in O(1). Returns (index, evt).
function WhoDAT_LogEvent(domain, kind, payload, opts)
  opts = opts or {}
  domain = tostring(domain or "misc")
  kind   = tostring(kind   or "changed")

  local key = U.GetPlayerKey()

  -- Ensure SavedVariables buckets exist
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.characters = WhoDatDB.characters or {}
  WhoDatDB.characters[key] = WhoDatDB.characters[key] or {}

  local C = WhoDatDB.characters[key]
  C.events = C.events or {}
  C.events[domain] = C.events[domain] or {}

  -- Minimal provenance for exporters and debugging
  local id = (type(WhoDAT_GetIdentity) == "function") and WhoDAT_GetIdentity() or {}
  local schema = (type(WhoDAT_GetSchema)   == "function") and WhoDAT_GetSchema()   or {}
  local evt = {
    ts   = opts.ts or time(),
    kind = kind,           -- e.g., "added", "removed", "changed", "snapshot", "mail_received"
    data = payload or {},
    meta = {
      realm       = id.realm,
      player      = id.player_name,
      class_file  = id.class_file,
      addon_ver   = (type(WhoDAT_GetVersion) == "function") and WhoDAT_GetVersion() or nil,
      schema_tag  = schema.export_format,
      domain      = domain,
    }
  }

  -- Append per-character event
  table.insert(C.events[domain], evt)

  -- Optional: also mirror to a unified global stream
  if opts.mirror_global then
    WhoDatDB.events = WhoDatDB.events or {}
    table.insert(WhoDatDB.events, evt)
  end

  -- Optional log (debug only)
  NS.Log("DEBUG", "Event: %s/%s appended (player=%s)", domain, kind, key)

  return #C.events[domain], evt
end

-- ------------------------------------------------------------------------------
-- Public contract (exports)
-- ------------------------------------------------------------------------------
-- U.GetPlayerKey()
-- U.GetItemMeta(linkOrId)
-- U.ResolveItemLink(maybe)
-- U.GetItemNameFromLink(link)
-- U.GetItemIdFromLink(link)
-- U.SetLoggerLevel(levelName) -- "ERROR" | "WARN" | "INFO" | "DEBUG"
-- Table helpers: U.Table_ShallowCopy, U.Table_DeepCopy, U.Table_ForceArray, U.Safe_Insert
-- U.IsNonEmptyString, U.Try
-- U.__VERSION
-- WhoDAT_LogEvent(domain, kind, payload, opts)
