-- tracker_combat.lua
-- WhoDAT - Combat Metrics Tracking
-- Tracks DPS, HPS, DTPS and other combat performance metrics
-- Wrath 3.3.5a compatible

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- ============================================================================
-- Configuration
-- ============================================================================

local CONFIG = {
  SAMPLE_INTERVAL = 15,      -- Sample combat metrics every 15 seconds
  MIN_COMBAT_DURATION = 2,   -- Only log combats longer than 2 seconds
  ENABLE_TRACKING = true,    -- Master toggle
}

-- ============================================================================
-- Combat State
-- ============================================================================

local combatState = {
  active = false,
  startTime = nil,
  endTime = nil,
  
  -- Damage dealt
  totalDamage = 0,
  damageByTarget = {},
  
  -- Healing done
  totalHealing = 0,
  totalOverhealing = 0,
  
  -- Damage taken
  totalDamageTaken = 0,
  damageFromSource = {},
  
  -- Resource tracking
  resourceWasted = 0,
  resourceSpent = 0,
  
  -- Target info
  currentTarget = nil,
  bossEncounter = false,
  
  -- Sample history (for charting)
  samples = {},
  lastSampleTime = 0,
}

-- ============================================================================
-- Helper Functions
-- ============================================================================

local function GetCurrentTarget()
  if UnitExists("target") then
    return {
      name = UnitName("target"),
      guid = UnitGUID("target"),
      level = UnitLevel("target"),
      classification = UnitClassification("target"), -- elite, worldboss, rare, etc.
      is_boss = UnitClassification("target") == "worldboss" or UnitClassification("target") == "elite",
    }
  end
  return nil
end

local function GetInstanceContext()
  local inInstance, instanceType = IsInInstance()
  if not inInstance then return nil end
  
  local name, type, difficulty, difficultyName = GetInstanceInfo()
  
  return {
    name = name,
    type = type,
    difficulty = difficulty,
    difficultyName = difficultyName,
  }
end

local function GetGroupContext()
  -- Wrath 3.3.5a uses GetNumRaidMembers() and GetNumPartyMembers()
  local numRaid = GetNumRaidMembers()
  local numParty = GetNumPartyMembers()
  
  if numRaid > 0 then
    return {
      type = "raid",
      size = numRaid,
    }
  elseif numParty > 0 then
    return {
      type = "party",
      size = numParty + 1,  -- +1 to include player
    }
  end
  
  return {
    type = "solo",
    size = 1,
  }
end

-- ============================================================================
-- Combat Log Parsing
-- ============================================================================

local function OnCombatLogEvent(timestamp, event, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags, ...)
  if not combatState.active then return end
  
  local playerGUID = UnitGUID("player")
  
  -- Damage dealt by player
  if sourceGUID == playerGUID then
    if event == "SWING_DAMAGE" then
      local amount = select(1, ...)
      combatState.totalDamage = combatState.totalDamage + amount
      
      -- Track by target
      if destGUID then
        combatState.damageByTarget[destGUID] = (combatState.damageByTarget[destGUID] or 0) + amount
      end
      
    elseif event == "SPELL_DAMAGE" or event == "SPELL_PERIODIC_DAMAGE" or event == "RANGE_DAMAGE" then
      -- For spell damage: arg1=spellId, arg2=spellName, arg3=spellSchool, arg4=amount
      local spellId, spellName, spellSchool, amount = select(1, ...)
      combatState.totalDamage = combatState.totalDamage + amount
      
      if destGUID then
        combatState.damageByTarget[destGUID] = (combatState.damageByTarget[destGUID] or 0) + amount
      end
    end
  end
  
  -- Healing done by player
  if sourceGUID == playerGUID then
    if event == "SPELL_HEAL" or event == "SPELL_PERIODIC_HEAL" then
      -- For healing: arg1=spellId, arg2=spellName, arg3=spellSchool, arg4=amount, arg5=overheal
      local spellId, spellName, spellSchool, amount, overheal = select(1, ...)
      combatState.totalHealing = combatState.totalHealing + amount
      combatState.totalOverhealing = combatState.totalOverhealing + (overheal or 0)
    end
  end
  
  -- Damage taken by player
  if destGUID == playerGUID then
    if event == "SWING_DAMAGE" then
      local amount = select(1, ...)
      combatState.totalDamageTaken = combatState.totalDamageTaken + amount
      
      if sourceGUID then
        combatState.damageFromSource[sourceGUID] = (combatState.damageFromSource[sourceGUID] or 0) + amount
      end
      
    elseif event == "SPELL_DAMAGE" or event == "SPELL_PERIODIC_DAMAGE" or event == "RANGE_DAMAGE" then
      local spellId, spellName, spellSchool, amount = select(1, ...)
      combatState.totalDamageTaken = combatState.totalDamageTaken + amount
      
      if sourceGUID then
        combatState.damageFromSource[sourceGUID] = (combatState.damageFromSource[sourceGUID] or 0) + amount
      end
    end
  end
  
  -- Resource waste tracking (energy/rage capping)
  if sourceGUID == playerGUID and event == "SPELL_ENERGIZE" then
    local spellId, spellName, spellSchool, amount, powerType = select(1, ...)
    -- TODO: Detect if player was at cap (would need UnitPower tracking)
  end
end

-- ============================================================================
-- Combat Sampling
-- ============================================================================

local function SampleCombatMetrics()
  if not combatState.active then return end
  
  local now = GetTime()
  local elapsed = now - combatState.startTime
  
  -- Don't sample too frequently
  if now - combatState.lastSampleTime < CONFIG.SAMPLE_INTERVAL then
    return
  end
  
  combatState.lastSampleTime = now
  
  -- Calculate metrics
  local dps = elapsed > 0 and (combatState.totalDamage / elapsed) or 0
  local hps = elapsed > 0 and (combatState.totalHealing / elapsed) or 0
  local dtps = elapsed > 0 and (combatState.totalDamageTaken / elapsed) or 0
  
  local overhealPct = 0
  if combatState.totalHealing > 0 then
    overhealPct = (combatState.totalOverhealing / (combatState.totalHealing + combatState.totalOverhealing)) * 100
  end
  
  -- Create sample
  local sample = {
    ts = time(),
    elapsed = elapsed,
    dps = dps,
    hps = hps,
    dtps = dtps,
    overheal_pct = overhealPct,
    total_damage = combatState.totalDamage,
    total_healing = combatState.totalHealing,
    total_damage_taken = combatState.totalDamageTaken,
  }
  
  table.insert(combatState.samples, sample)
  
  if NS.Log then
    NS.Log("DEBUG", "Combat sample: DPS=%.0f HPS=%.0f DTPS=%.0f (%.0fs)",
      dps, hps, dtps, elapsed)
  end
end

-- ============================================================================
-- Combat Start/End
-- ============================================================================

local function OnCombatStart()
  if not CONFIG.ENABLE_TRACKING then return end
  
  combatState = {
    active = true,
    startTime = GetTime(),
    startTimeUnix = time(),
    
    totalDamage = 0,
    damageByTarget = {},
    
    totalHealing = 0,
    totalOverhealing = 0,
    
    totalDamageTaken = 0,
    damageFromSource = {},
    
    resourceWasted = 0,
    resourceSpent = 0,
    
    currentTarget = GetCurrentTarget(),
    instance = GetInstanceContext(),
    group = GetGroupContext(),
    
    samples = {},
    lastSampleTime = GetTime(),
  }
  
  -- Determine if boss encounter
  if combatState.currentTarget then
    combatState.bossEncounter = combatState.currentTarget.is_boss
  end
  
  if NS.Log then
    NS.Log("DEBUG", "Combat started: target=%s boss=%s",
      combatState.currentTarget and combatState.currentTarget.name or "none",
      tostring(combatState.bossEncounter))
  end
end

local function OnCombatEnd()
  if not combatState.active then return end
  
  combatState.active = false
  combatState.endTime = GetTime()
  combatState.endTimeUnix = time()
  
  local duration = combatState.endTime - combatState.startTime
  
  -- Ignore very short combats
  if duration < CONFIG.MIN_COMBAT_DURATION then
    if NS.Log then
      NS.Log("DEBUG", "Combat too short (%.1fs), not logging", duration)
    end
    return
  end
  
  -- Take final sample
  SampleCombatMetrics()
  
  -- Calculate final metrics
  local dps = duration > 0 and (combatState.totalDamage / duration) or 0
  local hps = duration > 0 and (combatState.totalHealing / duration) or 0
  local dtps = duration > 0 and (combatState.totalDamageTaken / duration) or 0
  
  local overhealPct = 0
  if combatState.totalHealing > 0 then
    overhealPct = (combatState.totalOverhealing / (combatState.totalHealing + combatState.totalOverhealing)) * 100
  end
  
  -- Build combat event
  local combatEvent = {
    ts = combatState.startTimeUnix,
    duration = duration,
    
    -- Metrics
    dps = dps,
    hps = hps,
    dtps = dtps,
    overheal_pct = overhealPct,
    
    -- Totals
    total_damage = combatState.totalDamage,
    total_healing = combatState.totalHealing,
    total_overheal = combatState.totalOverhealing,
    total_damage_taken = combatState.totalDamageTaken,
    
    -- Context
    target = combatState.currentTarget and combatState.currentTarget.name or nil,
    target_level = combatState.currentTarget and combatState.currentTarget.level or nil,
    is_boss = combatState.bossEncounter,
    
    instance = combatState.instance and combatState.instance.name or nil,
    instance_difficulty = combatState.instance and combatState.instance.difficultyName or nil,
    
    group_type = combatState.group.type,
    group_size = combatState.group.size,
    
    zone = GetRealZoneText() or GetZoneText(),
    subzone = GetSubZoneText(),
    
    -- Samples for charting
    samples = combatState.samples,
  }
  
  -- Save to database
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or (GetRealmName() .. ":" .. UnitName("player"))
  
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.characters = WhoDatDB.characters or {}
  WhoDatDB.characters[key] = WhoDatDB.characters[key] or {}
  WhoDatDB.characters[key].events = WhoDatDB.characters[key].events or {}
  WhoDatDB.characters[key].events.combat = WhoDatDB.characters[key].events.combat or {}
  
  table.insert(WhoDatDB.characters[key].events.combat, combatEvent)
  
  -- Limit storage (keep last 500 combats)
  local maxCombats = 500
  while #WhoDatDB.characters[key].events.combat > maxCombats do
    table.remove(WhoDatDB.characters[key].events.combat, 1)
  end
  
  -- Emit to EventBus
  if NS.EventBus and NS.EventBus.Emit then
    NS.EventBus:Emit("combat", "ended", combatEvent)
  end
  
  if NS.Log then
    NS.Log("INFO", "Combat ended: %.0fs, DPS=%.0f HPS=%.0f DTPS=%.0f",
      duration, dps, hps, dtps)
  end
end

-- ============================================================================
-- Event Registration
-- ============================================================================

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

-- Sample timer
local sampleTimer = 0
frame:SetScript("OnUpdate", function(self, elapsed)
  sampleTimer = sampleTimer + elapsed
  
  if sampleTimer >= CONFIG.SAMPLE_INTERVAL then
    sampleTimer = 0
    SampleCombatMetrics()
  end
end)

frame:SetScript("OnEvent", function(self, event, ...)
  if event == "PLAYER_REGEN_DISABLED" then
    OnCombatStart()
    
  elseif event == "PLAYER_REGEN_ENABLED" then
    OnCombatEnd()
    
  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
    OnCombatLogEvent(...)
  end
end)

-- ============================================================================
-- Public API
-- ============================================================================

function NS.Combat_Enable()
  CONFIG.ENABLE_TRACKING = true
end

function NS.Combat_Disable()
  CONFIG.ENABLE_TRACKING = false
end

function NS.Combat_SetSampleInterval(seconds)
  CONFIG.SAMPLE_INTERVAL = math.max(5, seconds)
end

-- ============================================================================
-- SQL Schema
-- ============================================================================

--[[
CREATE TABLE combat_encounters (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  character_id BIGINT UNSIGNED NOT NULL,
  ts INT UNSIGNED NOT NULL,
  duration FLOAT NOT NULL,
  
  -- Performance metrics
  dps FLOAT,
  hps FLOAT,
  dtps FLOAT,
  overheal_pct FLOAT,
  
  -- Totals
  total_damage BIGINT UNSIGNED,
  total_healing BIGINT UNSIGNED,
  total_overheal BIGINT UNSIGNED,
  total_damage_taken BIGINT UNSIGNED,
  
  -- Context
  target VARCHAR(128),
  target_level TINYINT UNSIGNED,
  is_boss BOOLEAN,
  
  instance VARCHAR(128),
  instance_difficulty VARCHAR(64),
  
  group_type ENUM('solo', 'party', 'raid'),
  group_size TINYINT UNSIGNED,
  
  zone VARCHAR(128),
  subzone VARCHAR(128),
  
  KEY idx_char_ts (character_id, ts),
  KEY idx_target (target),
  KEY idx_instance (instance),
  KEY idx_boss (is_boss, dps DESC),
  CONSTRAINT fk_combat_char FOREIGN KEY (character_id)
    REFERENCES characters(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Optional: Store samples for detailed charting
CREATE TABLE combat_samples (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  combat_id BIGINT UNSIGNED NOT NULL,
  ts INT UNSIGNED NOT NULL,
  elapsed FLOAT,
  dps FLOAT,
  hps FLOAT,
  dtps FLOAT,
  
  KEY idx_combat (combat_id),
  CONSTRAINT fk_sample_combat FOREIGN KEY (combat_id)
    REFERENCES combat_encounters(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
]]

-- ============================================================================
-- Debug Commands
-- ============================================================================

SLASH_WDCOMBAT1 = "/wdcombat"
SlashCmdList["WDCOMBAT"] = function(msg)
  msg = (msg or ""):lower()
  
  if msg == "enable" then
    NS.Combat_Enable()
    print("[WhoDAT] Combat tracking enabled")
    
  elseif msg == "disable" then
    NS.Combat_Disable()
    print("[WhoDAT] Combat tracking disabled")
    
  elseif msg == "stats" then
    local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
      or (GetRealmName() .. ":" .. UnitName("player"))
    
    local char = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
    local combats = char and char.events and char.events.combat or {}
    
    print("=== Combat Statistics ===")
    print(string.format("Total combats: %d", #combats))
    
    if #combats > 0 then
      local totalDPS = 0
      local totalHPS = 0
      local maxDPS = 0
      local bossFights = 0
      
      for _, combat in ipairs(combats) do
        totalDPS = totalDPS + (combat.dps or 0)
        totalHPS = totalHPS + (combat.hps or 0)
        maxDPS = math.max(maxDPS, combat.dps or 0)
        
        if combat.is_boss then
          bossFights = bossFights + 1
        end
      end
      
      print(string.format("Average DPS: %.0f", totalDPS / #combats))
      print(string.format("Average HPS: %.0f", totalHPS / #combats))
      print(string.format("Max DPS: %.0f", maxDPS))
      print(string.format("Boss fights: %d", bossFights))
    end
    
  elseif msg == "current" then
    if combatState.active then
      local elapsed = GetTime() - combatState.startTime
      local dps = elapsed > 0 and (combatState.totalDamage / elapsed) or 0
      
      print("=== Current Combat ===")
      print(string.format("Duration: %.0fs", elapsed))
      print(string.format("DPS: %.0f", dps))
      print(string.format("Total damage: %d", combatState.totalDamage))
      print(string.format("Samples: %d", #combatState.samples))
    else
      print("[WhoDAT] Not in combat")
    end
    
  else
    print("=== WhoDAT Combat Tracker ===")
    print("/wdcombat enable  - Enable combat tracking")
    print("/wdcombat disable - Disable combat tracking")
    print("/wdcombat stats   - Show combat statistics")
    print("/wdcombat current - Show current combat info")
  end
end

return NS