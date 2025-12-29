
-- WhoDAT - export.lua
-- Build WhoDatDB structured export; ensure item name + ilvl present; write on logout

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- Locale-aware item level patterns
local ILVL_PATTERNS = {
  enUS = "Item Level%s*:?%s*(%d+)",
  enGB = "Item Level%s*:?%s*(%d+)",
  deDE = "Gegenstandsstufe%s*:?%s*(%d+)",
  frFR = "Niveau d'objet%s*:?%s*(%d+)",
  esES = "Nivel de objeto%s*:?%s*(%d+)",
  esMX = "Nivel de objeto%s*:?%s*(%d+)",
  ptBR = "Nível do Item%s*:?%s*(%d+)",
  ruRU = "Уровень предмета%s*:?%s*(%d+)",
  koKR = "아이템 레벨%s*:?%s*(%d+)",
  zhCN = "物品等级%s*:?%s*(%d+)",
  zhTW = "物品等級%s*:?%s*(%d+)",
}

local CLIENT_LOCALE = GetLocale() or "enUS"

-- Optional: allow utilities if present, but work standalone if not.
local U = NS.Utils

-- -------------------- Internal helpers (Wrath-safe) --------------------

local SCANNER_FRAME_NAME = ADDON_NAME .. "ScannerTooltip"
local scanner = _G[SCANNER_FRAME_NAME]
if not scanner then
  scanner = CreateFrame("GameTooltip", SCANNER_FRAME_NAME, nil, "GameTooltipTemplate")
  scanner:SetOwner(UIParent, "ANCHOR_NONE")
end

local function ensurePath(root, ...)
  local t = root
  for i = 1, select("#", ...) do
    local k = select(i, ...)
    if t[k] == nil then t[k] = {} end
    t = t[k]
  end
  return t
end

local function parseItemLevelFromTooltip(link)
  -- Fallback when GetItemInfo() hasn't cached yet.
  local ilvl = nil
  scanner:ClearLines()
  scanner:SetHyperlink(link)
  -- English fallback; extend for locales if needed.
  for i = 1, scanner:NumLines() do
    local left = _G[SCANNER_FRAME_NAME .. "TextLeft" .. i]
    local txt = left and left:GetText()
    if txt then
      local pattern = ILVL_PATTERNS[CLIENT_LOCALE] or ILVL_PATTERNS.enUS
local n = txt:match(pattern)
      if n then
        ilvl = tonumber(n)
        break
      end
    end
  end
  scanner:ClearLines()
  return ilvl
end

local function safeGetItemInfo(linkOrId)
  -- Prefer Utils if you've already wrapped this; otherwise use local logic
  if U and U.GetItemMeta then
    local name, ilvl, quality, _, _, _, _, stack, equipLoc, icon, itemID = U.GetItemMeta(linkOrId)
    return name, quality, icon, equipLoc, stack, itemID, ilvl
  end
  local name, link, quality, ilvl, reqLevel, class, subClass, stack, equipLoc, icon, sellPrice, itemID = GetItemInfo(linkOrId)
  if not name then
    -- Force cache via tooltip; then retry name and ilvl
    scanner:ClearLines()
    if linkOrId and type(linkOrId) == "string" then
      scanner:SetHyperlink(linkOrId)
    end
    scanner:ClearLines()
    name, link, quality, ilvl, reqLevel, class, subClass, stack, equipLoc, icon, sellPrice, itemID = GetItemInfo(linkOrId)
  end
  if not ilvl and link then
    ilvl = parseItemLevelFromTooltip(link)
  end
  return name, quality, icon, equipLoc, stack, itemID, ilvl
end

local function addToCatalog(indexByItemID, catalog, itemLinkOrString, count, targetField)
  if not itemLinkOrString then return end
  local name, quality, icon, equipLoc, stack, itemID, ilvl = safeGetItemInfo(itemLinkOrString)
  if not itemID then return end

  local entryIndex = indexByItemID[itemID]
  if not entryIndex then
    table.insert(catalog, {
      item_string      = itemLinkOrString,
      id               = itemID,
      name             = name or "",
      quality          = quality or 0,
      stack_size       = stack or 0,
      equip_loc        = equipLoc or "",
      icon             = icon or "",
      ilvl             = ilvl or 0,
      quantity_bag     = 0,
      quantity_bank    = 0,
      quantity_keyring = 0,
      quantity_mail    = 0
    })
    entryIndex = #catalog
    indexByItemID[itemID] = entryIndex
  end

  local e = catalog[entryIndex]
  local c = tonumber(count) or 0
  if targetField and e[targetField] ~= nil then
    e[targetField] = (e[targetField] or 0) + c
  end
  -- Backfill missing metadata on later cache hits
  if (not e.name or e.name == "") and name then e.name = name end
  if (not e.ilvl or e.ilvl == 0) and ilvl then e.ilvl = ilvl end
  if (not e.icon or e.icon == "") and icon then e.icon = icon end
  if (not e.equip_loc or e.equip_loc == "") and equipLoc then e.equip_loc = equipLoc end
  if (not e.stack_size or e.stack_size == 0) and stack then e.stack_size = stack end
end

-- -------------------- Robust compaction (stable serialization) --------------------

-- Deterministic serialization for table fields so equality checks are stable.
local function _stable_serialize(v)
  local t = type(v)
  if t ~= "table" then return tostring(v or "") end
  local keys = {}
  for k in pairs(v) do keys[#keys+1] = k end
  table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
  local parts = {}
  for i = 1, #keys do
    local k = keys[i]
    parts[#parts+1] = tostring(k) .. ":" .. _stable_serialize(v[k])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function CompactSeriesInPlace(seriesArr, valueFields)
  if type(seriesArr) ~= "table" or #seriesArr == 0 then return end
  local out, lastKey = {}, nil
  for i = 1, #seriesArr do
    local p = seriesArr[i]
    local keyParts = {}
    for _, f in ipairs(valueFields) do
      keyParts[#keyParts+1] = _stable_serialize(p[f])
    end
    local key = table.concat(keyParts, "\n") -- newline delimiter
    if key ~= lastKey then
      out[#out+1] = p
      lastKey = key
    end
  end
  wipe(seriesArr)
  for i = 1, #out do seriesArr[i] = out[i] end
end

local function CompactAllSeries(C)
  local S = (C and C.series) or {}
  -- Core series
  if S.money        then CompactSeriesInPlace(S.money,        {"value"}) end
  if S.xp           then CompactSeriesInPlace(S.xp,           {"value","max"}) end
  if S.rested       then CompactSeriesInPlace(S.rested,       {"value"}) end
  if S.level        then CompactSeriesInPlace(S.level,        {"value"}) end
  if S.honor        then CompactSeriesInPlace(S.honor,        {"value"}) end
  if S.zones        then CompactSeriesInPlace(S.zones,        {"zone","subzone","hearth"}) end

  -- Base stats points: { ts=..., values={...}, resistances={...} }
  if S.base_stats   then CompactSeriesInPlace(S.base_stats,   {"values","resistances"}) end

  -- Optional: uncomment if you store these series (serializer handles nested tables)
  -- if S.attack       then CompactSeriesInPlace(S.attack,       {"mhSpeed","ohSpeed","apBase","apPos","apNeg","crit","dodge","parry","block"}) end
  -- if S.spell_ranged then CompactSeriesInPlace(S.spell_ranged, {"ranged","spell"}) end
  -- if S.currency     then CompactSeriesInPlace(S.currency,     {"name","count"}) end
  -- if S.resource_max then CompactSeriesInPlace(S.resource_max, {"hp","mp","powerType"}) end
end

-- -------------------- Core export builders --------------------
-- Compute a lightweight hash of container contents
local function _computeContainersHash(containers)
  if type(containers) ~= "table" then return 0 end
  
  local sum = 0
  local count = 0
  
  -- Hash bags
  for _, bag in ipairs(containers.bags or {}) do
    for _, item in ipairs(bag.contents or {}) do
      sum = sum + (item.id or 0) * (item.count or 1)
      count = count + 1
    end
  end
  
  -- Hash bank
  for _, bag in ipairs(containers.bank or {}) do
    for _, item in ipairs(bag.contents or {}) do
      sum = sum + (item.id or 0) * (item.count or 1)
      count = count + 1
    end
  end
  
  -- Hash keyring
  for _, bag in ipairs(containers.keyring or {}) do
    for _, item in ipairs(bag.contents or {}) do
      sum = sum + (item.id or 0) * (item.count or 1)
      count = count + 1
    end
  end
  
  -- Hash mailbox attachments
  for _, mail in ipairs(containers.mailbox or {}) do
    for _, item in ipairs(mail.attachments or {}) do
      sum = sum + (item.id or 0) * (item.count or 1)
      count = count + 1
    end
  end
  
  -- Combine sum and count for unique hash
  return (sum * 1000) + count
end

-- ============================================================================
-- MODIFIED EnsureItemCatalog (Replace existing function)
-- ============================================================================

local function EnsureItemCatalog()
  -- Determine active character key
  local key
  if U and U.GetPlayerKey then
    key = U.GetPlayerKey()
  else
    local realm = GetRealmName() or "UNKNOWN"
    local name  = UnitName("player") or "UNKNOWN"
    key = string.format("%s:%s", realm, name)
  end

  WhoDatDB = WhoDatDB or {}
  WhoDatDB.schema = WhoDatDB.schema or {}
  WhoDatDB.schema.version = WhoDAT_Config and WhoDAT_Config.schema and WhoDAT_Config.schema.catalog_version or 3
  WhoDatDB.schema.tag = WhoDAT_Config and WhoDAT_Config.schema and WhoDAT_Config.schema.export_format or "v3"

  local C = ensurePath(WhoDatDB, "characters", key)
  
  -- ========================================================================
  -- EARLY EXIT: Check if containers changed since last catalog build
  -- ========================================================================
  local currentHash = _computeContainersHash(C.containers)
  C._catalogMeta = C._catalogMeta or {}
  
if C._catalogMeta.lastHash == currentHash then
  -- No changes detected - skip rebuild but update timestamp
  C._catalogMeta.lastUpdate = time()  -- ✅ ADD THIS LINE
  
  if NS.Log then
    NS.Log("DEBUG", "Catalog unchanged (hash: %d), skipping rebuild", currentHash)
  end
  return
end
  
  -- Hash changed - rebuild catalog
  if NS.Log then
    NS.Log("INFO", "Catalog changed (old: %d, new: %d), rebuilding", 
      C._catalogMeta.lastHash or 0, currentHash)
  end
  
  -- ========================================================================
  -- Proceed with catalog rebuild (existing logic)
  -- ========================================================================
  
  ensurePath(C, "containers", "bags")
  ensurePath(C, "containers", "bank")
  ensurePath(C, "containers", "mailbox")

  local catalogs = ensurePath(C, "catalogs")
  local catalog  = catalogs.items_catalog
  if not catalog then
    catalog = {}
    catalogs.items_catalog = catalog
  end

  -- Build an index for dedup by itemID
  local indexByItemID = {}
  for i, e in ipairs(catalog) do
    if e and e.id then indexByItemID[e.id] = i end
  end

  -- ---- Bags
  for _, bag in ipairs(C.containers.bags or {}) do
    for _, it in ipairs(bag.contents or {}) do
      addToCatalog(indexByItemID, catalog, it.link or it.item_string, it.count, "quantity_bag")
    end
  end

  -- ---- Bank
  for _, bag in ipairs(C.containers.bank or {}) do
    for _, it in ipairs(bag.contents or {}) do
      addToCatalog(indexByItemID, catalog, it.link or it.item_string, it.count, "quantity_bank")
    end
  end

  -- ---- Mail attachments
  for _, mail in ipairs(C.containers.mailbox or {}) do
    for _, it in ipairs(mail.attachments or {}) do
      addToCatalog(indexByItemID, catalog, it.link or it.item_string, it.count, "quantity_mail")
    end
  end

  -- ---- Keyring
  local snap = C.snapshots
  if snap and snap.keyring and snap.keyring.contents then
    for _, it in pairs(snap.keyring.contents) do
      addToCatalog(indexByItemID, catalog, it.link or it.item_string, it.count or 1, "quantity_keyring")
    end
  end
  if catalogs.keyring then
    for _, it in ipairs(catalogs.keyring) do
      local qty = it.quantity_keyring or it.count or 1
      addToCatalog(indexByItemID, catalog, it.item_string or it.link, qty, "quantity_keyring")
    end
  end

  -- Normalize zeros and ensure integers
  for _, e in ipairs(catalog) do
    e.quantity_bag     = tonumber(e.quantity_bag     or 0) or 0
    e.quantity_bank    = tonumber(e.quantity_bank    or 0) or 0
    e.quantity_keyring = tonumber(e.quantity_keyring or 0) or 0
    e.quantity_mail    = tonumber(e.quantity_mail    or 0) or 0
    e.ilvl             = tonumber(e.ilvl             or 0) or 0
    e.quality          = tonumber(e.quality          or 0) or 0
    e.stack_size       = tonumber(e.stack_size       or 0) or 0
  end
  
  -- ========================================================================
  -- Update hash and timestamp
  -- ========================================================================
  C._catalogMeta.lastHash = currentHash
  C._catalogMeta.lastUpdate = time()
  C._catalogMeta.itemCount = #catalog
end

-- -------------------- Public API --------------------

function NS.Export_Now()
  -- Build/refresh item catalog first
  EnsureItemCatalog()

  -- Per-character compaction (loss-free)
  local key = U and U.GetPlayerKey and U.GetPlayerKey() or (GetRealmName() .. ":" .. UnitName("player"))
  local C = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
  if C then
    -- Optional config flag: only compact if enabled (default true)
    local cfg = WhoDAT_Config and WhoDAT_Config.sampling
    local enabled = (not cfg) or (cfg.series_compact_on_export ~= false)
    if enabled then CompactAllSeries(C) end
  end

  WhoDatDB.last_export_ts = time()
end

-- Export automatically on logout
local f = NS._exportFrame or CreateFrame("Frame")
NS._exportFrame = f
f:RegisterEvent("PLAYER_LOGOUT")
f:SetScript("OnEvent", function()
  NS.Export_Now()
end)
-- ============================================================================
-- Chunked Export Integration Hook
-- ============================================================================

-- Store reference to original export function
NS.Export_Now_Blocking = NS.Export_Now

-- Wrapper to use chunked export by default
function NS.Export_Now()
  local use_chunked = WhoDAT_Config and WhoDAT_Config.export 
    and WhoDAT_Config.export.use_chunked
  
  if use_chunked ~= false then
    -- Use chunked export (non-blocking)
    if NS.Export_StartChunked then
      NS.Export_StartChunked()
    else
      -- Fallback to blocking export if chunked not loaded
      NS.Export_Now_Blocking()
    end
  else
    -- User disabled chunked export, use original
    NS.Export_Now_Blocking()
  end
end
SLASH_WDCATALOGDEBUG1 = "/wdcatdebug"
SlashCmdList["WDCATALOGDEBUG"] = function()
  local key = U and U.GetPlayerKey and U.GetPlayerKey() or (GetRealmName() .. ":" .. UnitName("player"))
  local C = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
  
  if not C then
    print("[WhoDAT] No character data found")
    return
  end
  
  local meta = C._catalogMeta or {}
  local currentHash = _computeContainersHash(C.containers)
  local catalog = C.catalogs and C.catalogs.items_catalog or {}
  
  print("=== Catalog Debug ===")
  print("Current hash:", currentHash)
  print("Last hash:", meta.lastHash or "none")
  print("Changed:", currentHash ~= meta.lastHash)
  print("Last update:", meta.lastUpdate and date("%Y-%m-%d %H:%M:%S", meta.lastUpdate) or "never")
  print("Items in catalog:", #catalog)
end