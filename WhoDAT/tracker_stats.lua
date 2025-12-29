--[[
WhoDAT - tracker_stats.lua (production)
Wrath of the Lich King 3.3.5a compatible
Tracks time-series and snapshots for: money, XP, rested, level, honor; base stats; attack & spell ratings; resistances; buffs/debuffs; talents; zone changes; currencies; time played.
Design notes:
- Defensive nil-checks for private cores
- Token UI gating for currency calls (LoadAddOn("Blizzard_TokenUI"))
- Throttling to avoid heavy scans in combat or too frequently
- Series are capped using NS.CONFIG.LIMITS.MAX_SERIES (default 500)
- Module exposes NS.Stats_Init() and NS.Stats_RegisterEvents(frame) so core.lua can orchestrate
]]
local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS
local U = NS.Utils or {}

--- Helpers --------------------------------------------------------------------

-- === Session Boundary Utilities ==============================================
-- Place near other helpers in tracker_stats.lua
local function _uuid4()
  -- lightweight UUIDv4-ish (not cryptographic; sufficient for client-side session keys)
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return template:gsub("[xy]", function(c)
    local r = math.random(0, 15)
    local v = (c == "x") and r or (r % 4 + 8) -- y = 8..b
    return string.format("%x", v)
  end)
end
local function _now() return time() end

-- Forward declaration so Session_Start/End can call it before the body is defined
local ensureCharacterSlot

-- Global accessor so core.lua can query or start/end sessions
function NS.Session_GetId()
  WhoDatDB = WhoDatDB or {}
  WhoDatDB._runtime = WhoDatDB._runtime or {}
  return WhoDatDB._runtime.session_id
end

local function _setSessionId(id)
  WhoDatDB = WhoDatDB or {}
  WhoDatDB._runtime = WhoDatDB._runtime or {}
  WhoDatDB._runtime.session_id = id
end

local function _getIdentity()
  -- Uses the identity snapshot you already maintain
  WhoDatDB = WhoDatDB or {}
  local ident = WhoDatDB.identity or {}
  return {
    player  = ident.player_name,
    realm   = ident.realm,
    class   = ident.class_file or ident.class_local,
    faction = ident.faction,
    locale  = ident.locale
  }
end

-- ============================================================================
-- Session Management: Start
-- ============================================================================
function NS.Session_Start(reason)
  local sid = _uuid4()
  local ts = _now()
  local key, char = ensureCharacterSlot()
  
  -- Set active session ID in runtime state
  _setSessionId(sid)
  
  -- Record session start in global sessions table
  WhoDatDB.sessions = WhoDatDB.sessions or {}
  WhoDatDB.sessions[#WhoDatDB.sessions+1] = {
    session_id    = sid,
    ts_start      = ts,
    start_ts      = ts,  -- Alias for compatibility with graphs
    character_key = key,
    reason        = reason,
    zone          = GetRealZoneText and GetRealZoneText() or (GetZoneText and GetZoneText()) or "Unknown"
  }
  
  -- CRITICAL FIX: Also record in per-character sessions (graphs.lua reads from here first!)
  char.sessions = char.sessions or {}
  char.sessions[#char.sessions+1] = {
    session_id    = sid,
    ts_start      = ts,
    start_ts      = ts,  -- Alias for compatibility
    ts            = ts,   -- Another alias some code might expect
    character_key = key,
    reason        = reason,
    zone          = GetRealZoneText and GetRealZoneText() or (GetZoneText and GetZoneText()) or "Unknown"
  }
  
  -- Record session start in per-character events
  char.events = char.events or {}
  char.events.sessions = char.events.sessions or {}
  char.events.sessions[#char.events.sessions+1] = {
    ts         = ts,
    session_id = sid,
    event      = "start",
    reason     = reason
  }
  
  -- Log event via internal event logger
  NS._logEvent("session", "start", {
    ts         = ts,
    session_id = sid,
    reason     = reason,
    zone       = GetRealZoneText and GetRealZoneText() or (GetZoneText and GetZoneText()) or "Unknown",
    identity   = _getIdentity(),
  })
  
  -- Emit to EventBus if available
  if NS.EventBus and NS.EventBus.Emit then
    NS.EventBus:Emit("session", "started", {
      session_id = sid,
      reason     = reason,
      zone       = GetRealZoneText and GetRealZoneText() or (GetZoneText and GetZoneText()) or "Unknown"
    })
  end
  
  if NS.Log then
    NS.Log("INFO", "Session started: %s (reason: %s)", sid, reason or "unknown")
  end
  
  return sid
end

-- ============================================================================
-- Session Management: End
-- ============================================================================
function NS.Session_End(reason)
  local sid = NS.Session_GetId()
  local ts = _now()
  local key, char = ensureCharacterSlot()
  if sid then
    -- Append end markers to global sessions
    WhoDatDB.sessions = WhoDatDB.sessions or {}
    WhoDatDB.sessions[#WhoDatDB.sessions+1] = {
      session_id    = sid, ts_end = ts, end_ts = ts, character_key = key, reason = reason
    }
    
    -- CRITICAL FIX: Update the per-character session with end_ts
    char.sessions = char.sessions or {}
    for i = #char.sessions, 1, -1 do
      if char.sessions[i].session_id == sid then
        char.sessions[i].ts_end = ts
        char.sessions[i].end_ts = ts
        char.sessions[i].te = ts  -- Another alias
        break
      end
    end
    
    char.events = char.events or {}
    char.events.sessions = char.events.sessions or {}
    char.events.sessions[#char.events.sessions+1] = {
      ts = ts, session_id = sid, event = "end", reason = reason
    }
    NS._logEvent("session", "end", {
      ts         = ts,
      session_id = sid,
      reason     = reason,
      identity   = _getIdentity(),
    })
  end
  -- Clear session_id so nothing is accidentally attributed after end
  _setSessionId(nil)
end

-- ===========================================================================

-- === Simple diff + safe logger ===

function NS._logEvent(category, action, payload)
  payload = payload or {}
  -- Attach current session_id if available
  local sid = NS.Session_GetId and NS.Session_GetId() or nil
  if sid and payload.session_id == nil then
    payload.session_id = sid
  end

  -- Existing behavior
  if type(WhoDAT_LogEvent) == "function" then
    WhoDAT_LogEvent(category, action, payload)
  elseif NS.Log then
    NS.Log("EVENT", "%s:%s %s", tostring(category), tostring(action),
      tostring(payload and payload.spell or payload and payload.glyph or payload and payload.skill or payload and payload.talent or ""))
  end
end

-- Build name->item map from { {name=..., ...}, ... } array
local function _indexByName(arr)
  local m = {}
  if type(arr) == "table" then
    for _, v in ipairs(arr) do
      if type(v) == "table" and v.name then m[v.name] = v end
    end
  end
  return m
end

-- Generic set diff: returns added[], removed[], common[]
local function _setDiff(oldArr, newArr)
  local oldM, newM = _indexByName(oldArr), _indexByName(newArr)
  local added, removed, common = {}, {}, {}
  -- added
  for name, v in pairs(newM) do
    if not oldM[name] then table.insert(added, v) else common[name] = { old = oldM[name], new = v } end
  end
  -- removed
  for name, v in pairs(oldM) do
    if not newM[name] then table.insert(removed, v) end
  end
  return added, removed, common
end

-- Persist "previous snapshot" store per character safely
local function _ensurePrevStore(char)
  char.prev = char.prev or { }
  char.prev.snapshots = char.prev.snapshots or { }
  char.prev.series = char.prev.series or { } -- in case you want series diffs later
  return char.prev
end

local function now() return time() end


-- (Definition follows the forward declaration above)
ensureCharacterSlot = function()
  local key = (U.GetPlayerKey and U.GetPlayerKey()) or (UnitName("player") .. "-" .. GetRealmName())
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.characters = WhoDatDB.characters or {}
  WhoDatDB.characters[key] = WhoDatDB.characters[key] or { series = {}, snapshots = {}, events = { sessions = {} } }
  return key, WhoDatDB.characters[key]
end


local function getSeriesContainer(name)
  local _, char = ensureCharacterSlot()
  char.series[name] = char.series[name] or {}
  return char.series[name]
end

local function pushSeries(name, point)
  local arr = getSeriesContainer(name)
  arr[#arr+1] = point
  local limit = (NS.CONFIG and NS.CONFIG.LIMITS and NS.CONFIG.LIMITS.MAX_SERIES) or 500
  if #arr > limit then table.remove(arr, 1) end
end

local _last = {}
local function shouldThrottle(tag, interval)
  local t = now()
  local last = _last[tag] or 0
  if (t - last) < interval then return true end
  _last[tag] = t
  return false
end

local function safeCall(tag, fn)
  local ok, err = pcall(fn)
  if not ok then
    if NS.Log then NS.Log("ERROR", "stats:%s error: %s", tostring(tag), tostring(err)) end
  end
end

local function inCombat()
  return UnitAffectingCombat and UnitAffectingCombat("player") or false
end

--- Core Series ---------------------------------------------------------------

-- DELTA ENCODING: Track last values
local _lastSeriesValues = { money = nil, level = nil, honor = nil }

function NS.Stats_RefreshSeries(triggerEvent)
  safeCall("series", function()
    local ts = now()
    -- Money (DELTA ENCODED)
    local money = GetMoney and GetMoney() or 0
    if _lastSeriesValues.money == nil or _lastSeriesValues.money ~= money then
      pushSeries("money", { ts = ts, value = money })
      _lastSeriesValues.money = money
    end
    -- XP / Rested / Level
    local xp = UnitXP and UnitXP("player") or 0
    local xpMax = UnitXPMax and UnitXPMax("player") or 0
    local rested = GetXPExhaustion and GetXPExhaustion() or 0
    -- Level (DELTA ENCODED)
    local level = UnitLevel and UnitLevel("player") or 0
    if _lastSeriesValues.level == nil or _lastSeriesValues.level ~= level then
      pushSeries("level", { ts = ts, value = level })
      _lastSeriesValues.level = level
    end
    pushSeries("xp",     { ts = ts, value = xp, max = xpMax })
    pushSeries("rested", { ts = ts, value = rested })
        -- Health/Mana maxima
    local hpMax = UnitHealthMax and UnitHealthMax("player") or nil
    local mpMax = UnitManaMax   and UnitManaMax("player")   or nil
    local powerType = UnitPowerType and UnitPowerType("player") or nil
    pushSeries("resource_max", { ts = ts, hp = hpMax, mp = mpMax, powerType = powerType })
    -- Honor points (Wrath has point currency)
-- Honor (DELTA ENCODED)
    if GetHonorCurrency then
      local honor = GetHonorCurrency() or 0
      if _lastSeriesValues.honor == nil or _lastSeriesValues.honor ~= honor then
        pushSeries("honor", { ts = ts, value = honor })
        _lastSeriesValues.honor = honor
      end
    end
  end)
  
-- CORRECTED: Trigger immediate graph refresh when data changes
  if NS.ui and NS.ui.tabs then
    for _, tab in ipairs(NS.ui.tabs) do
      if tab.key == "graphs" and tab.panel and tab.panel:IsVisible() then
        if NS.Graphs_ForceRefresh then
          NS.Graphs_ForceRefresh(tab.panel)
        end
        break
      end
    end
  end
end

--- Zone ----------------------------------------------------------------------


-- ============================================================================
-- ZONE TRACKING (FIXED - Session 5 Patch)
-- ============================================================================

-- Store last zone/subzone to detect actual changes
NS._lastZone = NS._lastZone or { zone = nil, subzone = nil }

function NS.Stats_OnZoneChanged()
  safeCall("zone", function()
    local ts = now()
    
    -- Get current zone/subzone (use GetRealZoneText for accuracy)
    local zone = (GetRealZoneText and GetRealZoneText()) or (GetZoneText and GetZoneText()) or ""
    local subzone = (GetSubZoneText and GetSubZoneText()) or ""
    local hearth = GetBindLocation and GetBindLocation() or nil
    
    -- Normalize empty strings
    zone = zone ~= "" and zone or ""
    subzone = subzone ~= "" and subzone or ""
    
    -- Check if zone actually changed
    local zoneChanged = (zone ~= NS._lastZone.zone)
    local subzoneChanged = (subzone ~= NS._lastZone.subzone)
    
    if not zoneChanged and not subzoneChanged then
      -- No actual change, skip logging
      return
    end
    
    -- Update last known zone/subzone
    NS._lastZone.zone = zone
    NS._lastZone.subzone = subzone
    
    -- Log to series (NEW structure for export/SQL)
    local series = getSeriesContainer("zones")
    series[#series+1] = { 
      ts = ts, 
      zone = zone, 
      subzone = subzone, 
      hearth = hearth 
    }
    
    -- Enforce series limit
    local limit = (NS.CONFIG and NS.CONFIG.LIMITS and NS.CONFIG.LIMITS.MAX_SERIES) or 500
    if #series > limit then 
      table.remove(series, 1) 
    end
    
    
    -- Emit to EventBus for other modules (e.g., item tracker needs zone context)
    if NS.EventBus and NS.EventBus.Emit then
      NS.EventBus:Emit("zone", "changed", {
        ts = ts,
        zone = zone,
        subzone = subzone,
        hearth = hearth,
        previous_zone = NS._lastZone.zone,
        previous_subzone = NS._lastZone.subzone,
      })
    end
    
    -- Log the zone change
    if NS.Log and (zoneChanged or subzoneChanged) then
      if subzone ~= "" then
        NS.Log("DEBUG", "Zone changed: %s (%s)", zone, subzone)
      else
        NS.Log("DEBUG", "Zone changed: %s", zone)
      end
    end
  end)
end



--- Base Stats & Ratings -------------------------------------------------------
function NS.Stats_ScanBaseStats()
  if inCombat() and shouldThrottle("base_incombat", 15) then return end
  if shouldThrottle("base", 30) then return end
  safeCall("base", function()
    local ts = now()
    
    -- FIXED: Flatten structure for SQL compatibility
    local snapshot = {
      ts = ts,
      -- Base stats as top-level fields
      strength = select(2, UnitStat("player", 1)),
      agility = select(2, UnitStat("player", 2)),
      stamina = select(2, UnitStat("player", 3)),
      intellect = select(2, UnitStat("player", 4)),
      spirit = select(2, UnitStat("player", 5)),
      armor = UnitArmor and select(2, UnitArmor("player")) or nil,
      defense = UnitDefense and select(1, UnitDefense("player")) or nil,
      -- Resistances as top-level fields
      resist_physical = UnitResistance and select(2, UnitResistance("player", 0)) or nil,
      resist_holy = UnitResistance and select(2, UnitResistance("player", 1)) or nil,
      resist_fire = UnitResistance and select(2, UnitResistance("player", 2)) or nil,
      resist_nature = UnitResistance and select(2, UnitResistance("player", 3)) or nil,
      resist_frost = UnitResistance and select(2, UnitResistance("player", 4)) or nil,
      resist_shadow = UnitResistance and select(2, UnitResistance("player", 5)) or nil,
      resist_arcane = UnitResistance and select(2, UnitResistance("player", 6)) or nil,
    }
    
    local _, char = ensureCharacterSlot()
    char.series.base_stats = char.series.base_stats or {}
    char.series.base_stats[#char.series.base_stats+1] = snapshot
    local limit = (NS.CONFIG and NS.CONFIG.LIMITS and NS.CONFIG.LIMITS.MAX_SERIES) or 500
    if #char.series.base_stats > limit then table.remove(char.series.base_stats, 1) end
  end)
end

function NS.Stats_ScanAttack()
  if inCombat() and shouldThrottle("attack_incombat", 10) then return end
  if shouldThrottle("attack", 20) then return end
  safeCall("attack", function()
    local ts = now()
    local mh, oh = (UnitAttackSpeed and UnitAttackSpeed("player"))
    local apBase, apPos, apNeg = UnitAttackPower and UnitAttackPower("player") or 0,0,0
    local crit  = GetCritChance  and GetCritChance()  or nil
    local dodge = GetDodgeChance and GetDodgeChance() or nil
    local parry = GetParryChance and GetParryChance() or nil
    local block = GetBlockChance and GetBlockChance() or nil
    local series = getSeriesContainer("attack")
    series[#series+1] = {
      ts = ts, mhSpeed = mh, ohSpeed = oh, apBase = apBase, apPos = apPos, apNeg = apNeg,
      crit = crit, dodge = dodge, parry = parry, block = block
    }
    local limit = (NS.CONFIG and NS.CONFIG.LIMITS and NS.CONFIG.LIMITS.MAX_SERIES) or 500
    if #series > limit then table.remove(series, 1) end
  end)
end

function NS.Stats_ScanRangedAndSpell()
  if inCombat() and shouldThrottle("spell_incombat", 10) then return end
  if shouldThrottle("spell", 25) then return end
  safeCall("spell", function()
    local ts = now()
    local rDmgMin, rDmgMax, rSpeed, rPower = nil, nil, nil, nil
    if UnitRangedDamage then
      rDmgMin, rDmgMax, rSpeed = UnitRangedDamage("player")
    end
    if UnitRangedAttackPower then
      rPower = UnitRangedAttackPower("player")
    end
    local rCrit     = GetRangedCritChance and GetRangedCritChance() or nil
    local healBonus = GetSpellBonusHealing and GetSpellBonusHealing() or nil
    local spellPen  = GetSpellPenetration   and GetSpellPenetration() or nil
    local regenBase, regenCasting = nil, nil
    if GetManaRegen then regenCasting, regenBase = GetManaRegen() end -- Wrath returns whileCasting, base
    local schools = {}
    for s=1,7 do
      local dmg  = GetSpellBonusDamage and GetSpellBonusDamage(s) or nil
      local crit = GetSpellCritChance  and GetSpellCritChance(s)  or nil
      schools[s] = { dmg = dmg, crit = crit }
    end
    local series = getSeriesContainer("spell_ranged")
    series[#series+1] = {
      ts = ts,
      ranged = { min = rDmgMin, max = rDmgMax, speed = rSpeed, ap = rPower, crit = rCrit },
      spell  = { healBonus = healBonus, penetration = spellPen, mp5_base = regenBase, mp5_cast = regenCasting, schools = schools }
    }
    local limit = (NS.CONFIG and NS.CONFIG.LIMITS and NS.CONFIG.LIMITS.MAX_SERIES) or 500
    if #series > limit then table.remove(series, 1) end
  end)
end

--- Buffs/Debuffs --------------------------------------------------------------
-- OPTIMIZED: Snapshot-based buff/debuff tracking (not event-stream)
-- Only captures buffs during important moments (zone change, combat start/end)
function NS.Stats_SnapshotAuras()
  safeCall("auras", function()
    local ts = now()
    local _, char = ensureCharacterSlot()
    
    -- Collect current buffs
    local buffs = {}
    for i=1,40 do
      local name, rank, texture, count, dtype, duration, expirationTime, unitCaster = UnitBuff and UnitBuff("player", i)
      if not name then break end
      
      table.insert(buffs, {
        name = name,
        icon = texture,
        count = count,
        type = dtype,
        duration = duration,
        remaining = expirationTime and (expirationTime - GetTime()) or 0,
        caster = unitCaster,
      })
    end
    
    -- Collect current debuffs
    local debuffs = {}
    for i=1,40 do
      local name, rank, texture, count, dtype, duration, expirationTime, unitCaster = UnitDebuff and UnitDebuff("player", i)
      if not name then break end
      
      table.insert(debuffs, {
        name = name,
        icon = texture,
        count = count,
        type = dtype,
        duration = duration,
        remaining = expirationTime and (expirationTime - GetTime()) or 0,
        caster = unitCaster,
      })
    end
    
    -- Store as SNAPSHOT (not series)
    char.snapshots = char.snapshots or {}
    char.snapshots.auras = {
      ts = ts,
      buffs = buffs,
      debuffs = debuffs,
      buff_count = #buffs,
      debuff_count = #debuffs,
    }
    
    -- Optional: Keep a limited history of snapshots
    char.snapshots.auras_history = char.snapshots.auras_history or {}
    table.insert(char.snapshots.auras_history, {
      ts = ts,
      buff_count = #buffs,
      debuff_count = #debuffs,
      buffs = buffs,
      debuffs = debuffs,
    })
    
    -- Limit history (keep last 100 snapshots)
    while #char.snapshots.auras_history > 100 do
      table.remove(char.snapshots.auras_history, 1)
    end
  end)
end

-- Legacy compatibility: Keep old function name but make it call the new one
function NS.Stats_ScanAuras()
  NS.Stats_SnapshotAuras()
end

--- Identity (player + guild) --------------------------------------------------

local function _resolveFaction()
  -- Wrath classic often has UnitFactionGroup("player")
  if UnitFactionGroup then
    local f = UnitFactionGroup("player")
    if type(f) == "string" then return f end
  end
  return nil
end

local function _resolveLocale()
  -- GetLocale() is available on Wrath clients
  if GetLocale then return GetLocale() end
  return nil
end

local function _resolveClass()
  -- Both local + file class (e.g., "Mage" and "MAGE")
  if UnitClass then
    local localName, fileName = UnitClass("player")
    return localName, fileName
  end
  return nil, nil
end

local function _resolveGuildSnapshot()
  -- Returns a table with guild info or nil if not in a guild
  local inGuild = IsInGuild and IsInGuild() or false
  if not inGuild then
    return { in_guild = false, name = nil, rank = nil, rank_index = nil, members = nil }
  end
  -- GetGuildInfo("player") is the stable way to get name & rank on 3.3.5a
  local gName, gRankName, gRankIndex = nil, nil, nil
  if GetGuildInfo then
    gName, gRankName, gRankIndex = GetGuildInfo("player")
  end
  -- Optional enrichment: number of members (may require roster available)
  local memberCount = nil
  if GetNumGuildMembers then
    -- Guild roster is usually kept fresh by the client; if a private core lags,
    -- you can call GuildRoster() elsewhere (not here, to avoid spam).
    memberCount = GetNumGuildMembers()
  end
  return {
    in_guild   = true,
    name       = gName,
    rank       = gRankName,
    rank_index = gRankIndex,
    members    = memberCount,
  }
end

function NS.Stats_UpdateIdentity()
  safeCall("identity", function()
    local ts = now()
    local playerName = UnitName  and UnitName("player")  or nil
    local realmName  = GetRealmName and GetRealmName()   or nil
    local classLocal, classFile = _resolveClass()
    local faction = _resolveFaction()
    local locale  = _resolveLocale()
    local guild   = _resolveGuildSnapshot()
    local race, raceFile = UnitRace("player")
    local sex = UnitSex("player")  -- 1=unknown, 2=male, 3=female
    local _, char = ensureCharacterSlot()
    -- (char.snapshots.identity is intentionally omitted)
    -- Move identity fields to the lower/global block
    WhoDatDB.identity = WhoDatDB.identity or {}
    -- Core identity fields
    WhoDatDB.identity.player_name  = playerName
    WhoDatDB.identity.realm        = realmName
    WhoDatDB.identity.class_local  = classLocal
    WhoDatDB.identity.class_file   = classFile
    WhoDatDB.identity.race_local   = race          -- NEW
    WhoDatDB.identity.race_file    = raceFile      -- NEW
    WhoDatDB.identity.sex          = sex           -- NEW
    WhoDatDB.identity.faction      = faction
    WhoDatDB.identity.locale       = locale
    WhoDatDB.identity.last_login_ts= ts
WhoDatDB.identity.guild = guild
    
    -- FIXED: Add normalized fields for SQL
    local function norm_str(s)
      if type(s) ~= "string" then return "" end
      return s:lower():gsub("%s+", "")
    end
    WhoDatDB.identity.realm_norm = norm_str(realmName)
    WhoDatDB.identity.name_norm = norm_str(playerName)
  end)
end

--- Talents --------------------------------------------------------------------

-- UI gating helper (similar to your Token UI gating)
local function ensureTalentUI()
  if not NS._talentUILoaded and LoadAddOn then
    NS._talentUILoaded = LoadAddOn("Blizzard_TalentUI")
  end
end

function NS.Stats_ScanTalents()
  if inCombat() and shouldThrottle("talents_incombat", 60) then return end
  if shouldThrottle("talents", 300) then return end
  ensureTalentUI() -- ensure talent APIs are initialized on private cores

  -- ─────────────────────────────────────────────────────────────────────────────
  -- Local fallbacks for helpers (used only if your globals are not defined)
  -- ─────────────────────────────────────────────────────────────────────────────
  local function _indexByName(list)
    if type(list) ~= "table" then return {} end
    local m = {}
    for i = 1, #list do
      local it = list[i]
      local k = (type(it) == "table" and it.name) or ("#" .. tostring(i))
      m[k] = it
    end
    return m
  end

  local function _ensurePrevStore(char)
    -- Use an addon-local ephemeral store; avoids SavedVariables churn
    NS._prevStore = NS._prevStore or {}
    NS._prevStore[char] = NS._prevStore[char] or {}
    return NS._prevStore[char]
  end

  local function _emitTalentChanged(payload)
    if _logEvent then
      _logEvent("talent", "changed", payload)
    elseif NS and NS.LogEvent then
      NS.LogEvent("talent", "changed", payload)
    elseif NS and NS.Log then
      -- Very light fallback log; won’t create an event row
      NS.Log("EVENT", "talent:changed tab=%s talent=%s rank=%s from=%s",
        tostring(payload.tab), tostring(payload.talent),
        tostring(payload.rank), tostring(payload.from))
    end
  end

  -- ─────────────────────────────────────────────────────────────────────────────
  -- Scan a specific talent group (1 or 2)
  -- ─────────────────────────────────────────────────────────────────────────────
  local function scanGroup(talentGroup)
    -- Build the tabs/talents snapshot for a specific talent group (1 or 2)
    local tabs = {}
    local numTabs = (GetNumTalentTabs and GetNumTalentTabs()) or 0
    for t = 1, numTabs do
      -- Wrath signature: GetTalentTabInfo(tabIndex, isInspect, isPet, petTalentMask, talentGroup)
      local name, icon, pointsSpent = nil, nil, 0
      if GetTalentTabInfo then
        local n, ic, pts = GetTalentTabInfo(t, false, false, nil, talentGroup)
        name, icon, pointsSpent = n, ic, pts
        -- Some private cores only return name when using select(); we already unpacked safely.
      end
      local tab = { name = name, icon = icon, points = pointsSpent or 0, talents = {} }
      local numTalents = (GetNumTalents and GetNumTalents(t)) or 0
      for i = 1, numTalents do
        -- Wrath signature: GetTalentInfo(tabIndex, talentIndex, inspect, pet, talentGroup)
        local tName, _, _, _, rank, maxRank =
          GetTalentInfo and GetTalentInfo(t, i, false, false, talentGroup)
        -- Optional hardening: some cores ignore talentGroup; try again without it
        if (not rank or rank <= 0 or rank == -1) and GetTalentInfo then
          tName, _, _, _, rank, maxRank = GetTalentInfo(t, i, false, false)
        end
        -- Link is group-agnostic on many cores; parse embedded rank from |Htalent:id:rank|
        local link = GetTalentLink and GetTalentLink(t, i) or nil
        local talentId, linkRank = nil, nil
        if link then
          talentId = tonumber(string.match(link, "Htalent:(%d+):"))
          local lr = string.match(link, "Htalent:%d+:(%-?%d+)")
          linkRank = lr and tonumber(lr) or nil
        end
        -- Prefer API rank; fall back to linkRank when API is 0/-1/nil
        local effectiveRank = rank or 0
        if (not effectiveRank or effectiveRank <= 0) and (linkRank and linkRank > 0) then
          effectiveRank = linkRank
        end
        if effectiveRank < 0 then effectiveRank = 0 end -- normalize weird -1 cases
        tab.talents[#tab.talents + 1] = {
          name    = tName,
          rank    = effectiveRank,
          maxRank = maxRank or nil,
          spellId = nil, -- talent links are Htalent; a spellId is typically not provided here
          link    = link,
          talentId= talentId, -- optional: store numeric talent id from link
          index   = i, -- convenient index within the tab
        }
      end
      -- Optional sanity check: points vs per-talent sum
      local sum = 0
      for _, talent in ipairs(tab.talents) do sum = sum + (talent.rank or 0) end
      if NS.Log and (tab.points or 0) > 0 and sum == 0 then
        NS.Log("WARN",
          "talents: tab '%s' shows %d points but per-talent ranks sum to 0 (UI gated?)",
          tostring(name), tonumber(tab.points) or 0)
      end
      tabs[#tabs + 1] = tab
    end
    return tabs
  end

  -- ─────────────────────────────────────────────────────────────────────────────
  -- Safe wrapper & persistence
  -- ─────────────────────────────────────────────────────────────────────────────
  safeCall("talents", function()
    local ts = now()
    -- Determine active group (defaults to 1 if dual spec not unlocked)
    local activeGroup = 1
    if GetActiveTalentGroup then
      -- Wrath: GetActiveTalentGroup(isInspect, isPet)
      activeGroup = GetActiveTalentGroup(false, false) or 1
    end
    -- Always scan the active group
    local activeTabs = scanGroup(activeGroup)

    -- === DIFF: compare current active group to previous active snapshot ===
    local _, char = ensureCharacterSlot()
    local prev = _ensurePrevStore(char)
    local oldSnap = char.snapshots and char.snapshots.talents or nil
    local oldTabs = (oldSnap and oldSnap.group == activeGroup and oldSnap.tabs) or {}

    -- Build per-tab maps by tab name, then per-talent by talent name
    local function _talentMapByName(tabs)
      local tm = {}
      for _, tab in ipairs(tabs or {}) do
        local talentsM = _indexByName(tab.talents or {})
        tm[tab.name or ("Tab" .. tostring(_))] = { tab = tab, talents = talentsM }
      end
      return tm
    end

    local oldTM = _talentMapByName(oldTabs)
    local newTM = _talentMapByName(activeTabs)

    for tabName, newEntry in pairs(newTM) do
      local oldEntry = oldTM[tabName]
      if oldEntry then
        -- Same tab: check per-talent rank changes
        for talentName, newTalent in pairs(newEntry.talents) do
          local oldTalent = oldEntry.talents[talentName]
          local oldRank = oldTalent and oldTalent.rank or 0
          local newRank = newTalent.rank or 0
          if oldRank ~= newRank then
            _emitTalentChanged({
              tab = tabName, talent = talentName,
              rank = newRank, from = oldRank, max = newTalent.maxRank
            })
          end
        end
      else
        -- Whole tab appeared (dual-spec swap, respec). Emit changes for nonzero ranks.
        for talentName, newTalent in pairs(newEntry.talents) do
          if (newTalent.rank or 0) > 0 then
            _emitTalentChanged({
              tab = tabName, talent = talentName,
              rank = newTalent.rank, from = 0, max = newTalent.maxRank
            })
          end
        end
      end
    end

    -- Talents removed (rank dropped to 0) across same tabs
    for tabName, oldEntry in pairs(oldTM) do
      local newEntry = newTM[tabName]
      if newEntry then
        for talentName, oldTalent in pairs(oldEntry.talents) do
          local newTalent = newEntry.talents[talentName]
          local oldRank = oldTalent.rank or 0
          local newRank = newTalent and (newTalent.rank or 0) or 0
          if oldRank > 0 and newRank == 0 then
            _emitTalentChanged({
              tab = tabName, talent = talentName,
              rank = 0, from = oldRank, max = (newTalent and newTalent.maxRank) or oldTalent.maxRank
            })
          end
        end
      end
    end
    -- === end DIFF ===

    -- If dual spec is available, also scan the other group (1->2, 2->1)
    local otherGroup = (activeGroup == 1) and 2 or 1
    local hasDualSpec, otherTabs = false, nil
    -- Heuristic: If GetActiveTalentGroup exists, the client supports dual spec.
    -- Some private cores expose the API even if the player hasn't purchased dual spec.
    -- We'll only include the other group if it returns meaningful data (nonzero points or ranks).
    if GetActiveTalentGroup then
      local candidate = scanGroup(otherGroup)
      -- Detect meaningful data: any tree points > 0 or any talent rank > 0
      local meaningful = false
      for _, tab in ipairs(candidate) do
        if (tab.points or 0) > 0 then meaningful = true break end
        for _, talent in ipairs(tab.talents or {}) do
          if (talent.rank or 0) > 0 then meaningful = true break end
        end
        if meaningful then break end
      end
      if meaningful then
        hasDualSpec = true
        otherTabs = candidate
      end
    end

    -- Persist to SavedVariables
    char.events = char.events or {}
    char.events.sessions = char.events.sessions or {}
    -- Backward-compatible field: keep the active group here so existing ingest/UI continues to work.
    char.snapshots = char.snapshots or {}
    char.snapshots.talents = { ts = ts, group = activeGroup, tabs = activeTabs }
    -- Keep prev in sync (ephemeral store)
    prev.snapshots = prev.snapshots or {}
    prev.snapshots.talents = char.snapshots.talents

    -- New dual-spec aware field: store both groups when available.
    -- Structure: talents_groups = { [1] = { ts=..., tabs={...} }, [2] = { ts=..., tabs={...} }, active = 1/2 }
    char.snapshots.talents_groups = char.snapshots.talents_groups or {}
    char.snapshots.talents_groups.active = activeGroup
    char.snapshots.talents_groups[activeGroup] = { ts = ts, tabs = activeTabs }
    if hasDualSpec and otherTabs then
      char.snapshots.talents_groups[otherGroup] = { ts = ts, tabs = otherTabs }
    else
      -- If no meaningful other group, clear it so downstream code knows it's not populated
      char.snapshots.talents_groups[otherGroup] = nil
    end
  end)
end

--- Currency / Honor / Arena ---------------------------------------------------

local function ensureTokenUI()
  if not NS._tokenUILoaded and LoadAddOn then NS._tokenUILoaded = LoadAddOn("Blizzard_TokenUI") end
end

function NS.Stats_ScanCurrency()
  if inCombat() and shouldThrottle("currency_incombat", 30) then return end
  if shouldThrottle("currency", 60) then return end
  safeCall("currency", function()
    ensureTokenUI()
    local _, char = ensureCharacterSlot()
    char.series.currency = {}
    local size = GetCurrencyListSize and GetCurrencyListSize() or 0
    for i=1,size do
      local name, isHeader, _, _, _, _, count = GetCurrencyListInfo and GetCurrencyListInfo(i)
      if isHeader and ExpandCurrencyList then ExpandCurrencyList(i, 1) end
      if name and not isHeader then
        char.series.currency[#char.series.currency+1] = { name = name, count = count or 0 }
      end
    end
    -- Honor/Arena snapshots
    local honor = GetHonorCurrency and GetHonorCurrency() or nil
    local arena = GetArenaCurrency and GetArenaCurrency() or nil
    char.snapshots.pvp = { ts = now(), honor = honor, arena = arena }
  end)
end

--- Time played ----------------------------------------------------------------

function NS.Stats_RequestTimePlayed()
  if RequestTimePlayed and not inCombat() and not shouldThrottle("timeplayed_req", 120) then RequestTimePlayed() end
end

function NS.Stats_OnTimePlayedMsg(totalTime, levelTime)
  safeCall("timeplayed", function()
    local _, char = ensureCharacterSlot()
    char.events.sessions[#char.events.sessions+1] = { ts = now(), total = totalTime, level = levelTime }
    local limit = (NS.CONFIG and NS.CONFIG.LIMITS and NS.CONFIG.LIMITS.MAX_SERIES) or 500
    if #char.events.sessions > limit then table.remove(char.events.sessions, 1) end
  end)
end

--- Public orchestration -------------------------------------------------------

function NS.Stats_Init()
  -- initial sweeps
  NS.Stats_RefreshSeries("init")
  NS.Stats_ScanBaseStats()
  NS.Stats_ScanAttack()
  NS.Stats_ScanRangedAndSpell()
  NS.Stats_SnapshotAuras()  -- CHANGED: Use snapshot instead of scan
  NS.Stats_ScanTalents()
  NS.Stats_ScanCurrency()
  NS.Stats_OnZoneChanged()
  NS.Stats_RequestTimePlayed()
  NS.Stats_UpdateIdentity()
end

function NS.Stats_RegisterEvents(frame)
  if not frame or not frame.RegisterEvent then return end
  local ev = {
    "PLAYER_MONEY",
    "PLAYER_XP_UPDATE",
    "UPDATE_FACTION",
    "ZONE_CHANGED",
    "ZONE_CHANGED_INDOORS",
    "ZONE_CHANGED_NEW_AREA",
    -- "UNIT_AURA",  -- REMOVED: Too granular, now using snapshot approach
    "KNOWN_CURRENCY_TYPES_UPDATE",
    "CURRENCY_DISPLAY_UPDATE",
    "TIME_PLAYED_MSG",
    "PLAYER_TALENT_UPDATE",
    "CHARACTER_POINTS_CHANGED",
    -- NEW: guild-related events
    "PLAYER_GUILD_UPDATE",
    "GUILD_ROSTER_UPDATE",
  }
  for i=1,#ev do frame:RegisterEvent(ev[i]) end
frame:HookScript("OnEvent", function(_, event, arg1, ...)
    if event == "PLAYER_MONEY" or event == "PLAYER_XP_UPDATE" or event == "UPDATE_FACTION" then
      NS.Stats_RefreshSeries(event)
    elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" or event == "ZONE_CHANGED_NEW_AREA" then
      NS.Stats_OnZoneChanged()
      NS.Stats_SnapshotAuras()  -- ADD: Snapshot buffs on zone change
    elseif event == "KNOWN_CURRENCY_TYPES_UPDATE" or event == "CURRENCY_DISPLAY_UPDATE" then
      NS.Stats_ScanCurrency()
    elseif event == "TIME_PLAYED_MSG" then
      NS.Stats_OnTimePlayedMsg(arg1, ...)
    elseif event == "PLAYER_TALENT_UPDATE" or event == "CHARACTER_POINTS_CHANGED" then
      NS.Stats_ScanTalents()
    -- NEW: whenever guild state may change, refresh identity
    elseif event == "PLAYER_GUILD_UPDATE" or event == "GUILD_ROSTER_UPDATE" then
      NS.Stats_UpdateIdentity()
    end
  end)
end
-- Register combat events for aura snapshots
local auraFrame = CreateFrame("Frame")
auraFrame:RegisterEvent("PLAYER_REGEN_DISABLED")  -- Combat start
auraFrame:RegisterEvent("PLAYER_REGEN_ENABLED")   -- Combat end
auraFrame:SetScript("OnEvent", function(self, event)
  if event == "PLAYER_REGEN_DISABLED" then
    -- Snapshot buffs at combat start
    NS.Stats_SnapshotAuras()
  elseif event == "PLAYER_REGEN_ENABLED" then
    -- Snapshot buffs at combat end
    NS.Stats_SnapshotAuras()
  end
end)
-- Optional: expose a lightweight tick to refresh combat-adjacent stats
function NS.Stats_OnUpdateThrottle(delta)
  -- call from a throttled OnUpdate in core.lua if desired
  if shouldThrottle("tick_series", 10) then return end
  NS.Stats_RefreshSeries("tick")
  if not inCombat() then
    NS.Stats_ScanBaseStats()
    NS.Stats_ScanAttack()
    NS.Stats_ScanRangedAndSpell()
  end
end

-- === WhoDAT: Add hooks for gear/stat changes to update tracked stats ===
local frame = NS._eventFrame or CreateFrame("Frame")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("UNIT_STATS")
frame:SetScript("OnEvent", function(self, event, arg1, ...)
  if event == "PLAYER_EQUIPMENT_CHANGED" or event == "UNIT_STATS" then
    NS.Stats_ScanBaseStats()
    NS.Stats_ScanAttack()
    NS.Stats_ScanRangedAndSpell()
   end
end)

-- Preserve the frame reference for reuse elsewhere in the addon
NS._eventFrame = frame